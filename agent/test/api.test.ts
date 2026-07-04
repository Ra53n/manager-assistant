import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { FastifyInstance } from "fastify";
import type { DB } from "../src/store/db.js";
import { buildApp } from "../src/http/app.js";
import { Runner } from "../src/runner/runner.js";
import { SchedulerService } from "../src/scheduler/scheduler.js";
import { RoutineService } from "../src/routines/routineService.js";
import type { AppContext } from "../src/http/context.js";
import { McpServersRepo } from "../src/store/mcpServersRepo.js";
import { stubHost } from "./helpers.js";
import { makeDb, makeRepos, stubLlm, textCompletion, seqId } from "./helpers.js";

const TOKEN = "test-token";
const NOW = "2026-06-27T09:00:00.000Z";
const tick = () => new Promise((r) => setTimeout(r, 15));

let db: DB;
let repos: ReturnType<typeof makeRepos>;
let scheduler: SchedulerService;
let app: FastifyInstance;

const auth = { authorization: `Bearer ${TOKEN}` };

async function createRoutine(over: Record<string, unknown> = {}) {
  const res = await app.inject({
    method: "POST",
    url: "/agent/routines",
    headers: auth,
    payload: { name: "R", prompt: "p", cron: "0 9 * * *", ...over },
  });
  return res.json();
}

beforeEach(async () => {
  db = makeDb();
  repos = makeRepos(db);
  repos.settings.update({ provider: "deepseek", llmApiKey: "sk-test" }, NOW);
  const runner = new Runner({
    routinesRepo: repos.routinesRepo,
    runsRepo: repos.runsRepo,
    settings: repos.settings,
    mcpHost: stubHost(),
    newId: seqId("run"),
    llmClientFactory: () => stubLlm([textCompletion("digest")]),
  });
  scheduler = new SchedulerService({
    routinesRepo: repos.routinesRepo,
    runsRepo: repos.runsRepo,
    runner,
    newId: seqId("skip"),
  });
  const routines = new RoutineService({
    repo: repos.routinesRepo,
    scheduler,
    defaultTimezone: "Europe/Moscow",
  });
  const ctx: AppContext = {
    routines,
    runsRepo: repos.runsRepo,
    settings: repos.settings,
    scheduler,
    runner,
    mcpServersRepo: new McpServersRepo(db),
    mcpHost: stubHost(),
    apiToken: TOKEN,
    now: () => new Date(NOW),
    idempotency: new Map(),
  };
  app = buildApp(ctx);
  await app.ready();
});

afterEach(async () => {
  scheduler.stop();
  await app.close();
  db.close();
});

describe("health и авторизация", () => {
  it("/agent/health доступен без токена", async () => {
    const res = await app.inject({ method: "GET", url: "/agent/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json().status).toBe("ok");
  });

  it("без/с неверным токеном → 401, с верным → 200", async () => {
    expect((await app.inject({ method: "GET", url: "/agent/routines" })).statusCode).toBe(401);
    const wrong = await app.inject({ method: "GET", url: "/agent/routines", headers: { authorization: "Bearer nope" } });
    expect(wrong.statusCode).toBe(401);
    expect(wrong.json().error.code).toBe("unauthorized");
    const ok = await app.inject({ method: "GET", url: "/agent/routines", headers: auth });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().items).toEqual([]);
  });
});

describe("CRUD рутин", () => {
  it("создание + человекочитаемый cron", async () => {
    const r = await createRoutine();
    expect(r.id).toBeTruthy();
    expect(r.rev).toBe(1);
    expect(r.cronHuman).toBe("каждый день в 09:00");
    expect(r.nextRunAt).not.toBeNull();
  });

  it("битый cron → 400 единым форматом", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/agent/routines",
      headers: auth,
      payload: { name: "R", prompt: "p", cron: "не cron" },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe("validation_error");
  });

  it("нет обязательного поля → 400", async () => {
    const res = await app.inject({ method: "POST", url: "/agent/routines", headers: auth, payload: { name: "R" } });
    expect(res.statusCode).toBe(400);
  });

  it("404 на неизвестную рутину", async () => {
    const res = await app.inject({ method: "GET", url: "/agent/routines/nope", headers: auth });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("not_found");
  });

  it("PATCH с устаревшим rev → 409, с верным → rev+1", async () => {
    const r = await createRoutine();
    const stale = await app.inject({
      method: "PATCH",
      url: `/agent/routines/${r.id}`,
      headers: auth,
      payload: { rev: 99, name: "X" },
    });
    expect(stale.statusCode).toBe(409);
    expect(stale.json().error.code).toBe("conflict");

    const ok = await app.inject({
      method: "PATCH",
      url: `/agent/routines/${r.id}`,
      headers: auth,
      payload: { rev: 1, name: "Новое" },
    });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().rev).toBe(2);
    expect(ok.json().name).toBe("Новое");
  });

  it("enable=false снимает расписание (nextRunAt=null)", async () => {
    const r = await createRoutine();
    const res = await app.inject({
      method: "POST",
      url: `/agent/routines/${r.id}/enable`,
      headers: auth,
      payload: { enabled: false },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().enabled).toBe(false);
    expect(res.json().nextRunAt).toBeNull();
  });

  it("DELETE → 204", async () => {
    const r = await createRoutine();
    const res = await app.inject({ method: "DELETE", url: `/agent/routines/${r.id}`, headers: auth });
    expect(res.statusCode).toBe(204);
    expect((await app.inject({ method: "GET", url: `/agent/routines/${r.id}`, headers: auth })).statusCode).toBe(404);
  });
});

