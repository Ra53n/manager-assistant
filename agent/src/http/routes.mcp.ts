// routes.mcp.ts — MCP-серверы агента. Источник правды — приложение: оно
// присылает весь список (PUT), агент подключается к ним и отдаёт инструменты
// рутинам. GET возвращает статус БЕЗ секретов (нет значений env и токенов в args).

import type { FastifyInstance } from "fastify";
import type { AppContext } from "./context.js";
import type { McpServerConfig, McpServerPublic } from "../domain/types.js";
import { mcpServersBody } from "./schemas.js";

function publicList(ctx: AppContext): McpServerPublic[] {
  const configs = ctx.mcpServersRepo.list();
  const byId = new Map(ctx.mcpHost.statuses().map((s) => [s.id, s]));
  return configs.map((c) => {
    const st = byId.get(c.id);
    return {
      id: c.id,
      name: c.name,
      command: c.command,
      enabled: c.enabled,
      connected: st?.connected ?? false,
      toolCount: st?.toolCount ?? 0,
      error: st?.error ?? null,
    };
  });
}

export function registerMcpRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get("/agent/mcp-servers", async () => ({ items: publicList(ctx) }));

  app.put<{ Body: { servers: McpServerConfig[] } }>(
    "/agent/mcp-servers",
    { schema: { body: mcpServersBody } },
    async (req) => {
      const servers = (req.body.servers ?? []).map((s) => ({
        id: String(s.id),
        name: s.name ?? "",
        command: s.command ?? "npx",
        args: Array.isArray(s.args) ? s.args.map(String) : [],
        env: s.env && typeof s.env === "object" ? s.env : {},
        enabled: s.enabled ?? true,
      }));
      ctx.mcpServersRepo.replaceAll(servers, ctx.now().toISOString());
      await ctx.mcpHost.refresh(servers);
      return { items: publicList(ctx) };
    },
  );
}
