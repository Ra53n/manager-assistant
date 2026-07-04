import { describe, it, expect } from "vitest";
import { McpHostImpl, qualify, slugify, type McpConnector, type McpClientLike } from "../src/runner/mcpHost.js";
import type { McpServerConfig } from "../src/domain/types.js";

function cfg(id: string, name: string, over: Partial<McpServerConfig> = {}): McpServerConfig {
  return { id, name, command: "npx", args: [], env: {}, enabled: true, ...over };
}

interface ServerSpec {
  tools?: Array<{ name: string; description?: string; inputSchema?: unknown }>;
  onCall?: (name: string, args: unknown) => { content?: unknown[]; isError?: boolean };
  throwOnConnect?: boolean;
  throwOnCall?: boolean;
}

function fakeConnector(specs: Record<string, ServerSpec>, counters = { connects: 0, closes: 0 }): {
  connector: McpConnector;
  counters: { connects: number; closes: number };
} {
  const connector: McpConnector = async (server) => {
    counters.connects++;
    const s = specs[server.id] ?? {};
    if (s.throwOnConnect) throw new Error("connect fail");
    const client: McpClientLike = {
      async listTools() {
        return { tools: (s.tools ?? []).map((t) => ({ name: t.name, description: t.description ?? "", inputSchema: t.inputSchema ?? {} })) };
      },
      async callTool({ name, arguments: args }) {
        if (s.throwOnCall) throw new Error("call fail");
        if (s.onCall) return s.onCall(name, args);
        return { content: [{ type: "text", text: `${server.id}:${name}` }] };
      },
      async close() {
        counters.closes++;
      },
    };
    return client;
  };
  return { connector, counters };
}

describe("qualify/slugify", () => {
  it("slug — латиница/цифры/_, иначе mcp", () => {
    expect(slugify("yougile")).toBe("yougile");
    expect(slugify("My Server 1")).toBe("my_server_1");
    expect(slugify("Доска")).toBe("mcp");
  });
  it("qualify даёт <slug>__<tool>", () => {
    expect(qualify("yougile", "list_tasks")).toBe("yougile__list_tasks");
  });
});

describe("McpHost", () => {
  it("агрегирует инструменты N серверов с квалификацией", async () => {
    const { connector } = fakeConnector({
      a: { tools: [{ name: "list" }, { name: "get" }] },
      b: { tools: [{ name: "summary" }] },
    });
    const host = new McpHostImpl(connector);
    await host.refresh([cfg("a", "alpha"), cfg("b", "beta")]);
    const names = host.availableTools().map((t) => t.qualifiedName).sort();
    expect(names).toEqual(["alpha__get", "alpha__list", "beta__summary"]);
  });

  it("маршрутизирует call в нужный сервер", async () => {
    const { connector } = fakeConnector({
      a: { tools: [{ name: "t" }], onCall: () => ({ content: [{ type: "text", text: "из A" }] }) },
      b: { tools: [{ name: "t" }], onCall: () => ({ content: [{ type: "text", text: "из B" }] }) },
    });
    const host = new McpHostImpl(connector);
    await host.refresh([cfg("a", "alpha"), cfg("b", "beta")]);
    expect(await host.call("alpha__t", "{}")).toBe("из A");
    expect(await host.call("beta__t", "{}")).toBe("из B");
  });

  it("неизвестный инструмент → ERROR", async () => {
    const { connector } = fakeConnector({});
    const host = new McpHostImpl(connector);
    await host.refresh([]);
    expect(await host.call("nope__x", "{}")).toMatch(/^ERROR/);
  });

  it("падение callTool изолировано → ERROR, не бросает", async () => {
    const { connector } = fakeConnector({ a: { tools: [{ name: "t" }], throwOnCall: true } });
    const host = new McpHostImpl(connector);
    await host.refresh([cfg("a", "alpha")]);
    expect(await host.call("alpha__t", "{}")).toMatch(/^ERROR/);
  });

  it("падение подключения одного сервера не ломает остальные; статус — ошибка", async () => {
    const { connector } = fakeConnector({
      a: { throwOnConnect: true },
      b: { tools: [{ name: "t" }] },
    });
    const host = new McpHostImpl(connector);
    await host.refresh([cfg("a", "alpha"), cfg("b", "beta")]);
    expect(host.availableTools().map((t) => t.qualifiedName)).toEqual(["beta__t"]);
    const statuses = host.statuses();
    expect(statuses.find((s) => s.id === "a")?.connected).toBe(false);
    expect(statuses.find((s) => s.id === "b")?.connected).toBe(true);
  });

  it("refresh идемпотентен: неизменённый сервер не переподключается", async () => {
    const { connector, counters } = fakeConnector({ a: { tools: [{ name: "t" }] } });
    const host = new McpHostImpl(connector);
    await host.refresh([cfg("a", "alpha")]);
    await host.refresh([cfg("a", "alpha")]); // та же конфигурация
    expect(counters.connects).toBe(1);
  });

  it("close закрывает клиентов", async () => {
    const { connector, counters } = fakeConnector({ a: { tools: [{ name: "t" }] } });
    const host = new McpHostImpl(connector);
    await host.refresh([cfg("a", "alpha")]);
    await host.close();
    expect(counters.closes).toBe(1);
  });
});
