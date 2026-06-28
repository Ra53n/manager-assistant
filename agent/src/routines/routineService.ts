// routineService.ts — бизнес-логика рутин: создание/обновление с дефолтами и
// валидацией (cron, синки), оптимистическая блокировка по rev и синхронизация с
// планировщиком (register/reschedule/unregister). Единая точка истины для CRUD.

import type { RoutinesRepo } from "../store/routinesRepo.js";
import type { SchedulerService } from "../scheduler/scheduler.js";
import {
  DEFAULT_MAX_ITERATIONS,
  DEFAULT_MAX_TOKENS_BUDGET,
  type CreateRoutineInput,
  type Routine,
  type SinkConfig,
  type UpdateRoutineInput,
} from "../domain/types.js";
import { describeCron, isValidCron, nextRunISO } from "../domain/cron.js";
import { ValidationError } from "../domain/errors.js";

function clamp(v: number, min: number, max: number): number {
  if (!Number.isFinite(v)) return min;
  return Math.max(min, Math.min(max, Math.trunc(v)));
}

/**
 * Нормализует синки. Сейчас встроено только локальное хранилище (vps_local) —
 * результат всегда сохраняется в БД и виден в приложении. Сохранение во внешние
 * системы делается через промпт рутины (у агента есть все MCP-инструменты).
 */
export function normalizeSinks(_sinks: SinkConfig[] | undefined): SinkConfig[] {
  return [{ kind: "vps_local" }];
}

export interface RoutineServiceDeps {
  repo: RoutinesRepo;
  scheduler: SchedulerService;
  defaultTimezone: string;
  now?: () => Date;
  newId?: () => string;
}

export class RoutineService {
  private readonly now: () => Date;
  private readonly newId: () => string;

  constructor(private readonly deps: RoutineServiceDeps) {
    this.now = deps.now ?? (() => new Date());
    this.newId = deps.newId ?? (() => crypto.randomUUID());
  }

  list(): Routine[] {
    return this.deps.repo.list();
  }

  get(id: string): Routine {
    return this.deps.repo.getOrThrow(id);
  }

  create(input: CreateRoutineInput): Routine {
    const name = (input.name ?? "").trim();
    const prompt = (input.prompt ?? "").trim();
    const cron = (input.cron ?? "").trim();
    const timezone = (input.timezone ?? "").trim() || this.deps.defaultTimezone;

    if (!name) throw new ValidationError("Не задано имя рутины.");
    if (!prompt) throw new ValidationError("Не задан промпт рутины.");
    if (!isValidCron(cron, timezone)) {
      throw new ValidationError(`Некорректное расписание (cron): «${cron}».`);
    }

    const sinks = normalizeSinks(input.sinks);
    const nowDate = this.now();
    const nowISO = nowDate.toISOString();

    const routine: Routine = {
      id: this.newId(),
      name,
      prompt,
      cron,
      timezone,
      enabled: input.enabled ?? true,
      catchUpOnStart: input.catchUpOnStart ?? false,
      model: (input.model ?? "").trim(),
      maxIterations: clamp(input.maxIterations ?? DEFAULT_MAX_ITERATIONS, 1, 20),
      maxTokensBudget: clamp(input.maxTokensBudget ?? DEFAULT_MAX_TOKENS_BUDGET, 1000, 1_000_000),
      sinks,
      lastRunAt: null,
      nextRunAt: nextRunISO(cron, timezone, nowDate),
      cronHuman: describeCron(cron),
      createdAt: nowISO,
      updatedAt: nowISO,
      rev: 1,
    };

    this.deps.repo.insert(routine);
    this.deps.scheduler.register(routine); // обновит next_run_at в БД
    return this.deps.repo.getOrThrow(routine.id);
  }

  update(id: string, input: UpdateRoutineInput): Routine {
    if (typeof input.rev !== "number") {
      throw new ValidationError("Не передан rev (версия для оптимистической блокировки).");
    }
    const existing = this.deps.repo.getOrThrow(id);

    const name = input.name !== undefined ? input.name.trim() : existing.name;
    const prompt = input.prompt !== undefined ? input.prompt.trim() : existing.prompt;
    const cron = input.cron !== undefined ? input.cron.trim() : existing.cron;
    const timezone =
      input.timezone !== undefined ? input.timezone.trim() : existing.timezone;

    if (!name) throw new ValidationError("Имя рутины не может быть пустым.");
    if (!prompt) throw new ValidationError("Промпт рутины не может быть пустым.");
    if (!isValidCron(cron, timezone)) {
      throw new ValidationError(`Некорректное расписание (cron): «${cron}».`);
    }

    const sinks = input.sinks !== undefined ? normalizeSinks(input.sinks) : existing.sinks;
    const nowDate = this.now();

    const merged: Routine = {
      ...existing,
      name,
      prompt,
      cron,
      timezone,
      enabled: input.enabled ?? existing.enabled,
      catchUpOnStart: input.catchUpOnStart ?? existing.catchUpOnStart,
      model: input.model !== undefined ? input.model.trim() : existing.model,
      maxIterations:
        input.maxIterations !== undefined
          ? clamp(input.maxIterations, 1, 20)
          : existing.maxIterations,
      maxTokensBudget:
        input.maxTokensBudget !== undefined
          ? clamp(input.maxTokensBudget, 1000, 1_000_000)
          : existing.maxTokensBudget,
      sinks,
      nextRunAt: nextRunISO(cron, timezone, nowDate),
      cronHuman: describeCron(cron),
      updatedAt: nowDate.toISOString(),
      rev: input.rev + 1,
    };

    this.deps.repo.replace(merged, input.rev); // 409 при устаревшем rev
    this.deps.scheduler.reschedule(merged);
    return this.deps.repo.getOrThrow(id);
  }

  setEnabled(id: string, enabled: boolean): Routine {
    const existing = this.deps.repo.getOrThrow(id);
    const nowDate = this.now();
    const merged: Routine = {
      ...existing,
      enabled,
      nextRunAt: enabled ? nextRunISO(existing.cron, existing.timezone, nowDate) : null,
      updatedAt: nowDate.toISOString(),
      rev: existing.rev + 1,
    };
    this.deps.repo.replace(merged, existing.rev);
    this.deps.scheduler.reschedule(merged);
    return this.deps.repo.getOrThrow(id);
  }

  remove(id: string): void {
    this.deps.repo.getOrThrow(id); // 404, если нет
    this.deps.scheduler.unregister(id);
    this.deps.repo.remove(id);
  }
}
