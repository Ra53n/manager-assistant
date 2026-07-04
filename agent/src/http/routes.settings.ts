// routes.settings.ts — настройки агента (server-side, задаются из приложения).
// GET отдаёт замаскированные секреты; PUT принимает новые значения.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import type { UpdateAgentSettingsInput } from "../domain/types.js";
import { settingsBody } from "./schemas.js";

export function registerSettingsRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get("/agent/settings", async () => ctx.settings.getPublic());

  app.put<{ Body: UpdateAgentSettingsInput }>(
    "/agent/settings",
    { schema: { body: settingsBody } },
    async (req) => ctx.settings.update(req.body, ctx.now().toISOString()),
  );
}
