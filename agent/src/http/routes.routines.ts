// routes.routines.ts — CRUD рутин, enable/pause и trigger-now (с идемпотентностью).

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import type { CreateRoutineInput, UpdateRoutineInput } from "../domain/types.js";
import { createRoutineBody, enableBody, updateRoutineBody } from "./schemas.js";

const IDEMPOTENCY_TTL_MS = 10 * 60 * 1000;

function pruneIdempotency(map: Map<string, { runId: string; ts: number }>): void {
  const cutoff = Date.now() - IDEMPOTENCY_TTL_MS;
  for (const [key, val] of map) {
    if (val.ts < cutoff) map.delete(key);
  }
}

export function registerRoutineRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get("/agent/routines", async () => ({ items: ctx.routines.list() }));

  app.post<{ Body: CreateRoutineInput }>(
    "/agent/routines",
    { schema: { body: createRoutineBody } },
    async (req, reply) => {
      const routine = ctx.routines.create(req.body);
      reply.code(201);
      return routine;
    },
  );

  app.get<{ Params: { id: string } }>("/agent/routines/:id", async (req) =>
    ctx.routines.get(req.params.id),
  );

  app.patch<{ Params: { id: string }; Body: UpdateRoutineInput }>(
    "/agent/routines/:id",
    { schema: { body: updateRoutineBody } },
    async (req) => ctx.routines.update(req.params.id, req.body),
  );

  app.delete<{ Params: { id: string } }>("/agent/routines/:id", async (req, reply) => {
    ctx.routines.remove(req.params.id);
    reply.code(204);
    return null;
  });

  app.post<{ Params: { id: string }; Body: { enabled: boolean } }>(
    "/agent/routines/:id/enable",
    { schema: { body: enableBody } },
    async (req) => ctx.routines.setEnabled(req.params.id, req.body.enabled),
  );

  app.post<{ Params: { id: string } }>(
    "/agent/routines/:id/trigger",
    async (req, reply) => {
      const routine = ctx.routines.get(req.params.id); // 404, если нет
      const key = req.headers["idempotency-key"];

      if (typeof key === "string" && key) {
        pruneIdempotency(ctx.idempotency);
        const hit = ctx.idempotency.get(key);
        if (hit) {
          const existing = ctx.runsRepo.get(hit.runId);
          if (existing) {
            reply.code(202);
            return existing;
          }
        }
      }

      const run = ctx.scheduler.triggerNow(routine);
      if (typeof key === "string" && key) {
        ctx.idempotency.set(key, { runId: run.id, ts: Date.now() });
      }
      reply.code(202);
      return run;
    },
  );
}
