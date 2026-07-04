import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { DB } from "../src/store/db.js";
import { SchedulerService } from "../src/scheduler/scheduler.js";
import type { Runner } from "../src/runner/runner.js";
import type { Routine, RunRecord, RunTrigger } from "../src/domain/types.js";
import { makeDb, makeRepos, buildRoutine, buildRun, seqId } from "./helpers.js";

let db: DB;
let repos: ReturnType<typeof makeRepos>;
let scheduler: SchedulerService | null;

const tick = () => new Promise((r) => setTimeout(r, 15));

/** Фейковый раннер: begin вставляет running-запись; executeRun ждёт опц. gate. */
function fakeRunner(gate?: Promise<void>): Runner {
  const idg = seqId("run");
  const fake = {
    begin(routine: Routine, trigger: RunTrigger, scheduledFor: string | null): RunRecord {
      const run = buildRun({ id: idg(), routineId: routine.id, trigger, status: "running", scheduledFor });
      repos.runsRepo.insert(run);
      return run;
    },
    async executeRun(routine: Routine, run: RunRecord): Promise<RunRecord> {
      if (gate) await gate;
      run.status = "ok";
      run.finishedAt = "2026-06-27T09:01:00.000Z";
      repos.runsRepo.update(run);
      repos.routinesRepo.updateRunStamps(routine.id, run.startedAt, null);
      return run;
    },
    async run(routine: Routine, trigger: RunTrigger, sf: string | null): Promise<RunRecord> {
      return this.executeRun(routine, this.begin(routine, trigger, sf));
    },
  };
  return fake as unknown as Runner;
}

beforeEach(() => {
  db = makeDb();
  repos = makeRepos(db);
  scheduler = null;
});
afterEach(() => {
  scheduler?.stop();
  db.close();
});

describe("overlap-guard (triggerNow)", () => {
  it("второй запуск во время первого → skipped_overlap, без двойного прогона", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const routine = buildRoutine({ id: "a" });
    repos.routinesRepo.insert(routine);
    scheduler = new SchedulerService({
      routinesRepo: repos.routinesRepo,
      runsRepo: repos.runsRepo,
      runner: fakeRunner(gate),
      now: () => new Date("2026-06-27T09:00:00.000Z"),
      newId: seqId("skip"),
    });

    const r1 = scheduler.triggerNow(routine);
    expect(r1.status).toBe("running");
    expect(scheduler.isRunning("a")).toBe(true);

    const r2 = scheduler.triggerNow(routine);
    expect(r2.status).toBe("skipped_overlap");

    release();
    await tick();
    expect(scheduler.isRunning("a")).toBe(false);
    // ровно один «настоящий» прогон + одна запись пропуска
    const items = repos.runsRepo.listByRoutine("a", 10).items;
    expect(items.filter((x) => x.status === "skipped_overlap")).toHaveLength(1);
    expect(items.filter((x) => x.status === "ok")).toHaveLength(1);
  });
});

describe("register / unregister", () => {
  it("включённая рутина получает next_run_at; выключенная — null", () => {
    const routine = buildRoutine({ id: "a", enabled: true });
    repos.routinesRepo.insert(routine);
    scheduler = new SchedulerService({
      routinesRepo: repos.routinesRepo,
      runsRepo: repos.runsRepo,
      runner: fakeRunner(),
    });
    scheduler.register(routine);
    expect(repos.routinesRepo.get("a")?.nextRunAt).not.toBeNull();

    scheduler.register({ ...routine, enabled: false });
    expect(repos.routinesRepo.get("a")?.nextRunAt).toBeNull();
  });
});

describe("start(): reconcile + catch-up", () => {
  it("зависшие running примиряются в error", () => {
    repos.routinesRepo.insert(buildRoutine({ id: "a", enabled: false }));
    repos.runsRepo.insert(buildRun({ id: "stuck", routineId: "a", status: "running" }));
    scheduler = new SchedulerService({
      routinesRepo: repos.routinesRepo,
      runsRepo: repos.runsRepo,
      runner: fakeRunner(),
      now: () => new Date("2026-06-27T10:00:00.000Z"),
    });
    scheduler.start();
    expect(repos.runsRepo.get("stuck")?.status).toBe("error");
  });

  it("пропущенный слот фиксируется записью missed", () => {
    repos.routinesRepo.insert(
      buildRoutine({ id: "a", enabled: true, lastRunAt: "2026-06-20T06:00:00.000Z" }),
    );
    scheduler = new SchedulerService({
      routinesRepo: repos.routinesRepo,
      runsRepo: repos.runsRepo,
      runner: fakeRunner(),
      now: () => new Date("2026-06-25T00:00:00.000Z"),
      newId: seqId("s"),
    });
    scheduler.start();
    const latest = repos.runsRepo.latestForRoutine("a");
    expect(latest?.status).toBe("missed");
    expect(latest?.scheduledFor).toBe("2026-06-21T06:00:00.000Z");
  });

  it("catchUpOnStart=true запускает ровно один догоняющий прогон", async () => {
    repos.routinesRepo.insert(
      buildRoutine({
        id: "a",
        enabled: true,
        catchUpOnStart: true,
        lastRunAt: "2026-06-20T06:00:00.000Z",
      }),
    );
    scheduler = new SchedulerService({
      routinesRepo: repos.routinesRepo,
      runsRepo: repos.runsRepo,
      runner: fakeRunner(),
      now: () => new Date("2026-06-25T00:00:00.000Z"),
      newId: seqId("s"),
    });
    scheduler.start();
    await tick();
    const items = repos.runsRepo.listByRoutine("a", 10).items;
    expect(items.some((x) => x.trigger === "catchup")).toBe(true);
    expect(items.some((x) => x.status === "missed")).toBe(true);
  });

  it("повторный start не дублирует missed", () => {
    repos.routinesRepo.insert(
      buildRoutine({ id: "a", enabled: true, lastRunAt: "2026-06-20T06:00:00.000Z" }),
    );
    const deps = {
      routinesRepo: repos.routinesRepo,
      runsRepo: repos.runsRepo,
      runner: fakeRunner(),
      now: () => new Date("2026-06-25T00:00:00.000Z"),
      newId: seqId("s"),
    };
    scheduler = new SchedulerService(deps);
    scheduler.start();
    scheduler.stop();
    const s2 = new SchedulerService(deps);
    s2.start();
    s2.stop();
    const missed = repos.runsRepo
      .listByRoutine("a", 10)
      .items.filter((x) => x.status === "missed");
    expect(missed).toHaveLength(1);
  });
});
