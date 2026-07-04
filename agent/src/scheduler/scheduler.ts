// scheduler.ts — планировщик рутин (24/7). Каждой включённой рутине соответствует
// один Cron-джоб (croner) со своей таймзоной. Один общий overlap-guard (Set) для
// тиков расписания, ручного запуска и догоняющих прогонов: пока прогон рутины
// выполняется, новый не стартует (вместо двойного запуска — запись skipped_overlap).
//
// Старт сервиса: примирить «зависшие» running (краш до рестарта) → error,
// зарегистрировать включённые рутины, применить политику пропусков (missed/catch-up).

import { Cron } from "croner";
import type { Logger } from "../logger.js";
import { silentLogger } from "../logger.js";
import type { RoutinesRepo } from "../store/routinesRepo.js";
import type { RunsRepo } from "../store/runsRepo.js";
import type { Runner } from "../runner/runner.js";
import type { Routine, RunRecord, RunTrigger } from "../domain/types.js";
import { nextRunISO } from "../domain/cron.js";

export interface SchedulerDeps {
  routinesRepo: RoutinesRepo;
  runsRepo: RunsRepo;
  runner: Runner;
  logger?: Logger;
  now?: () => Date;
  newId?: () => string;
}

export class SchedulerService {
  private readonly jobs = new Map<string, Cron>();
  private readonly running = new Set<string>();
  private readonly logger: Logger;
  private readonly now: () => Date;
  private readonly newId: () => string;

  constructor(private readonly deps: SchedulerDeps) {
    this.logger = deps.logger ?? silentLogger;
    this.now = deps.now ?? (() => new Date());
    this.newId = deps.newId ?? (() => crypto.randomUUID());
  }

  /** Старт: примирить зависшие running, зарегистрировать рутины, применить catch-up. */
  start(): void {
    const reconciled = this.deps.runsRepo.reconcileStuckRunning(
      "Прервано рестартом сервиса.",
      this.now().toISOString(),
    );
    if (reconciled > 0) {
      this.logger.warn({ reconciled }, "примирены зависшие прогоны running→error");
    }
    for (const routine of this.deps.routinesRepo.list()) {
      if (routine.enabled) this.register(routine);
      this.maybeCatchUp(routine);
    }
  }

  /** (Пере)регистрирует джоб рутины. Для выключенной — только снимает старый. */
  register(routine: Routine): void {
    this.unregister(routine.id);
    if (!routine.enabled) {
      this.deps.routinesRepo.updateRunStamps(routine.id, routine.lastRunAt, null);
      return;
    }
    let job: Cron;
    try {
      job = new Cron(routine.cron, { timezone: routine.timezone }, () => {
        void this.fire(routine.id);
      });
    } catch (e) {
      this.logger.error(
        { routineId: routine.id, cron: routine.cron, err: (e as Error).message },
        "некорректный cron — рутина не зарегистрирована",
      );
      return;
    }
    this.jobs.set(routine.id, job);
    const next = job.nextRun();
    this.deps.routinesRepo.updateRunStamps(
      routine.id,
      routine.lastRunAt,
      next ? next.toISOString() : null,
    );
  }

  unregister(id: string): void {
    const job = this.jobs.get(id);
    if (job) {
      job.stop();
      this.jobs.delete(id);
    }
  }

  /** Перепланировать после правки рутины (register сам снимает старый джоб). */
  reschedule(routine: Routine): void {
    this.register(routine);
  }

  isRunning(id: string): boolean {
    return this.running.has(id);
  }

  /** Останавливает все джобы (graceful shutdown). */
  stop(): void {
    for (const job of this.jobs.values()) job.stop();
    this.jobs.clear();
  }

  /**
   * Ручной запуск из API: при отсутствии активного прогона — стартует в ФОНЕ и
   * сразу возвращает запись `running`; при активном прогоне — `skipped_overlap`.
   */
  triggerNow(routine: Routine): RunRecord {
    if (this.running.has(routine.id)) {
      return this.recordSkipped(routine, "manual", null);
    }
    this.running.add(routine.id);
    const run = this.deps.runner.begin(routine, "manual", null);
    this.executeInBackground(routine, run);
    return run;
  }

  // ── приватное ───────────────────────────────────────────────────────────────

  /** Тик расписания: перечитываем рутину из БД (могла измениться/выключиться). */
  private async fire(id: string): Promise<void> {
    const routine = this.deps.routinesRepo.get(id);
    if (!routine || !routine.enabled) return;
    const scheduledFor = this.now().toISOString();

    if (this.running.has(routine.id)) {
      this.recordSkipped(routine, "schedule", scheduledFor);
      return;
    }
    this.running.add(routine.id);
    try {
      await this.deps.runner.run(routine, "schedule", scheduledFor);
    } catch (e) {
      this.logger.error({ routineId: id, err: (e as Error).message }, "прогон по расписанию упал");
    } finally {
      this.running.delete(routine.id);
    }
  }

  private executeInBackground(routine: Routine, run: RunRecord): void {
    void (async () => {
      try {
        await this.deps.runner.executeRun(routine, run);
      } catch (e) {
        this.logger.error(
          { routineId: routine.id, err: (e as Error).message },
          "фоновый прогон упал",
        );
      } finally {
        this.running.delete(routine.id);
      }
    })();
  }

  private recordSkipped(
    routine: Routine,
    trigger: RunTrigger,
    scheduledFor: string | null,
  ): RunRecord {
    const now = this.now().toISOString();
    const run: RunRecord = {
      id: this.newId(),
      routineId: routine.id,
      trigger,
      status: "skipped_overlap",
      scheduledFor,
      startedAt: now,
      finishedAt: now,
      outputMarkdown: "",
      usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0, costUsd: null },
      toolTranscript: [],
      sinkResults: [],
      error: "Предыдущий прогон ещё выполняется.",
    };
    this.deps.runsRepo.insert(run);
    return run;
  }

  /**
   * Политика пропусков на старте: если между последним прогоном (или созданием) и
   * текущим моментом был хотя бы один слот — фиксируем запись `missed`; при
   * routine.catchUpOnStart дополнительно запускаем РОВНО один догоняющий прогон.
   * Защита от дублей при многократных рестартах: пропускаем, если последний прогон
   * уже привязан к этому же слоту.
   */
  private maybeCatchUp(routine: Routine): void {
    if (!routine.enabled) return;
    const from = routine.lastRunAt
      ? new Date(routine.lastRunAt)
      : new Date(routine.createdAt);
    const missedISO = nextRunISO(routine.cron, routine.timezone, from);
    if (!missedISO) return;
    if (new Date(missedISO).getTime() > this.now().getTime()) return; // слот ещё не наступил

    const latest = this.deps.runsRepo.latestForRoutine(routine.id);
    if (latest && latest.scheduledFor === missedISO) return; // уже зафиксировано

    const now = this.now().toISOString();
    this.deps.runsRepo.insert({
      id: this.newId(),
      routineId: routine.id,
      trigger: "schedule",
      status: "missed",
      scheduledFor: missedISO,
      startedAt: now,
      finishedAt: now,
      outputMarkdown: "",
      usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0, costUsd: null },
      toolTranscript: [],
      sinkResults: [],
      error: "Слот пропущен: сервис был недоступен.",
    });
    this.logger.info({ routineId: routine.id, missedISO }, "зафиксирован пропущенный слот");

    if (routine.catchUpOnStart && !this.running.has(routine.id)) {
      this.running.add(routine.id);
      const run = this.deps.runner.begin(routine, "catchup", missedISO);
      this.executeInBackground(routine, run);
    }
  }
}
