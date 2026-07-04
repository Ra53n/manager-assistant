// mcpServersRepo.ts — хранение MCP-серверов, синхронизированных из приложения.
// Источник правды — приложение; здесь только зеркало для рантайма агента.
// Секреты (в args/env) наружу не отдаём (см. routes.mcp — маскирование).

import type { DB } from "./db.js";
import type { McpServerConfig } from "../domain/types.js";

interface McpRow {
  id: string;
  name: string;
  command: string;
  args_json: string;
  env_json: string;
  enabled: number;
  updated_at: string;
}

function parseArr(json: string): string[] {
  try {
    const v = JSON.parse(json);
    return Array.isArray(v) ? v.map(String) : [];
  } catch {
    return [];
  }
}

function parseEnv(json: string): Record<string, string> {
  try {
    const v = JSON.parse(json);
    return v && typeof v === "object" ? (v as Record<string, string>) : {};
  } catch {
    return {};
  }
}

function rowToConfig(row: McpRow): McpServerConfig {
  return {
    id: row.id,
    name: row.name,
    command: row.command,
    args: parseArr(row.args_json),
    env: parseEnv(row.env_json),
    enabled: row.enabled === 1,
  };
}

export class McpServersRepo {
  constructor(private readonly db: DB) {}

  list(): McpServerConfig[] {
    const rows = this.db.prepare(`SELECT * FROM mcp_servers ORDER BY name`).all() as McpRow[];
    return rows.map(rowToConfig);
  }

  /** Полностью заменяет список (приложение — источник правды). */
  replaceAll(servers: McpServerConfig[], updatedAt: string): McpServerConfig[] {
    const tx = this.db.transaction((items: McpServerConfig[]) => {
      this.db.prepare(`DELETE FROM mcp_servers`).run();
      const stmt = this.db.prepare(
        `INSERT INTO mcp_servers (id, name, command, args_json, env_json, enabled, updated_at)
         VALUES (@id, @name, @command, @args_json, @env_json, @enabled, @updated_at)`,
      );
      for (const s of items) {
        stmt.run({
          id: s.id,
          name: s.name,
          command: s.command,
          args_json: JSON.stringify(s.args ?? []),
          env_json: JSON.stringify(s.env ?? {}),
          enabled: s.enabled ? 1 : 0,
          updated_at: updatedAt,
        });
      }
    });
    tx(servers);
    return this.list();
  }
}
