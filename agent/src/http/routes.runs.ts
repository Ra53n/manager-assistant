// routes.runs.ts — история прогонов (cursor-пагинация) и полная запись прогона.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { NotFoundError } from "../domain/errors.js";
import { runsQuery } from "./schemas.js";

export function registerRunRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get<{ Params: { id: string }; Querystring: { limit?: number; cursor?: string } }>(
    "/agent/routines/:id/runs",
    { schema: { querystring: runsQuery } },
    async (req) => {
      ctx.routines.get(req.params.id); // 404, если рутины нет
      return ctx.runsRepo.listByRoutine(
        req.params.id,
        req.query.limit ?? 20,
        req.query.cursor ?? null,
      );
    },
  );

  app.get<{ Params: { runId: string } }>("/agent/runs/:runId", async (req) => {
    const run = ctx.runsRepo.get(req.params.runId);
    if (!run) throw new NotFoundError(`Прогон не найден: ${req.params.runId}`);
    return run;
  });
}
