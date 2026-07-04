// mcpHost.ts — generic MCP-хост агента. Подключается к N MCP-серверам (спеки
// приходят из приложения — источник правды), агрегирует их инструменты,
// квалифицирует имена `<slug>__<tool>` и маршрутизирует вызовы. Никаких привязок
// к конкретному MCP. Транспорт по умолчанию — stdio (как в приложении: spawn
// `command args env`, в т.ч. `npx -y mcp-remote <url> --header ...`).

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { Logger } from "../logger.js";
import { silentLogger } from "../logger.js";
import type { McpServerConfig, McpServerPublic } from "../domain/types.js";

export interface McpToolSpec {
  name: string;
  description: string;
  inputSchema: unknown;
}

/** Квалифицированный инструмент для LLM. */
export interface QualifiedTool {
  qualifiedName: string;
  description: string;
  inputSchema: unknown;
}

/** Минимальный интерфейс MCP-клиента (для подмены в тестах). */
export interface McpClientLike {
  listTools(): Promise<{ tools?: McpToolSpec[] }>;
  callTool(args: { name: string; arguments: unknown }): Promise<{ content?: unknown[]; isError?: boolean }>;
  close(): Promise<void>;
}

/** Фабрика подключения к одному серверу (по умолчанию — stdio через SDK). */
export type McpConnector = (server: McpServerConfig) => Promise<McpClientLike>;

export interface McpHost {
  refresh(servers: McpServerConfig[]): Promise<void>;
  availableTools(): QualifiedTool[];
  call(qualifiedName: string, argsJSON: string): Promise<string>;
  statuses(): McpServerPublic[];
  close(): Promise<void>;
}

// ─── Квалификация имён (по образцу MCPManager приложения) ─────────────────────

export function slugify(name: string): string {
  const s = name
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 24);
  return s || "mcp";
}

export function qualify(slug: string, tool: string): string {
  return `${slug}__${tool}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 64);
}

/** PATH для дочернего процесса: добавляем стандартные пути к node/npx. */
function augmentPath(base: string | undefined): string {
  const extra = ["/usr/local/bin", "/usr/bin", "/bin"];
  return [base, ...extra].filter(Boolean).join(":");
}

/** Реальный коннектор: spawn stdio через SDK. */
export const defaultConnector: McpConnector = async (server) => {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (typeof v === "string") env[k] = v;
  for (const [k, v] of Object.entries(server.env)) env[k] = v;
  env.PATH = augmentPath(env.PATH);

  const transport = new StdioClientTransport({ command: server.command, args: server.args, env });
  const client = new Client({ name: "manager-agent", version: "0.1.0" }, { capabilities: {} });
  await client.connect(transport);
  return {
    listTools: () => client.listTools() as Promise<{ tools?: McpToolSpec[] }>,
    callTool: (a) => client.callTool(a as never) as Promise<{ content?: unknown[]; isError?: boolean }>,
    close: () => client.close(),
  };
};

interface Connection {
  config: McpServerConfig;
  slug: string;
  signature: string;
  client: McpClientLike;
  tools: McpToolSpec[];
}

function signatureOf(s: McpServerConfig): string {
  return JSON.stringify([s.command, s.args, s.env]);
}

export class McpHostImpl implements McpHost {
  private conns = new Map<string, Connection>(); // serverId → connection
  private route = new Map<string, { serverId: string; tool: string }>(); // qualifiedName → target
  private errors = new Map<string, { name: string; command: string; error: string }>();

  constructor(
    private readonly connector: McpConnector = defaultConnector,
    private readonly logger: Logger = silentLogger,
  ) {}

  /** (Пере)подключает включённые серверы. Идемпотентно: неизменённые не трогает. */
  async refresh(servers: McpServerConfig[]): Promise<void> {
    const enabled = servers.filter((s) => s.enabled);
    const wanted = new Map(enabled.map((s) => [s.id, s]));
    this.errors.clear();

    // Закрыть удалённые/выключенные.
    for (const [id, conn] of [...this.conns]) {
      const next = wanted.get(id);
      if (!next || signatureOf(next) !== conn.signature) {
        await this.safeClose(conn);
        this.conns.delete(id);
      }
    }

    // Подключить новые/изменённые.
    for (const s of enabled) {
      if (this.conns.has(s.id)) continue;
      try {
        const client = await this.connector(s);
        const res = await client.listTools();
        const tools = res.tools ?? [];
        this.conns.set(s.id, { config: s, slug: slugify(s.name), signature: signatureOf(s), client, tools });
      } catch (e) {
        this.errors.set(s.id, { name: s.name, command: s.command, error: (e as Error).message });
        this.logger.warn({ server: s.name, err: (e as Error).message }, "MCP server connect failed");
      }
    }

    this.rebuildRoutes();
  }

  private rebuildRoutes(): void {
    this.route.clear();
    for (const conn of this.conns.values()) {
      for (const t of conn.tools) {
        this.route.set(qualify(conn.slug, t.name), { serverId: conn.config.id, tool: t.name });
      }
    }
  }

  availableTools(): QualifiedTool[] {
    const out: QualifiedTool[] = [];
    for (const conn of this.conns.values()) {
      for (const t of conn.tools) {
        out.push({
          qualifiedName: qualify(conn.slug, t.name),
          description: t.description,
          inputSchema: t.inputSchema,
        });
      }
    }
    return out;
  }

  async call(qualifiedName: string, argsJSON: string): Promise<string> {
    const target = this.route.get(qualifiedName);
    if (!target) return `ERROR: неизвестный инструмент ${qualifiedName}`;
    const conn = this.conns.get(target.serverId);
    if (!conn) return `ERROR: сервер не подключён для ${qualifiedName}`;
    let args: unknown = {};
    try {
      args = argsJSON ? JSON.parse(argsJSON) : {};
    } catch {
      args = {};
    }
    try {
      const res = await conn.client.callTool({ name: target.tool, arguments: args });
      const text = (res.content ?? [])
        .filter((c): c is { type: string; text: string } =>
          !!c && typeof c === "object" && (c as { type?: string }).type === "text" &&
          typeof (c as { text?: unknown }).text === "string")
        .map((c) => c.text)
        .join("\n");
      if (res.isError) return `ERROR: ${text || "ошибка инструмента"}`;
      return text || "(пустой результат)";
    } catch (e) {
      return `ERROR: ${(e as Error).message}`;
    }
  }

  statuses(): McpServerPublic[] {
    const out: McpServerPublic[] = [];
    for (const conn of this.conns.values()) {
      out.push({
        id: conn.config.id,
        name: conn.config.name,
        command: conn.config.command,
        enabled: true,
        connected: true,
        toolCount: conn.tools.length,
        error: null,
      });
    }
    for (const [id, e] of this.errors) {
      out.push({
        id,
        name: e.name,
        command: e.command,
        enabled: true,
        connected: false,
        toolCount: 0,
        error: e.error,
      });
    }
    return out;
  }

  async close(): Promise<void> {
    for (const conn of this.conns.values()) await this.safeClose(conn);
    this.conns.clear();
    this.route.clear();
  }

  private async safeClose(conn: Connection): Promise<void> {
    try {
      await conn.client.close();
    } catch {
      /* игнор */
    }
  }
}
