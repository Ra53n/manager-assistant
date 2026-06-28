// orchestrator.ts — generic FSM-движок прогона рутины (порт `runStateMachine`/`runWave`
// из приложения, ChatViewModel.swift). НЕ привязан к YouGile: задача = routine.prompt,
// инструменты = любые из McpHost. Работает поверх существующего `runToolLoop`.
//
// Фазы: planning → execution (рой волнами ИЛИ последовательно) → validation
// (вердикт; назад в execution до лимита) → answer (финальный текст = дайджест прогона).
// Headless: без интерактива (пауза-на-плане/роутер/ASK_USER) и без инвариантов — это
// отдельные слои приложения, в v1 не портируются.

import type { Logger } from "../../logger.js";
import { silentLogger } from "../../logger.js";
import {
  runToolLoop,
  type LlmCompletionClient,
  type ToolDef,
  type Usage,
} from "../llm.js";
import {
  computeWaves,
  parseDeps,
  parsePlanSteps,
  parseVerdict,
  stripMarkers,
  wantsReplan,
} from "./parsers.js";
import {
  buildPrompt,
  subAgentPrompt,
  subAgentSystemPrompt,
  systemPromptFor,
  type PipelineState,
} from "./prompts.js";

// Таблица переходов FSM (как `TaskFSM.transitions`) — для самопроверки легальности.
const FSM_TRANSITIONS: Record<PipelineState, PipelineState[]> = {
  planning: ["execution"],
  execution: ["validation", "planning"],
  validation: ["answer", "execution", "planning"],
  answer: [],
};

const MAX_EXECUTION_RETRIES = 2; // validation → execution
const MAX_PLAN_RETRIES = 2; // execution → planning (REPLAN)
const MAX_TRANSITIONS = 60; // защитный потолок от раннавей-цикла (норм. прогон укладывается)

export interface PipelineParams {
  client: LlmCompletionClient;
  model: string;
  temperature: number;
  maxTokens: number;
  tools: ToolDef[];
  /** Исполнитель инструмента (как у runToolLoop): возвращает текст, не бросает. */
  execute: (name: string, argsJSON: string) => Promise<string>;
  /** Задача — это промпт рутины ([QUERY]). */
  task: string;
  /** Рой: гнать шаги волнами параллельных подагентов (иначе последовательно). */
  swarm: boolean;
  /** Размер чанка параллельности подагентов. */
  maxParallelAgents: number;
  /** Лимит tool-итераций на ОДИН под-вызов (этап/подагент). */
  perStepMaxIterations: number;
  signal?: AbortSignal;
  logger?: Logger;
}

export interface PipelineResult {
  text: string;
  usage: Usage;
  transcript: Array<{ name: string; ok: boolean }>;
}

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  const n = Math.max(1, size);
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

/**
 * Прогоняет задачу через конечный автомат plan→execution→validation→answer и возвращает
 * финальный текст + суммарный расход токенов + объединённый транскрипт вызовов.
 */
