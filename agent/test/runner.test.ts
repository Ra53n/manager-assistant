import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { DB } from "../src/store/db.js";
import { Runner } from "../src/runner/runner.js";
import {
  makeDb,
  makeRepos,
  buildRoutine,
  stubLlm,
  stubHost,
  qtool,
  textCompletion,
  toolCallCompletion,
  seqId,
} from "./helpers.js";

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

beforeEach(() => {
  db = makeDb();
  repos = makeRepos(db);
  repos.settings.update({ provider: "deepseek", llmApiKey: "sk-test" }, NOW);
});
afterEach(() => db.close());

describe("Runner.run", () => {
  it("простой прогон даёт дайджест и сохраняет запись (vps_local)", async () => {
    const routine = buildRoutine();
    repos.routinesRepo.insert(routine);
    const runner = makeRunner({
      llmClientFactory: () => stubLlm([textCompletion("# Дайджест\nвсё ок")]),
      mcpHost: stubHost(),
    });

    const run = await runner.run(routine, "manual", null);
    expect(run.status).toBe("ok");
    expect(run.outputMarkdown).toContain("Дайджест");
    expect(run.usage.totalTokens).toBe(15);
    expect(run.sinkResults).toEqual([{ kind: "vps_local", status: "ok" }]);
    expect(repos.runsRepo.get(run.id)?.status).toBe("ok");
    expect(repos.routinesRepo.get(routine.id)?.lastRunAt).toBe(run.startedAt);
  });

  it("tool-loop: вызывает инструмент из хоста, затем отвечает текстом", async () => {
    const routine = buildRoutine();
    repos.routinesRepo.insert(routine);
    const host = stubHost({ tools: [qtool("yougile__list_tasks")], onCall: () => "2 задачи" });
    const llm = stubLlm([
      toolCallCompletion("yougile__list_tasks", { column_id: "c1" }),
      textCompletion("Задач: 2"),
    ]);
    const runner = makeRunner({ llmClientFactory: () => llm, mcpHost: host });

    const run = await runner.run(routine, "schedule", NOW);
    expect(run.status).toBe("ok");
    expect(run.outputMarkdown).toBe("Задач: 2");
    expect(llm.calls).toBe(2);
    expect(host.calls.map((c) => c.name)).toEqual(["yougile__list_tasks"]);
    expect(run.toolTranscript).toEqual([{ name: "yougile__list_tasks", ok: true }]);
  });

  it("action-режим: НЕ обрывается после первого батча — гонит все tool-раунды до текста", async () => {
    const routine = buildRoutine({ mode: "action" });
    repos.routinesRepo.insert(routine);
    const host = stubHost({ tools: [qtool("srv__do")], onCall: () => "ok" });
    // 3 последовательных вызова инструмента, затем финальный текст
    const llm = stubLlm([
      toolCallCompletion("srv__do", { step: 1 }),
      toolCallCompletion("srv__do", { step: 2 }),
      toolCallCompletion("srv__do", { step: 3 }),
      textCompletion("Процедура выполнена"),
    ]);
    const runner = makeRunner({ llmClientFactory: () => llm, mcpHost: host });

    const run = await runner.run(routine, "manual", null);
    expect(run.status).toBe("ok");
    expect(run.outputMarkdown).toBe("Процедура выполнена");
    expect(host.calls.length).toBe(3); // все три действия выполнены за ОДИН прогон
    expect(llm.calls).toBe(4);
  });

  it("action-режим использует системный промпт «доводи процедуру до конца», не дайджестовый", async () => {
    const routine = buildRoutine({ mode: "action" });
    repos.routinesRepo.insert(routine);
    let sys = "";
    const capturing = {
      calls: 0,
      async chat(req: { messages: Array<{ role: string; content: string | null }> }) {
        this.calls++;
        sys = String(req.messages.find((m) => m.role === "system")?.content ?? "");
        return { message: { content: "итог" }, usage: { promptTokens: 1, completionTokens: 1, totalTokens: 2 } };
      },
    };
    await makeRunner({ llmClientFactory: () => capturing as never }).run(routine, "manual", null);
    expect(sys).toContain("ПРОЦЕДУРУ");
    expect(sys).not.toContain("СРАЗУ выводи итог");
  });

  it("без LLM-ключа — статус error, без сети", async () => {
    db.prepare("UPDATE settings SET llm_api_key='' WHERE id=1").run();
    const routine = buildRoutine();
    repos.routinesRepo.insert(routine);
    const run = await makeRunner({}).run(routine, "manual", null);
    expect(run.status).toBe("error");
    expect(run.error).toMatch(/LLM не настроен/);
  });

  it("таймаут прогона → статус timeout", async () => {
    const routine = buildRoutine();
    repos.routinesRepo.insert(routine);
    const hangingLlm = { calls: 0, chat: () => new Promise<never>(() => {}) };
    const run = await makeRunner({
      runTimeoutMs: 50,
      llmClientFactory: () => hangingLlm as never,
    }).run(routine, "manual", null);
    expect(run.status).toBe("timeout");
    expect(run.error).toMatch(/время/i);
  });

  it("ask: отвечает по результату прогона, инструменты из хоста", async () => {
    const routine = buildRoutine();
    const host = stubHost({ tools: [qtool("srv__tool")] });
    const runner = makeRunner({ llmClientFactory: () => stubLlm([textCompletion("ответ")]), mcpHost: host });
    const res = await runner.ask({
      routine,
      run: null,
      messages: [{ role: "user", content: "вопрос" }],
      allowTools: false,
    });
    expect(res.reply).toBe("ответ");
  });
});
