// runner.ts — выполнение одного прогона рутины:
//   1) взять ВСЕ инструменты подключённых MCP-серверов (generic, из McpHost),
//   2) прогнать агентный tool-loop через LLM (DeepSeek) → дайджест,
//   3) сохранить результат локально (история в приложении),
//   4) персистентно зафиксировать RunRecord и отметки рутины.
//
// Никаких привязок к конкретному MCP: набор инструментов задаёт McpHost (список
// MCP-серверов синхронизируется из приложения). Сохранение во внешние системы —
// через промпт рутины (агент сам вызовет нужный инструмент).
//
// Запись RunRecord со статусом `running` создаётся ДО вызова LLM, затем
// обновляется финальным статусом — чтобы прогон пережил краш/рестарт.

import type { Logger } from "../logger.js";
import { silentLogger } from "../logger.js";
import type { RoutinesRepo } from "../store/routinesRepo.js";
import type { RunsRepo } from "../store/runsRepo.js";
import type { SettingsService } from "../settings/settingsService.js";
import {
  MAX_OUTPUT_BYTES,
  type Provider,
  type Routine,
  type RunRecord,
  type RunTrigger,
} from "../domain/types.js";
import { estimateCostUsd } from "../domain/pricing.js";
import { nextRunISO } from "../domain/cron.js";
import { UpstreamError } from "../domain/errors.js";
import {
  HttpLlmClient,
  providerChatUrl,
  runToolLoop,
  type ChatMessage,
  type LlmCompletionClient,
  type ToolDef,
} from "./llm.js";
import type { McpHost, QualifiedTool } from "./mcpHost.js";

const RUNNER_SYSTEM_PROMPT = `Ты — агент-исполнитель рутины, работающий по расписанию. \
Тебе дан промпт рутины (что нужно сделать). При необходимости собери актуальные данные \
через доступные инструменты, затем сформируй АГРЕГИРОВАННЫЙ результат в Markdown: \
структурировано, по существу, с конкретикой (числа, списки, выводы, что важно). \
Действуй ЭКОНОМНО: предпочитай сводные инструменты (список) детальным по каждому элементу; \
не запрашивай детали по каждому элементу отдельно, если это не критично для результата. \
Как только данных достаточно — СРАЗУ выводи итог, не описывай дальнейшие шаги. \
НЕ показывай ход рассуждений, промежуточные заметки и расшифровки: первая строка \
ответа — уже часть итогового результата. Не выдумывай данные, которых нет. \
Верни ТОЛЬКО итоговый результат, без служебных пояснений и преамбул.`;

const DEFAULT_TEMPERATURE = 0.4;
const DEFAULT_MAX_TOKENS = 4096;

/** Фабрика LLM-клиента (подменяется в тестах). */
export type LlmClientFactory = (cfg: {
  provider: Provider;
  apiKey: string;
}) => LlmCompletionClient;

const defaultLlmClientFactory: LlmClientFactory = (cfg) =>
  new HttpLlmClient({
    url: providerChatUrl(cfg.provider),
    apiKey: cfg.apiKey,
    provider: cfg.provider,
  });

export interface RunnerDeps {
  routinesRepo: RoutinesRepo;
  runsRepo: RunsRepo;
  settings: SettingsService;
  mcpHost: McpHost;
  llmClientFactory?: LlmClientFactory;
  logger?: Logger;
  now?: () => Date;
  newId?: () => string;
  runTimeoutMs?: number;
}

class TimeoutError extends Error {}

function buildToolDef(tool: QualifiedTool): ToolDef {
  const schema =
    tool.inputSchema && typeof tool.inputSchema === "object"
      ? tool.inputSchema
      : { type: "object", properties: {} };
  return {
    type: "function",
    function: {
      name: tool.qualifiedName,
      description: tool.description || undefined,
      parameters: schema,
    },
  };
}

/**
 * Срезает ведущую «болтовню» модели перед результатом: если в тексте есть
 * Markdown-заголовок (строка вида `#`/`##` …), отбрасываем всё до первого такого
 * заголовка. Для дайджест-рутин это убирает преамбулы вроде «Теперь составлю
 * сводку…»; для ответов без заголовков — ничего не меняет (no-op).
 */
