// app.ts — сборка Fastify-приложения: единый обработчик ошибок (единый формат
// `{ error: { code, message, details } }`), публичный /agent/health и защищённая
// bearer-токеном зона с маршрутами рутин/прогонов/настроек/диалога.

import Fastify, { type FastifyInstance, type FastifyServerOptions } from "fastify";
import type { AppContext } from "./context.js";
import { AppError } from "../domain/errors.js";
import { bearerAuth } from "./auth.js";
import { registerSettingsRoutes } from "./routes.settings.js";
import { registerRoutineRoutes } from "./routes.routines.js";
import { registerRunRoutes } from "./routes.runs.js";
import { registerChatRoutes } from "./routes.chat.js";
import { registerMcpRoutes } from "./routes.mcp.js";

export const AGENT_VERSION = "0.1.0";

export interface BuildAppOptions {
  /** Логгер Fastify: pino-инстанс, объект опций или false (выкл, по умолчанию). */
  logger?: FastifyServerOptions["logger"];
}

export function buildApp(ctx: AppContext, opts: BuildAppOptions = {}): FastifyInstance {
  const app = Fastify({ logger: opts.logger ?? false });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.httpStatus).send({
        error: { code: err.code, message: err.message, details: err.details ?? null },
      });
    }
    // Ошибка валидации схемы Fastify/ajv.
    const anyErr = err as { validation?: unknown; statusCode?: number };
    if (anyErr.validation) {
      return reply.status(400).send({
        error: {
          code: "validation_error",
          message: err.message,
          details: anyErr.validation ?? null,
        },
      });
    }
    req.log.error({ err }, "необработанная ошибка");
    return reply.status(500).send({
      error: { code: "internal", message: "Внутренняя ошибка сервера", details: null },
    });
  });

  // Публичный liveness — без авторизации (для Caddy/systemd/смоук-проверок).
  app.get("/agent/health", async () => ({
    status: "ok",
    version: AGENT_VERSION,
    uptime: Math.round(process.uptime()),
  }));

  // Защищённая зона (encapsulation: preHandler действует только здесь).
  app.register(async (instance) => {
    instance.addHook("preHandler", bearerAuth(ctx.apiToken));
    registerSettingsRoutes(instance, ctx);
    registerMcpRoutes(instance, ctx);
    registerRoutineRoutes(instance, ctx);
    registerRunRoutes(instance, ctx);
    registerChatRoutes(instance, ctx);
  });

  return app;
}
