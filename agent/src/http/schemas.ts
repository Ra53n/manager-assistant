// schemas.ts — JSON-схемы валидации тел/параметров запросов (Fastify+ajv).
// Это и есть машиночитаемый КОНТРАКТ API. Семантику (валидность cron, синков,
// rev) дополнительно проверяют сервисы. additionalProperties:true — снисходительно
// к будущим полям (как ленивый декод в Swift).

const sinkSchema = {
  type: "object",
  additionalProperties: true,
  properties: {
    kind: { type: "string" },
    mode: { type: "string" },
    boardId: { type: ["string", "null"] },
    columnId: { type: ["string", "null"] },
    taskId: { type: ["string", "null"] },
    titleTemplate: { type: ["string", "null"] },
    bodyTemplate: { type: ["string", "null"] },
  },
} as const;

export const createRoutineBody = {
  type: "object",
  additionalProperties: true,
  required: ["name", "prompt", "cron"],
  properties: {
    name: { type: "string" },
    prompt: { type: "string" },
    cron: { type: "string" },
    timezone: { type: "string" },
    enabled: { type: "boolean" },
    catchUpOnStart: { type: "boolean" },
    model: { type: "string" },
    maxIterations: { type: "number" },
    maxTokensBudget: { type: "number" },
    sinks: { type: "array", items: sinkSchema },
  },
} as const;

export const updateRoutineBody = {
  type: "object",
  additionalProperties: true,
  required: ["rev"],
  properties: {
    rev: { type: "number" },
    name: { type: "string" },
    prompt: { type: "string" },
    cron: { type: "string" },
    timezone: { type: "string" },
    enabled: { type: "boolean" },
    catchUpOnStart: { type: "boolean" },
    model: { type: "string" },
    maxIterations: { type: "number" },
    maxTokensBudget: { type: "number" },
    sinks: { type: "array", items: sinkSchema },
  },
} as const;

export const enableBody = {
  type: "object",
  required: ["enabled"],
  properties: { enabled: { type: "boolean" } },
} as const;

export const settingsBody = {
  type: "object",
  additionalProperties: true,
  properties: {
    provider: { type: "string" },
    llmApiKey: { type: "string" },
    defaultModel: { type: "string" },
    defaultTimezone: { type: "string" },
  },
} as const;

const mcpServerSchema = {
  type: "object",
  additionalProperties: true,
  required: ["id", "name", "command"],
  properties: {
    id: { type: "string" },
    name: { type: "string" },
    command: { type: "string" },
    args: { type: "array", items: { type: "string" } },
    env: { type: "object", additionalProperties: { type: "string" } },
    enabled: { type: "boolean" },
  },
} as const;

export const mcpServersBody = {
  type: "object",
  required: ["servers"],
  properties: {
    servers: { type: "array", items: mcpServerSchema },
  },
} as const;

export const askBody = {
  type: "object",
  required: ["routineId", "messages"],
  properties: {
    routineId: { type: "string" },
    runId: { type: ["string", "null"] },
    allowTools: { type: "boolean" },
    messages: {
      type: "array",
      items: {
        type: "object",
        required: ["role", "content"],
        properties: {
          role: { type: "string", enum: ["user", "assistant"] },
          content: { type: "string" },
        },
      },
    },
  },
} as const;

export const runsQuery = {
  type: "object",
  properties: {
    limit: { type: "number" },
    cursor: { type: "string" },
  },
} as const;
