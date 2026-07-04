// routinesRepo.ts — хранение рутин. Оптимистическая блокировка через rev:
// обновление проходит только если переданный rev совпадает с текущим в БД.

import type { DB } from "./db.js";
import type { Routine, RoutineMode, SinkConfig } from "../domain/types.js";
import { ROUTINE_MODES } from "../domain/types.js";
import { ConflictError, NotFoundError } from "../domain/errors.js";

/** Снисходительный декод режима: неизвестное значение → "simple". */
function parseMode(v: string): RoutineMode {
  return (ROUTINE_MODES as readonly string[]).includes(v) ? (v as RoutineMode) : "simple";
}

interface RoutineRow {
  id: string;
  name: string;
  prompt: string;
  cron: string;
  timezone: string;
  enabled: number;
  catch_up_on_start: number;
  model: string;
  max_iterations: number;
  max_tokens_budget: number;
  mode: string;
  swarm: number;
  max_parallel_agents: number;
  sinks_json: string;
  last_run_at: string | null;
  next_run_at: string | null;
  created_at: string;
  updated_at: string;
  rev: number;
}

function parseSinks(json: string): SinkConfig[] {
  try {
    const v = JSON.parse(json);
    return Array.isArray(v) ? (v as SinkConfig[]) : [];
  } catch {
    return [];
  }
}

function rowToRoutine(row: RoutineRow, cronHuman: string): Routine {
  return {
    id: row.id,
    name: row.name,
    prompt: row.prompt,
    cron: row.cron,
    timezone: row.timezone,
    enabled: row.enabled === 1,
    catchUpOnStart: row.catch_up_on_start === 1,
    model: row.model,
    maxIterations: row.max_iterations,
    maxTokensBudget: row.max_tokens_budget,
    mode: parseMode(row.mode),
    swarm: row.swarm === 1,
    maxParallelAgents: row.max_parallel_agents,
    sinks: parseSinks(row.sinks_json),
    lastRunAt: row.last_run_at,
    nextRunAt: row.next_run_at,
    cronHuman,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    rev: row.rev,
  };
}

export class RoutinesRepo {
  // describeCron инжектируется, чтобы repo не зависел от croner напрямую
  // (и чтобы человекочитаемое поле считалось единообразно).
  constructor(
    private readonly db: DB,
    private readonly describeCron: (pattern: string) => string,
  ) {}

  private map(row: RoutineRow): Routine {
    return rowToRoutine(row, this.describeCron(row.cron));
  }

  insert(r: Routine): Routine {
    this.db
      .prepare(
        `INSERT INTO routines
         (id, name, prompt, cron, timezone, enabled, catch_up_on_start, model,
          max_iterations, max_tokens_budget, mode, swarm, max_parallel_agents,
          sinks_json, last_run_at, next_run_at,
          created_at, updated_at, rev)
         VALUES
         (@id, @name, @prompt, @cron, @timezone, @enabled, @catch_up_on_start, @model,
          @max_iterations, @max_tokens_budget, @mode, @swarm, @max_parallel_agents,
          @sinks_json, @last_run_at, @next_run_at,
          @created_at, @updated_at, @rev)`,
      )
      .run({
        id: r.id,
        name: r.name,
        prompt: r.prompt,
        cron: r.cron,
        timezone: r.timezone,
        enabled: r.enabled ? 1 : 0,
        catch_up_on_start: r.catchUpOnStart ? 1 : 0,
        model: r.model,
        max_iterations: r.maxIterations,
        max_tokens_budget: r.maxTokensBudget,
        mode: r.mode,
        swarm: r.swarm ? 1 : 0,
        max_parallel_agents: r.maxParallelAgents,
        sinks_json: JSON.stringify(r.sinks),
        last_run_at: r.lastRunAt,
        next_run_at: r.nextRunAt,
        created_at: r.createdAt,
        updated_at: r.updatedAt,
        rev: r.rev,
      });
    return r;
  }

  get(id: string): Routine | null {
    const row = this.db.prepare(`SELECT * FROM routines WHERE id = ?`).get(id) as
      | RoutineRow
      | undefined;
    return row ? this.map(row) : null;
  }

  getOrThrow(id: string): Routine {
    const r = this.get(id);
    if (!r) throw new NotFoundError(`Рутина не найдена: ${id}`);
    return r;
  }

  list(): Routine[] {
    const rows = this.db
      .prepare(`SELECT * FROM routines ORDER BY created_at DESC`)
      .all() as RoutineRow[];
    return rows.map((row) => this.map(row));
  }

  /**
   * Полная замена рутины с проверкой оптимистической блокировки: проходит только
   * если текущий rev == expectedRev. Новый объект `r` уже несёт rev=expectedRev+1.
   */
  replace(r: Routine, expectedRev: number): Routine {
    const info = this.db
      .prepare(
        `UPDATE routines SET
           name=@name, prompt=@prompt, cron=@cron, timezone=@timezone,
           enabled=@enabled, catch_up_on_start=@catch_up_on_start, model=@model,
           max_iterations=@max_iterations, max_tokens_budget=@max_tokens_budget,
           mode=@mode, swarm=@swarm, max_parallel_agents=@max_parallel_agents,
           sinks_json=@sinks_json, last_run_at=@last_run_at, next_run_at=@next_run_at,
           updated_at=@updated_at, rev=@rev
         WHERE id=@id AND rev=@expected_rev`,
      )
      .run({
        id: r.id,
        name: r.name,
        prompt: r.prompt,
        cron: r.cron,
        timezone: r.timezone,
        enabled: r.enabled ? 1 : 0,
        catch_up_on_start: r.catchUpOnStart ? 1 : 0,
        model: r.model,
        max_iterations: r.maxIterations,
        max_tokens_budget: r.maxTokensBudget,
        mode: r.mode,
        swarm: r.swarm ? 1 : 0,
        max_parallel_agents: r.maxParallelAgents,
        sinks_json: JSON.stringify(r.sinks),
        last_run_at: r.lastRunAt,
        next_run_at: r.nextRunAt,
        updated_at: r.updatedAt,
        rev: r.rev,
        expected_rev: expectedRev,
      });
    if (info.changes === 0) {
      // Различаем «нет рутины» и «устаревший rev».
      if (!this.get(r.id)) throw new NotFoundError(`Рутина не найдена: ${r.id}`);
      throw new ConflictError(
        `Рутина изменена в другом месте (ожидался rev=${expectedRev}).`,
        { id: r.id, expectedRev },
      );
    }
    return r;
  }

  /** Обновляет служебные отметки запусков (БЕЗ смены rev — это не правка пользователя). */
  updateRunStamps(id: string, lastRunAt: string | null, nextRunAt: string | null): void {
    this.db
      .prepare(`UPDATE routines SET last_run_at=?, next_run_at=? WHERE id=?`)
      .run(lastRunAt, nextRunAt, id);
  }

  remove(id: string): boolean {
    const tx = this.db.transaction((rid: string) => {
      this.db.prepare(`DELETE FROM runs WHERE routine_id=?`).run(rid);
      return this.db.prepare(`DELETE FROM routines WHERE id=?`).run(rid).changes;
    });
    return (tx(id) as number) > 0;
  }
}
