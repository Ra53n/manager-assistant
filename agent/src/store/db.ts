// db.ts — открытие SQLite (better-sqlite3) + миграции.
//
// Краш-устойчивость: WAL-режим, синхронные ACID-записи. Параллельные чтения API
// не мешают записи прогонов планировщиком. Версия схемы — в PRAGMA user_version;
// миграции только вперёд (forward-only), как «старые данные не должны падать».

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type DB = Database.Database;

/** SQL-миграции по порядку. Индекс массива + 1 = целевая user_version. */
const MIGRATIONS: string[] = [
  // ── v1: исходная схема ─────────────────────────────────────────────────────
  `
  CREATE TABLE routines (
    id                TEXT PRIMARY KEY,
    name              TEXT NOT NULL,
    prompt            TEXT NOT NULL,
    cron              TEXT NOT NULL,
    timezone          TEXT NOT NULL,
    enabled           INTEGER NOT NULL DEFAULT 1,
    catch_up_on_start INTEGER NOT NULL DEFAULT 0,
    model             TEXT NOT NULL DEFAULT '',
    max_iterations    INTEGER NOT NULL DEFAULT 6,
    max_tokens_budget INTEGER NOT NULL DEFAULT 20000,
    sinks_json        TEXT NOT NULL DEFAULT '[]',
    last_run_at       TEXT,
    next_run_at       TEXT,
    created_at        TEXT NOT NULL,
    updated_at        TEXT NOT NULL,
    rev               INTEGER NOT NULL DEFAULT 1
  );

  CREATE TABLE runs (
    id                   TEXT PRIMARY KEY,
    routine_id           TEXT NOT NULL,
    trigger              TEXT NOT NULL,
    status               TEXT NOT NULL,
    scheduled_for        TEXT,
    started_at           TEXT NOT NULL,
    finished_at          TEXT,
    output_md            TEXT NOT NULL DEFAULT '',
    prompt_tokens        INTEGER NOT NULL DEFAULT 0,
    completion_tokens    INTEGER NOT NULL DEFAULT 0,
    total_tokens         INTEGER NOT NULL DEFAULT 0,
    cost_usd             REAL,
    tool_transcript_json TEXT NOT NULL DEFAULT '[]',
    sink_results_json    TEXT NOT NULL DEFAULT '[]',
    error                TEXT
  );

  CREATE INDEX idx_runs_routine_started ON runs (routine_id, started_at DESC, id DESC);

  CREATE TABLE settings (
    id                INTEGER PRIMARY KEY CHECK (id = 1),
    provider          TEXT NOT NULL DEFAULT 'deepseek',
    llm_api_key       TEXT NOT NULL DEFAULT '',
    default_model     TEXT NOT NULL DEFAULT 'deepseek-chat',
    default_timezone  TEXT NOT NULL DEFAULT 'Europe/Moscow',
    yougile_mcp_url   TEXT NOT NULL DEFAULT 'http://127.0.0.1:3000/mcp',
    yougile_mcp_token TEXT NOT NULL DEFAULT '',
    updated_at        TEXT NOT NULL DEFAULT ''
  );

  INSERT INTO settings (id, updated_at) VALUES (1, '');
  `,

  // ── v2: MCP-серверы (синхронизируются из приложения; источник правды — приложение) ──
  `
  CREATE TABLE mcp_servers (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT '',
    command    TEXT NOT NULL DEFAULT 'npx',
    args_json  TEXT NOT NULL DEFAULT '[]',
    env_json   TEXT NOT NULL DEFAULT '{}',
    enabled    INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT ''
  );
  `,

  // ── v3: режим исполнения рутины (simple | pipeline) + параметры роя ──────────
  // Дефолт mode='simple' для СУЩЕСТВУЮЩИХ рутин — чтобы их поведение не изменилось.
  // Новые рутины из приложения присылают свой mode (по умолчанию pipeline).
  `
  ALTER TABLE routines ADD COLUMN mode TEXT NOT NULL DEFAULT 'simple';
  ALTER TABLE routines ADD COLUMN swarm INTEGER NOT NULL DEFAULT 1;
  ALTER TABLE routines ADD COLUMN max_parallel_agents INTEGER NOT NULL DEFAULT 3;
  `,
];

/** Применяет недостающие миграции (idempotent). */
function migrate(db: DB): void {
  const current = db.pragma("user_version", { simple: true }) as number;
  for (let v = current; v < MIGRATIONS.length; v++) {
    const sql = MIGRATIONS[v]!;
    const tx = db.transaction(() => {
      db.exec(sql);
      db.pragma(`user_version = ${v + 1}`);
    });
    tx();
  }
}

/**
 * Открывает БД по пути (или ":memory:" для тестов), включает WAL и накатывает
 * миграции. Создаёт каталог при необходимости.
 */
export function openDb(path: string): DB {
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  migrate(db);
  return db;
}
