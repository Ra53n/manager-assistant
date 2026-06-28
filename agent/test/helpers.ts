// helpers.ts — фабрики для тестов: in-memory БД, репозитории, заглушки LLM и MCP,
// строители доменных объектов, фиксированные часы/идентификаторы. Без сети.

import { openDb, type DB } from "../src/store/db.js";
import { RoutinesRepo } from "../src/store/routinesRepo.js";
import { RunsRepo } from "../src/store/runsRepo.js";
import { SettingsRepo } from "../src/store/settingsRepo.js";
import { SettingsService } from "../src/settings/settingsService.js";
import { describeCron } from "../src/domain/cron.js";
import type { ChatCompletion, LlmCompletionClient } from "../src/runner/llm.js";
import type { McpHost, QualifiedTool } from "../src/runner/mcpHost.js";
import type { Routine, RunRecord } from "../src/domain/types.js";

export function makeDb(): DB {
  return openDb(":memory:");
}

export function makeRepos(db: DB) {
  const settingsRepo = new SettingsRepo(db);
  return {
    routinesRepo: new RoutinesRepo(db, describeCron),
    runsRepo: new RunsRepo(db),
    settingsRepo,
    settings: new SettingsService(settingsRepo),
  };
}

// ── Заглушка LLM ──────────────────────────────────────────────────────────────

export interface StubLlm extends LlmCompletionClient {
  calls: number;
}

/** Возвращает шаги по очереди; после последнего повторяет его. */
export function stubLlm(steps: ChatCompletion[]): StubLlm {
  const stub: StubLlm = {
    calls: 0,
    async chat() {
      const idx = Math.min(stub.calls, steps.length - 1);
      stub.calls++;
      return steps[idx]!;
    },
  };
  return stub;
}

const ZERO_USAGE = { promptTokens: 10, completionTokens: 5, totalTokens: 15 };

export function textCompletion(
  text: string,
  usage = ZERO_USAGE,
): ChatCompletion {
  return { message: { content: text }, usage };
}

export function toolCallCompletion(
  name: string,
  args: unknown,
  usage = ZERO_USAGE,
): ChatCompletion {
  return {
    message: {
      content: null,
      tool_calls: [
        { id: "call-1", type: "function", function: { name, arguments: JSON.stringify(args) } },
      ],
    },
    usage,
  };
}

// ── Заглушка MCP-хоста ────────────────────────────────────────────────────────

export interface StubHost extends McpHost {
  calls: Array<{ name: string; argsJSON: string }>;
  closed: boolean;
}

export function stubHost(opts: {
  tools?: QualifiedTool[];
  onCall?: (name: string, argsJSON: string) => string;
} = {}): StubHost {
  const h: StubHost = {
    calls: [],
    closed: false,
    async refresh() {},
    availableTools() {
      return opts.tools ?? [];
    },
    async call(name, argsJSON) {
      h.calls.push({ name, argsJSON });
      return opts.onCall ? opts.onCall(name, argsJSON) : "(ok)";
    },
    statuses() {
      return [];
    },
    async close() {
      h.closed = true;
    },
  };
  return h;
}

export function qtool(qualifiedName: string): QualifiedTool {
  return { qualifiedName, description: "", inputSchema: { type: "object" } };
}

// ── Часы / идентификаторы ─────────────────────────────────────────────────────

export function fixedClock(iso: string): () => Date {
  return () => new Date(iso);
}

export function seqId(prefix = "id"): () => string {
  let n = 0;
  return () => `${prefix}-${++n}`;
}

// ── Строители доменных объектов ───────────────────────────────────────────────

export function buildRoutine(over: Partial<Routine> = {}): Routine {
  const now = "2026-06-27T00:00:00.000Z";
  return {
    id: "r1",
    name: "Тест-рутина",
    prompt: "Собери сводку",
    cron: "0 9 * * *",
    timezone: "Europe/Moscow",
    enabled: true,
    catchUpOnStart: false,
    model: "",
    maxIterations: 6,
    maxTokensBudget: 20000,
    sinks: [{ kind: "vps_local" }],
    lastRunAt: null,
    nextRunAt: null,
    cronHuman: "",
    createdAt: now,
    updatedAt: now,
    rev: 1,
    ...over,
  };
}

export function buildRun(over: Partial<RunRecord> = {}): RunRecord {
  const now = "2026-06-27T09:00:00.000Z";
  return {
    id: "run1",
    routineId: "r1",
    trigger: "manual",
    status: "running",
    scheduledFor: null,
    startedAt: now,
    finishedAt: null,
    outputMarkdown: "",
    usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0, costUsd: null },
    toolTranscript: [],
    sinkResults: [],
    error: null,
    ...over,
  };
}
