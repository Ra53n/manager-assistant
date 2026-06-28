// index.ts — точка входа: загрузка bootstrap-конфига, открытие БД, сборка
// сервисов, старт планировщика и HTTP-сервера. Слушает строго на 127.0.0.1
// (наружу — только через Caddy). Корректное завершение по SIGTERM/SIGINT.

import pino from "pino";
import { loadConfig } from "./config.js";
import { fastifyLoggerOptions } from "./logger.js";
import { openDb } from "./store/db.js";
import { RoutinesRepo } from "./store/routinesRepo.js";
import { RunsRepo } from "./store/runsRepo.js";
import { SettingsRepo } from "./store/settingsRepo.js";
import { McpServersRepo } from "./store/mcpServersRepo.js";
import { SettingsService } from "./settings/settingsService.js";
import { describeCron } from "./domain/cron.js";
import { Runner } from "./runner/runner.js";
import { McpHostImpl } from "./runner/mcpHost.js";
import { SchedulerService } from "./scheduler/scheduler.js";
import { RoutineService } from "./routines/routineService.js";
import { buildApp } from "./http/app.js";
import type { AppContext } from "./http/context.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const logger = pino(fastifyLoggerOptions(config.logLevel));

  const db = openDb(config.dbPath);
  const routinesRepo = new RoutinesRepo(db, describeCron);
  const runsRepo = new RunsRepo(db);
  const settings = new SettingsService(new SettingsRepo(db));
  const mcpServersRepo = new McpServersRepo(db);

  // MCP-хост: подключается к серверам, синхронизированным из приложения.
  const mcpHost = new McpHostImpl(undefined, logger);
  await mcpHost.refresh(mcpServersRepo.list());

  const runner = new Runner({ routinesRepo, runsRepo, settings, mcpHost, logger });
  const scheduler = new SchedulerService({ routinesRepo, runsRepo, runner, logger });
  const routines = new RoutineService({
    repo: routinesRepo,
    scheduler,
    defaultTimezone: config.defaultTimezone,
  });

  const ctx: AppContext = {
    routines,
    runsRepo,
    settings,
    scheduler,
    runner,
    mcpServersRepo,
    mcpHost,
    apiToken: config.apiToken,
    now: () => new Date(),
    idempotency: new Map(),
  };

  const app = buildApp(ctx, { logger });

  // Старт планировщика: примирение зависших прогонов + регистрация рутин + catch-up.
  scheduler.start();

  await app.listen({ host: config.host, port: config.port });
  logger.info(
    { host: config.host, port: config.port, tz: config.defaultTimezone },
    "manager-agent запущен",
  );

  const shutdown = async (signal: string) => {
    logger.info({ signal }, "останавливаюсь");
    scheduler.stop();
    try {
      await app.close();
      await mcpHost.close();
      db.close();
    } finally {
      process.exit(0);
    }
  };
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));
}

main().catch((err) => {
  // Падаем с понятным сообщением — systemd покажет его в journalctl.
  console.error(`[manager-agent] фатальная ошибка запуска: ${(err as Error).message}`);
  process.exit(1);
});