export function trimLeadingChatter(text: string): string {
  const lines = text.split("\n");
  // Первая «структурная» строка: Markdown-заголовок ИЛИ строка-заголовок с
  // ведущим эмодзи/жирным (частый формат дайджеста: «🗓 **Задачи на сегодня**»).
  const headingRe = /^(#{1,6}\s+\S|\*{0,2}[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}])/u;
  const idx = lines.findIndex((l) => headingRe.test(l.trim()));
  if (idx > 0) return lines.slice(idx).join("\n").trim();
  return text.trim();
}

/** Обрезает текст до лимита байт (UTF-8) с маркером усечения. */
function capOutput(text: string): string {
  const buf = Buffer.from(text, "utf8");
  if (buf.byteLength <= MAX_OUTPUT_BYTES) return text;
  const sliced = buf.subarray(0, MAX_OUTPUT_BYTES).toString("utf8");
  return `${sliced}\n\n…(результат усечён)`;
}

export class Runner {
  private readonly llmFactory: LlmClientFactory;
  private readonly host: McpHost;
  private readonly logger: Logger;
  private readonly now: () => Date;
  private readonly newId: () => string;
  private readonly runTimeoutMs: number;

  constructor(private readonly deps: RunnerDeps) {
    this.llmFactory = deps.llmClientFactory ?? defaultLlmClientFactory;
    this.host = deps.mcpHost;
    this.logger = deps.logger ?? silentLogger;
    this.now = deps.now ?? (() => new Date());
    this.newId = deps.newId ?? (() => crypto.randomUUID());
    this.runTimeoutMs = deps.runTimeoutMs ?? 120_000;
  }

  /**
   * Создаёт и СОХРАНЯЕТ запись прогона со статусом `running` (до вызова LLM).
   * Возвращается сразу, чтобы API мог отдать «running», а работа шла в фоне.
   */
  begin(routine: Routine, trigger: RunTrigger, scheduledFor: string | null): RunRecord {
    const run: RunRecord = {
      id: this.newId(),
      routineId: routine.id,
      trigger,
      status: "running",
      scheduledFor,
      startedAt: this.now().toISOString(),
      finishedAt: null,
      outputMarkdown: "",
      usage: { promptTokens: 0, completionTokens: 0, totalTokens: 0, costUsd: null },
      toolTranscript: [],
      sinkResults: [],
      error: null,
    };
    this.deps.runsRepo.insert(run);
    return run;
  }

  /** Полный прогон (begin + executeRun), с ожиданием. НЕ бросает. */
  async run(
    routine: Routine,
    trigger: RunTrigger,
    scheduledFor: string | null,
  ): Promise<RunRecord> {
    const run = this.begin(routine, trigger, scheduledFor);
    return this.executeRun(routine, run);
  }

  /** Выполняет работу по уже сохранённой записи `running` и финализирует её. */
  async executeRun(routine: Routine, run: RunRecord): Promise<RunRecord> {
    const settings = this.deps.settings.getInternal();
    if (!settings.llmApiKey) {
      run.status = "error";
      run.error =
        "LLM не настроен: задай провайдера и API-ключ в приложении (Настройки агента).";
      return this.finalize(run, routine);
    }

    const model = routine.model || settings.defaultModel || "deepseek-chat";

    try {
      const toolDefs = this.host.availableTools().map(buildToolDef);

      const messages: ChatMessage[] = [
        { role: "system", content: RUNNER_SYSTEM_PROMPT },
        { role: "user", content: routine.prompt },
      ];

      const client = this.llmFactory({ provider: settings.provider, apiKey: settings.llmApiKey });

      const loop = await this.withTimeout((signal) =>
        runToolLoop({
          client,
          model,
          temperature: DEFAULT_TEMPERATURE,
          maxTokens: DEFAULT_MAX_TOKENS,
          messages,
          tools: toolDefs,
          maxIterations: routine.maxIterations,
          maxTokensBudget: routine.maxTokensBudget,
          execute: this.executor(),
          signal,
        }),
      );

      run.outputMarkdown = capOutput(trimLeadingChatter(loop.text));
      run.usage = {
        promptTokens: loop.usage.promptTokens,
        completionTokens: loop.usage.completionTokens,
        totalTokens: loop.usage.totalTokens,
        costUsd: estimateCostUsd(model, loop.usage.promptTokens, loop.usage.completionTokens),
      };
      run.toolTranscript = loop.transcript;
      run.status = "ok";
    } catch (e) {
      if (e instanceof TimeoutError) {
        run.status = "timeout";
        run.error = "Превышено время выполнения прогона.";
      } else {
        run.status = "error";
        run.error = (e as Error).message;
      }
      this.logger.warn({ routineId: routine.id, err: run.error }, "routine run failed");
    }

    run.sinkResults = [{ kind: "vps_local", status: "ok" }];
    return this.finalize(run, routine);
  }

  /**
   * Интерактивный диалог по результату прогона: сидируем контекст дайджестом и
   * (опц.) даём инструменты. Возвращает ответ + расход. Бросает при отсутствии ключа.
   */
  async ask(params: {
    routine: Routine;
    run: RunRecord | null;
    messages: Array<{ role: "user" | "assistant"; content: string }>;
    allowTools: boolean;
  }): Promise<{ reply: string; usage: ReturnType<typeof zeroUsage>; toolTranscript: Array<{ name: string; ok: boolean }> }> {
    const settings = this.deps.settings.getInternal();
    if (!settings.llmApiKey) {
      throw new UpstreamError(
        "LLM не настроен: задай провайдера и API-ключ в приложении (Настройки агента).",
      );
    }
    const model = params.routine.model || settings.defaultModel || "deepseek-chat";
    const toolDefs = params.allowTools ? this.host.availableTools().map(buildToolDef) : [];

    const context = params.run?.outputMarkdown
      ? `Результат последнего прогона рутины «${params.routine.name}»:\n\n${params.run.outputMarkdown}`
      : `Рутина «${params.routine.name}». Готового результата прогона пока нет.`;

    const messages: ChatMessage[] = [
      {
        role: "system",
        content:
          `Ты — агент рутины «${params.routine.name}». Отвечай на вопросы пользователя по её работе и результату. ` +
          `Будь конкретным; при необходимости используй инструменты.\n\n${context}`,
      },
      ...params.messages.map((m) => ({ role: m.role, content: m.content })),
    ];

    const client = this.llmFactory({ provider: settings.provider, apiKey: settings.llmApiKey });
    const loop = await this.withTimeout((signal) =>
      runToolLoop({
        client,
        model,
        temperature: DEFAULT_TEMPERATURE,
        maxTokens: DEFAULT_MAX_TOKENS,
        messages,
        tools: toolDefs,
        maxIterations: params.allowTools ? 6 : 1,
        execute: this.executor(),
        signal,
      }),
    );
    return {
      reply: loop.text,
      usage: {
        promptTokens: loop.usage.promptTokens,
        completionTokens: loop.usage.completionTokens,
        totalTokens: loop.usage.totalTokens,
        costUsd: estimateCostUsd(model, loop.usage.promptTokens, loop.usage.completionTokens),
      },
      toolTranscript: loop.transcript,
    };
  }

  // ── приватное ───────────────────────────────────────────────────────────────

  private executor() {
    return (name: string, argsJSON: string): Promise<string> => this.host.call(name, argsJSON);
  }

  private async withTimeout<T>(fn: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const ac = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        ac.abort();
        reject(new TimeoutError());
      }, this.runTimeoutMs);
    });
    try {
      return await Promise.race([fn(ac.signal), timeout]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  private finalize(run: RunRecord, routine: Routine): RunRecord {
    run.finishedAt = this.now().toISOString();
    if (run.sinkResults.length === 0) {
      run.sinkResults = [{ kind: "vps_local", status: "ok" }];
    }
    this.deps.runsRepo.update(run);
    const next = nextRunISO(routine.cron, routine.timezone, this.now());
    this.deps.routinesRepo.updateRunStamps(routine.id, run.startedAt, next);
    return run;
  }
}

function zeroUsage() {
  return { promptTokens: 0, completionTokens: 0, totalTokens: 0, costUsd: null as number | null };
}
