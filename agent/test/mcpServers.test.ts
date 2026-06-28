import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { DB } from "../src/store/db.js";
import { McpServersRepo } from "../src/store/mcpServersRepo.js";
import type { McpServerConfig } from "../src/domain/types.js";
import { makeDb } from "./helpers.js";

let db: DB;
let repo: McpServersRepo;

beforeEach(() => {
  db = makeDb();
  repo = new McpServersRepo(db);
});
afterEach(() => db.close());

function cfg(id: string, name: string, over: Partial<McpServerConfig> = {}): McpServerConfig {
  return { id, name, command: "npx", args: [], env: {}, enabled: true, ...over };
}

describe("McpServersRepo", () => {
  it("replaceAll + list round-trip (args/env сохраняются)", () => {
    repo.replaceAll(
      [cfg("a", "alpha", { args: ["-y", "mcp-remote", "https://x/mcp"], env: { K: "v" } })],
      "2026-06-27T00:00:00.000Z",
    );
    const list = repo.list();
    expect(list).toHaveLength(1);
    expect(list[0]!.name).toBe("alpha");
    expect(list[0]!.args).toEqual(["-y", "mcp-remote", "https://x/mcp"]);
    expect(list[0]!.env).toEqual({ K: "v" });
  });

  it("replaceAll полностью заменяет список", () => {
    repo.replaceAll([cfg("a", "alpha"), cfg("b", "beta")], "t1");
    repo.replaceAll([cfg("c", "gamma")], "t2");
    expect(repo.list().map((s) => s.id)).toEqual(["c"]);
  });
});
