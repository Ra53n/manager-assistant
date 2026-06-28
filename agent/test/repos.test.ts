import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { DB } from "../src/store/db.js";
import { ConflictError, NotFoundError } from "../src/domain/errors.js";
import { makeDb, makeRepos, buildRoutine, buildRun } from "./helpers.js";

let db: DB;
let repos: ReturnType<typeof makeRepos>;

beforeEach(() => {
  db = makeDb();
  repos = makeRepos(db);
});
afterEach(() => db.close());

describe("RoutinesRepo", () => {
  it("insert/get/list round-trip", () => {
    const r = buildRoutine({ id: "a", sinks: [{ kind: "vps_local" }, { kind: "yougile", mode: "comment", taskId: "t1" }] });
    repos.routinesRepo.insert(r);
    const got = repos.routinesRepo.get("a");
    expect(got?.name).toBe(r.name);
    expect(got?.sinks).toHaveLength(2);
    expect(got?.cronHuman).toBe("каждый день в 09:00"); // вычислено через describeCron
    expect(repos.routinesRepo.list()).toHaveLength(1);
  });

  it("getOrThrow бросает NotFound", () => {
    expect(() => repos.routinesRepo.getOrThrow("нет")).toThrow(NotFoundError);
  });

  it("replace при совпадении rev обновляет, новый rev фиксируется", () => {
    repos.routinesRepo.insert(buildRoutine({ id: "a", rev: 1 }));
    const updated = buildRoutine({ id: "a", name: "Новое имя", rev: 2 });
    repos.routinesRepo.replace(updated, 1);
    expect(repos.routinesRepo.get("a")?.name).toBe("Новое имя");
    expect(repos.routinesRepo.get("a")?.rev).toBe(2);
  });

  it("replace при устаревшем rev бросает Conflict", () => {
    repos.routinesRepo.insert(buildRoutine({ id: "a", rev: 5 }));
    const updated = buildRoutine({ id: "a", name: "X", rev: 99 });
    expect(() => repos.routinesRepo.replace(updated, 1)).toThrow(ConflictError);
  });

  it("remove удаляет рутину вместе с её прогонами", () => {
    repos.routinesRepo.insert(buildRoutine({ id: "a" }));
    repos.runsRepo.insert(buildRun({ id: "run-a", routineId: "a" }));
    expect(repos.routinesRepo.remove("a")).toBe(true);
    expect(repos.routinesRepo.get("a")).toBeNull();
    expect(repos.runsRepo.get("run-a")).toBeNull();
  });
});

describe("RunsRepo", () => {
  beforeEach(() => repos.routinesRepo.insert(buildRoutine({ id: "a" })));

  function insertRuns(n: number) {
    for (let i = 1; i <= n; i++) {
      repos.runsRepo.insert(
        buildRun({
          id: `run-${i}`,
          routineId: "a",
          status: "ok",
          startedAt: `2026-06-27T0${i}:00:00.000Z`,
        }),
      );
    }
  }

  it("cursor-пагинация в порядке started_at DESC", () => {
    insertRuns(5);
    const page1 = repos.runsRepo.listByRoutine("a", 2);
    expect(page1.items.map((r) => r.id)).toEqual(["run-5", "run-4"]);
    expect(page1.nextCursor).not.toBeNull();

    const page2 = repos.runsRepo.listByRoutine("a", 2, page1.nextCursor);
    expect(page2.items.map((r) => r.id)).toEqual(["run-3", "run-2"]);

    const page3 = repos.runsRepo.listByRoutine("a", 2, page2.nextCursor);
    expect(page3.items.map((r) => r.id)).toEqual(["run-1"]);
    expect(page3.nextCursor).toBeNull();
  });

  it("summary не содержит тяжёлого outputMarkdown", () => {
    repos.runsRepo.insert(buildRun({ id: "run-x", routineId: "a", outputMarkdown: "много текста" }));
    const page = repos.runsRepo.listByRoutine("a", 10);
    expect((page.items[0] as Record<string, unknown>).outputMarkdown).toBeUndefined();
    // полная запись содержит вывод
    expect(repos.runsRepo.get("run-x")?.outputMarkdown).toBe("много текста");
  });

  it("latestForRoutine возвращает самый свежий", () => {
    insertRuns(3);
    expect(repos.runsRepo.latestForRoutine("a")?.id).toBe("run-3");
  });

  it("update финализирует запись", () => {
    repos.runsRepo.insert(buildRun({ id: "run-1", routineId: "a", status: "running" }));
    const finished = buildRun({
      id: "run-1",
      routineId: "a",
      status: "ok",
      finishedAt: "2026-06-27T09:01:00.000Z",
      outputMarkdown: "итог",
      usage: { promptTokens: 1, completionTokens: 2, totalTokens: 3, costUsd: 0.0001 },
    });
    repos.runsRepo.update(finished);
    const got = repos.runsRepo.get("run-1");
    expect(got?.status).toBe("ok");
    expect(got?.usage.totalTokens).toBe(3);
  });

  it("reconcileStuckRunning переводит зависшие running → error", () => {
    repos.runsRepo.insert(buildRun({ id: "run-1", routineId: "a", status: "running" }));
    repos.runsRepo.insert(buildRun({ id: "run-2", routineId: "a", status: "ok" }));
    const n = repos.runsRepo.reconcileStuckRunning("прервано", "2026-06-27T10:00:00.000Z");
    expect(n).toBe(1);
    expect(repos.runsRepo.get("run-1")?.status).toBe("error");
    expect(repos.runsRepo.get("run-2")?.status).toBe("ok");
  });
});