describe("trigger + идемпотентность", () => {
  it("повторный ключ возвращает тот же прогон; другой ключ — новый", async () => {
    const r = await createRoutine();
    const t1 = await app.inject({
      method: "POST",
      url: `/agent/routines/${r.id}/trigger`,
      headers: { ...auth, "idempotency-key": "k1" },
    });
    expect(t1.statusCode).toBe(202);
    const run1 = t1.json();

    const t2 = await app.inject({
      method: "POST",
      url: `/agent/routines/${r.id}/trigger`,
      headers: { ...auth, "idempotency-key": "k1" },
    });
    expect(t2.json().id).toBe(run1.id);

    await tick(); // дать фоновому прогону завершиться, чтобы не словить overlap
    const t3 = await app.inject({
      method: "POST",
      url: `/agent/routines/${r.id}/trigger`,
      headers: { ...auth, "idempotency-key": "k2" },
    });
    expect(t3.json().id).not.toBe(run1.id);
  });

  it("история и полная запись прогона", async () => {
    const r = await createRoutine();
    await app.inject({ method: "POST", url: `/agent/routines/${r.id}/trigger`, headers: auth });
    await tick();
    const list = await app.inject({ method: "GET", url: `/agent/routines/${r.id}/runs`, headers: auth });
    expect(list.statusCode).toBe(200);
    expect(list.json().items.length).toBeGreaterThanOrEqual(1);
    const runId = list.json().items[0].id;
    const full = await app.inject({ method: "GET", url: `/agent/runs/${runId}`, headers: auth });
    expect(full.statusCode).toBe(200);
    expect(typeof full.json().outputMarkdown).toBe("string");
  });
});

describe("настройки агента", () => {
  it("GET маскирует секрет; PUT обновляет", async () => {
    const g = await app.inject({ method: "GET", url: "/agent/settings", headers: auth });
    expect(g.json().hasLlmKey).toBe(true);
    expect(g.json().llmKeyHint).toBe("…test");
    expect(JSON.stringify(g.json())).not.toContain("sk-test");

    const p = await app.inject({
      method: "PUT",
      url: "/agent/settings",
      headers: auth,
      payload: { defaultModel: "deepseek-reasoner" },
    });
    expect(p.statusCode).toBe(200);
    expect(p.json().defaultModel).toBe("deepseek-reasoner");
  });
});

describe("диалог с агентом", () => {
  it("успешный ответ по рутине", async () => {
    const r = await createRoutine();
    const res = await app.inject({
      method: "POST",
      url: "/agent/chat/ask",
      headers: auth,
      payload: { routineId: r.id, messages: [{ role: "user", content: "привет" }], allowTools: false },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().reply).toBe("digest");
  });

  it("нет routineId → 400; неизвестная рутина → 404", async () => {
    const bad = await app.inject({ method: "POST", url: "/agent/chat/ask", headers: auth, payload: { messages: [] } });
    expect(bad.statusCode).toBe(400);
    const nf = await app.inject({
      method: "POST",
      url: "/agent/chat/ask",
      headers: auth,
      payload: { routineId: "nope", messages: [{ role: "user", content: "x" }] },
    });
    expect(nf.statusCode).toBe(404);
  });
});

describe("MCP-серверы (синк из приложения)", () => {
  it("PUT сохраняет список; GET отдаёт статус БЕЗ секретов", async () => {
    const put = await app.inject({
      method: "PUT",
      url: "/agent/mcp-servers",
      headers: auth,
      payload: {
        servers: [
          {
            id: "s1",
            name: "yougile",
            command: "npx",
            args: ["-y", "mcp-remote", "https://x/mcp", "--header", "Authorization: Bearer SECRET"],
            env: { TOKEN: "SECRET" },
            enabled: true,
          },
        ],
      },
    });
    expect(put.statusCode).toBe(200);
    const items = put.json().items;
    expect(items).toHaveLength(1);
    expect(items[0].name).toBe("yougile");
    // секреты не утекают в ответ
    expect(JSON.stringify(put.json())).not.toContain("SECRET");

    const get = await app.inject({ method: "GET", url: "/agent/mcp-servers", headers: auth });
    expect(get.statusCode).toBe(200);
    expect(get.json().items[0].name).toBe("yougile");
    expect(JSON.stringify(get.json())).not.toContain("SECRET");
  });

  it("требует авторизацию", async () => {
    const res = await app.inject({ method: "GET", url: "/agent/mcp-servers" });
    expect(res.statusCode).toBe(401);
  });
});
