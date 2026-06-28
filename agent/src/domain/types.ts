// types.ts — доменные типы агента рутин. Это КОНТРАКТ между сервером и
// macOS-приложением: Swift-DTO (RoutineModels.swift) зеркалят эти же поля.
// Менять осторожно: новые поля добавлять опциональными/с дефолтами, чтобы
// старые клиенты и старые записи в БД не падали (как и в Swift — ленивый декод).

// ─── Перечисления (строковые литералы + массивы для валидации) ──────────────

export const PROVIDERS = ["deepseek", "openrouter"] as const;
export type Provider = (typeof PROVIDERS)[number];

// Места сохранения. Сейчас встроено только локальное хранилище (история в приложении);
// сохранение во внешние системы делается ЧЕРЕЗ ПРОМПТ рутины (у агента есть все
// MCP-инструменты приложения). Никаких привязок к конкретному MCP.
export const SINK_KINDS = ["vps_local"] as const;
export type SinkKind = (typeof SINK_KINDS)[number];

export const RUN_TRIGGERS = ["schedule", "manual", "catchup"] as const;
export type RunTrigger = (typeof RUN_TRIGGERS)[number];

export const RUN_STATUSES = [
  "running",
  "ok",
  "error",
  "timeout",
  "skipped_overlap",
  "missed",
] as const;
export type RunStatus = (typeof RUN_STATUSES)[number];

// ─── Конфигурация места сохранения результата (sink) ────────────────────────

export interface SinkConfig {
  kind: SinkKind;
}

// ─── MCP-серверы (источник правды — приложение; синхронизируются на агент) ────

/** Конфиг MCP-сервера (зеркалит MCPServer приложения). Содержит секреты в args/env. */
export interface McpServerConfig {
  id: string;
  name: string;
  command: string; // напр. "npx"
  args: string[]; // напр. ["-y","mcp-remote","https://…/mcp","--header","Authorization: Bearer …"]
  env: Record<string, string>;
  enabled: boolean;
}

/** Публичный статус MCP-сервера (БЕЗ секретов): для GET /agent/mcp-servers. */
export interface McpServerPublic {
  id: string;
  name: string;
  command: string;
  enabled: boolean;
  connected: boolean;
  toolCount: number;
  error?: string | null;
}

// ─── Рутина ─────────────────────────────────────────────────────────────────

export interface Routine {
  id: string;
  name: string;
  prompt: string;
  cron: string;
  timezone: string;
  enabled: boolean;
  catchUpOnStart: boolean;
  model: string; // "" → берётся defaultModel из настроек агента
  maxIterations: number;
  maxTokensBudget: number;
  sinks: SinkConfig[];
  lastRunAt: string | null; // ISO-8601 UTC
  nextRunAt: string | null; // ISO-8601 UTC (вычисляется планировщиком)
  cronHuman: string; // человекочитаемое описание расписания (для UI)
  createdAt: string;
  updatedAt: string;
  rev: number; // счётчик оптимистической блокировки
}

/** Тело создания рутины (поля с дефолтами опциональны). */
export interface CreateRoutineInput {
  name: string;
  prompt: string;
  cron: string;
  timezone?: string;
  enabled?: boolean;
  catchUpOnStart?: boolean;
  model?: string;
  maxIterations?: number;
  maxTokensBudget?: number;
  sinks?: SinkConfig[];
}

/** Тело обновления рутины. rev обязателен (оптимистическая блокировка). */
export interface UpdateRoutineInput extends Partial<CreateRoutineInput> {
  rev: number;
}

// ─── Запись прогона ──────────────────────────────────────────────────────────

export interface RunUsage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  costUsd: number | null;
}

export interface ToolCallRecord {
  name: string;
  ok: boolean;
}

export interface SinkResult {
  kind: SinkKind;
  status: "ok" | "error" | "skipped";
  error?: string | null;
  externalRef?: string | null;
}

export interface RunRecord {
  id: string;
  routineId: string;
  trigger: RunTrigger;
  status: RunStatus;
  scheduledFor: string | null;
  startedAt: string;
  finishedAt: string | null;
  outputMarkdown: string;
  usage: RunUsage;
  toolTranscript: ToolCallRecord[];
  sinkResults: SinkResult[];
  error: string | null;
}

/** Краткая запись прогона для списка истории (без тяжёлого outputMarkdown). */
export type RunSummary = Omit<RunRecord, "outputMarkdown" | "toolTranscript">;

// ─── Настройки агента (server-side; задаются из приложения) ──────────────────

/** Полные настройки С СЕКРЕТАМИ — только внутри сервера, наружу не отдаются. */
export interface AgentSettings {
  provider: Provider;
  llmApiKey: string;
  defaultModel: string;
  defaultTimezone: string;
  updatedAt: string;
}

/** Публичное представление настроек: секреты замаскированы (паттерн write-only). */
export interface AgentSettingsPublic {
  provider: Provider;
  defaultModel: string;
  defaultTimezone: string;
  hasLlmKey: boolean;
  llmKeyHint: string; // напр. "…ab12" или ""
  updatedAt: string;
}

/** Тело PUT /agent/settings. Секреты применяются ТОЛЬКО если переданы непустыми. */
export interface UpdateAgentSettingsInput {
  provider?: Provider;
  llmApiKey?: string;
  defaultModel?: string;
  defaultTimezone?: string;
}

// ─── Дефолты ─────────────────────────────────────────────────────────────────

export const DEFAULT_MAX_ITERATIONS = 8;
export const DEFAULT_MAX_TOKENS_BUDGET = 60000;
export const MAX_OUTPUT_BYTES = 256 * 1024; // кап размера дайджеста в БД

export function defaultSinks(): SinkConfig[] {
  return [{ kind: "vps_local" }];
}