export async function runPipeline(params: PipelineParams): Promise<PipelineResult> {
  const logger = params.logger ?? silentLogger;
  const usage: Usage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
  const transcript: Array<{ name: string; ok: boolean }> = [];

  // Один под-вызов LLM (этап или подагент) поверх runToolLoop. Аккумулирует расход.
  // maxTokensBudget НЕ задаём — фазу ограничивает perStepMaxIterations + общий таймаут.
  const callPhase = async (systemPrompt: string, userPrompt: string): Promise<string> => {
    const r = await runToolLoop({
      client: params.client,
      model: params.model,
      temperature: params.temperature,
      maxTokens: params.maxTokens,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      tools: params.tools,
      maxIterations: params.perStepMaxIterations,
      execute: params.execute,
      signal: params.signal,
    });
    usage.promptTokens += r.usage.promptTokens;
    usage.completionTokens += r.usage.completionTokens;
    usage.totalTokens += r.usage.totalTokens;
    transcript.push(...r.transcript);
    return r.text;
  };

  // ── Состояние FSM (в памяти на прогон) ──────────────────────────────────────
  let state: PipelineState = "planning";
  let plan: string[] = [];
  let done: string[] = [];
  let stepResults: string[] = [];
  let stepDeps: Array<Set<number>> = [];
  let waves: number[][] = [];
  let waveIndex = 0;
  let step = 0;
  let validationResult = "";
  let executionRetries = 0;
  let planRetries = 0;
  let planFeedback = "";
  let lastText = "";

  const promptCtx = (current = "") => ({
    task: params.task,
    state,
    current,
    plan,
    done,
    step,
    total: plan.length,
    validationResult,
    executionRetries,
    planFeedback,
  });

  const go = (to: PipelineState) => {
    if (!FSM_TRANSITIONS[state].includes(to)) {
      // Не должно случаться (оркестратор ведёт переходы сам) — но ловим логические баги.
      throw new Error(`Недопустимый переход пайплайна ${state} → ${to}`);
    }
    state = to;
  };

  for (let t = 0; t < MAX_TRANSITIONS; t++) {
    if (params.signal?.aborted) break;

    if (state === "planning") {
      const raw = await callPhase(systemPromptFor("planning", params.swarm), buildPrompt(promptCtx()));
      lastText = raw;
      plan = parsePlanSteps(raw);
      done = [];
      step = 0;
      stepResults = [];
      waveIndex = 0;
      planFeedback = "";
      if (params.swarm) {
        stepDeps = parseDeps(raw, plan.length);
        waves = computeWaves(plan.length, stepDeps);
      } else {
        stepDeps = [];
        waves = [];
      }
      go("execution");
      continue;
    }

    if (state === "execution") {
      if (plan.length === 0) {
        go("planning");
        continue;
      }
      if (params.swarm) {
        const wave = waves[waveIndex] ?? [];
        const sys = subAgentSystemPrompt();
        const results = new Map<number, string>();
        // Волна — параллельно, чанками по maxParallelAgents.
        for (const part of chunk(wave, params.maxParallelAgents)) {
          const settled = await Promise.all(
            part.map(async (idx) => {
              const text = await callPhase(
                sys,
                subAgentPrompt({
                  task: params.task,
                  stepIndex: idx,
                  plan,
                  deps: stepDeps[idx] ?? new Set<number>(),
                  stepResults,
                }),
              );
              return { idx, text };
            }),
          );
          for (const { idx, text } of settled) results.set(idx, text);
        }
        const merged = [...results.values()].join("\n\n");
        // REPLAN от любого подагента → шаг назад в планирование (в пределах лимита).
        if (wantsReplan(merged) && planRetries < MAX_PLAN_RETRIES) {
          planRetries++;
          planFeedback = stripMarkers(merged);
          done = [];
          step = 0;
          stepResults = [];
          waveIndex = 0;
          go("planning");
          continue;
        }
        // Атомарный коммит волны: результаты по индексам + в done по порядку.
        if (stepResults.length < plan.length) {
          stepResults = stepResults.concat(Array(plan.length - stepResults.length).fill(""));
        }
        for (const idx of [...wave].sort((a, b) => a - b)) {
          const cleaned = stripMarkers(results.get(idx) ?? "");
          stepResults[idx] = cleaned;
          done.push(cleaned);
        }
        step = done.length;
        waveIndex++;
        if (waveIndex >= waves.length) go("validation");
        continue;
      } else {
        // Последовательный путь (рой выкл): полный [DONE] как контекст, один вызов на шаг.
        step = Math.min(step, plan.length - 1);
        const current = plan[step]!;
        const text = await callPhase(systemPromptFor("execution"), buildPrompt(promptCtx(current)));
        lastText = text;
        if (wantsReplan(text) && planRetries < MAX_PLAN_RETRIES) {
          planRetries++;
          planFeedback = stripMarkers(text);
          done = [];
          step = 0;
          go("planning");
          continue;
        }
        done.push(stripMarkers(text));
        step++;
        if (step >= plan.length) go("validation");
        continue;
      }
    }

    if (state === "validation") {
      if (done.length === 0) {
        go("execution");
        continue;
      }
      const text = await callPhase(systemPromptFor("validation"), buildPrompt(promptCtx()));
      lastText = text;
      validationResult = stripMarkers(text);
      if (parseVerdict(text)) {
        go("answer");
      } else if (executionRetries < MAX_EXECUTION_RETRIES) {
        executionRetries++;
        done = [];
        step = 0;
        waveIndex = 0;
        stepResults = [];
        go("execution");
      } else {
        go("answer"); // бюджет ретраев исчерпан — отдаём ответ как есть
      }
      continue;
    }

    // answer — терминал
    const text = await callPhase(systemPromptFor("answer"), buildPrompt(promptCtx()));
    return { text: stripMarkers(text), usage, transcript };
  }

  // Достигнут потолок переходов (или отмена между фазами) — отдаём лучшее, что есть.
  logger.warn({ state }, "пайплайн завершён по лимиту переходов/отмене — отдаём best-effort");
  const fallback = validationResult || done.join("\n\n") || stripMarkers(lastText);
  return { text: fallback, usage, transcript };
}
