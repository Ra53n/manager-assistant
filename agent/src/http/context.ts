// context.ts — общий контекст приложения (сервисы), прокидываемый в маршруты.

import type { RoutineService } from "../routines/routineService.js";
import type { RunsRepo } from "../store/runsRepo.js";
import type { SettingsService } from "../settings/settingsService.js";
import type { SchedulerService } from "../scheduler/scheduler.js";
import type { Runner } from "../runner/runner.js";
import type { McpServersRepo } from "../store/mcpServersRepo.js";
import type { McpHost } from "../runner/mcpHost.js";

export interface AppContext {
  routines: RoutineService;
  runsRepo: RunsRepo;
  settings: SettingsService;
  scheduler: SchedulerService;
  runner: Runner;
  mcpServersRepo: McpServersRepo;
  mcpHost: McpHost;
  apiToken: string;
  now: () => Date;
  /** Идемпотентность trigger-now: ключ → созданный runId (+время для TTL). */
  idempotency: Map<string, { runId: string; ts: number }>;
}
