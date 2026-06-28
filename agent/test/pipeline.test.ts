import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { DB } from "../src/store/db.js";
import { Runner } from "../src/runner/runner.js";
import type { ChatCompletion, ChatRequest } from "../src/runner/llm.js";
import { makeDb, makeRepos, buildRoutine, stubHost, qtool, seqId } from "./helpers.js";

let db: DB;
let repos: ReturnType<typeof makeRepos>;
const NOW = "2026-06-27T09:00:00.000Z";

function makeRunner(over: Partial<ConstructorParameters<typeof Runner>[0]>) {
  return new Runner({
    routinesRepo: repos.routinesRepo,
    runsRepo: repos.runsRepo,
    settings: repos.settings,
    mcpHost: stubHost(),
    newId: seqId("run"),
    now: () => new Date(NOW),
    ...over,
  });
}

const usage = { promptTokens: 10, completionTokens: 5, totalTokens: 15 };
function text(content: string): ChatCompletion {
  return { message: { content }, usage };
}

/**
 * LLM-заглушка, маршрутизирующая ответ ПО РОЛИ из системного промпта, а не по порядку
 * вызова — так параллельные подагенты роя не делают тест флакающим. validation может быть
 * последовательностью (для теста ретрая).
 */
function pipelineLlm(opts: {
  plan: string;
  exec?: (userMsg: string) => ChatCompletion;
  validation: string | string[];
  answer: string;
}) {
  const counts = { plan: 0, exec: 0, validation: 0, answer: 0 };
  let validationCall = 0;
  const stub = {
    calls: 0,
    counts,
    async chat(req: ChatRequest): Promise<ChatCompletion> {
      stub.calls++;
      const sys = String(req.messages.find((m) => m.role === "system")?.content ?? "");
      const user = String([...req.messages].reverse().find((m) => m.role === "user")?.content ?? "");
      if (sys.includes("планировщик")) {
        counts.plan++;
        return text(opts.plan);
      }
      if (sys.includes("проверяющий")) {
        const seq = Array.isArray(opts.validation) ? opts.validation : [opts.validation];
        const v = seq[Math.min(validationCall, seq.length - 1)]!;
        validationCall++;
        counts.validation++;
        return text(v);
      }
      if (sys.includes("ФИНАЛЬНЫЙ ОТВЕТ")) {
        counts.answer++;
        return text(opts.answer);
      }
      // иначе — исполнитель (подагент роя ИЛИ последовательный шаг)
      counts.exec++;
      return opts.exec ? opts.exec(user) : text("Результат шага");
    },
  };
  return stub;
}

beforeEach(() => {
  db = makeDb();
  repos = makeRepos(db);
  repos.settings.update({ provider: "deepseek", llmApiKey: "sk-test" }, NOW);
});
afterEach(() => db.close());

describe("Runner pipeline mode", () => {
  it("plan → рой (волны) → проверка → ответ, за один прогон", async () => {
    const routine = buildRoutine({ mode: "pipeline", swarm: true, maxParallelAgents: 2 });
    repos.routinesRepo.insert(routine);
    const llm = pipelineLlm({
      plan: "1. Шаг A\n2. Шаг B\n3. Шаг C\nЗАВИСИМОСТИ:\n3: 1,2",
      validation: "Всё на месте\nВЕРДИКТ: ВЫПОЛНЕНО",
      answer: "# Итог\nготово",
    });
    const run = await makeRunner({ llmClientFactory: () => llm }).run(routine, "manual", null);

    expect(run.status).toBe("ok");
    expect(run.outputMarkdown).toContain("Итог");
    // 1 план + 3 подагента + 1 проверка + 1 ответ
    expect(llm.counts).toEqual({ plan: 1, exec: 3, validation: 1, answer: 1 });
    // расход просуммирован по всем 6 под-вызовам
    expect(run.usage.totalTokens).toBe(6 * 15);
  });

  it("последовательный путь (рой выкл) тоже доводит до ответа", async () => {
    const routine = buildRoutine({ mode: "pipeline", swarm: false });
    repos.routinesRepo.insert(routine);
    const llm = pipelineLlm({
      plan: "1. Первый шаг\n2. Второй шаг",
      validation: "ВЕРДИКТ: ВЫПОЛНЕНО",
      answer: "Готовый ответ",
    });
    const run = await makeRunner({ llmClientFactory: () => llm }).run(routine, "manual", null);

    expect(run.status).toBe("ok");
    expect(run.outputMarkdown).toBe("Готовый ответ");
    expect(llm.counts).toEqual({ plan: 1, exec: 2, validation: 1, answer: 1 });
  });

  it("вердикт «НЕ ВЫПОЛНЕНО» → повтор execution, затем ответ", async () => {
    const routine = buildRoutine({ mode: "pipeline", swarm: false });
    repos.routinesRepo.insert(routine);
    const llm = pipelineLlm({
      plan: "1. Единственный шаг",
      validation: ["ВЕРДИКТ: НЕ ВЫПОЛНЕНО", "ВЕРДИКТ: ВЫПОЛНЕНО"],
      answer: "Финал",
    });
    const run = await makeRunner({ llmClientFactory: () => llm }).run(routine, "manual", null);

    expect(run.status).toBe("ok");
    // execution прогнан дважды (исходно + повтор после провала проверки)
    expect(llm.counts.exec).toBe(2);
    expect(llm.counts.validation).toBe(2);
    expect(llm.counts.answer).toBe(1);
  });

  it("подагент может вызвать инструмент MCP в своём tool-loop", async () => {
    const routine = buildRoutine({ mode: "pipeline", swarm: false });
    repos.routinesRepo.insert(routine);
    const host = stubHost({ tools: [qtool("yougile__list_tasks")], onCall: () => "2 задачи" });
    let execCalls = 0;
    const llm = {
      calls: 0,
      async chat(req: ChatRequest): Promise<ChatCompletion> {
        this.calls++;
        const sys = String(req.messages.find((m) => m.role === "system")?.content ?? "");
        if (sys.includes("планировщик")) return text("1. Собрать задачи");
        if (sys.includes("проверяющий")) return text("ВЕРДИКТ: ВЫПОЛНЕНО");
        if (sys.includes("ФИНАЛЬНЫЙ ОТВЕТ")) return text("Итог: 2 задачи");
        // исполнитель: первый вызов — tool_call, второй — текст
        execCalls++;
        if (execCalls === 1) {
          return {
            message: {
              content: null,
              tool_calls: [
                { id: "c1", type: "function", function: { name: "yougile__list_tasks", arguments: "{}" } },
              ],
            },
            usage,
          };
        }
        return text("Задачи собраны\nNEXT_STEP");
      },
    };
    const run = await makeRunner({ llmClientFactory: () => llm, mcpHost: host }).run(
      routine,
      "manual",
      null,
    );

    expect(run.status).toBe("ok");
    expect(host.calls.map((c) => c.name)).toEqual(["yougile__list_tasks"]);
    expect(run.toolTranscript).toContainEqual({ name: "yougile__list_tasks", ok: true });
  });

  it("таймаут пайплайна → статус timeout", async () => {
    const routine = buildRoutine({ mode: "pipeline" });
    repos.routinesRepo.insert(routine);
    const hangingLlm = { calls: 0, chat: () => new Promise<never>(() => {}) };
    const run = await makeRunner({
      pipelineTimeoutMs: 50,
      llmClientFactory: () => hangingLlm as never,
    }).run(routine, "manual", null);
    expect(run.status).toBe("timeout");
  });
});
