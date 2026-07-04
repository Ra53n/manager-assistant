// routes.chat.ts — интерактивный диалог с агентом по результату прогона.
// Stateless: историю реплик присылает приложение; сервер сидирует контекст
// дайджестом нужного прогона и гоняет tool-loop.

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import { askBody } from "./schemas.js";

interface AskBody {
  routineId: string;
  runId?: string | null;
  allowTools?: boolean;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
}

export function registerChatRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post<{ Body: AskBody }>(
    "/agent/chat/ask",
    { schema: { body: askBody } },
    async (req) => {
      const body = req.body;
      const routine = ctx.routines.get(body.routineId); // 404, если нет
      const run = body.runId
        ? ctx.runsRepo.get(body.runId)
        : ctx.runsRepo.latestForRoutine(routine.id);
      return ctx.runner.ask({
        routine,
        run: run ?? null,
        messages: body.messages,
        allowTools: body.allowTools ?? true,
      });
    },
  );
}
