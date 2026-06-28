import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { DB } from "../src/store/db.js";
import { ValidationError } from "../src/domain/errors.js";
import { makeDb, makeRepos } from "./helpers.js";

let db: DB;
let repos: ReturnType<typeof makeRepos>;
const NOW = "2026-06-27T12:00:00.000Z";

beforeEach(() => {
  db = makeDb();
  repos = makeRepos(db);
});
afterEach(() => db.close());

describe("SettingsService", () => {
  it("по умолчанию секретов нет, маски пустые", () => {
    const pub = repos.settings.getPublic();
    expect(pub.provider).toBe("deepseek");
    expect(pub.hasLlmKey).toBe(false);
    expect(pub.llmKeyHint).toBe("");
  });

  it("GET НИКОГДА не отдаёт сам секрет — только маску", () => {
    repos.settings.update({ provider: "deepseek", llmApiKey: "sk-secret-abcd" }, NOW);
    const pub = repos.settings.getPublic() as Record<string, unknown>;
    expect(pub.hasLlmKey).toBe(true);
    expect(pub.llmKeyHint).toBe("…abcd");
    expect(JSON.stringify(pub)).not.toContain("sk-secret-abcd");
  });

  it("getInternal отдаёт секрет (для раннера)", () => {
    repos.settings.update({ llmApiKey: "sk-secret-abcd" }, NOW);
    expect(repos.settings.getInternal().llmApiKey).toBe("sk-secret-abcd");
  });

  it("PUT с пустым секретом НЕ затирает существующий", () => {
    repos.settings.update({ llmApiKey: "sk-keep-1234" }, NOW);
    repos.settings.update({ defaultModel: "deepseek-reasoner", llmApiKey: "" }, NOW);
    expect(repos.settings.getInternal().llmApiKey).toBe("sk-keep-1234");
    expect(repos.settings.getInternal().defaultModel).toBe("deepseek-reasoner");
  });

  it("отвергает неизвестного провайдера и плохую таймзону", () => {
    expect(() => repos.settings.update({ provider: "openai" as never }, NOW)).toThrow(ValidationError);
    expect(() => repos.settings.update({ defaultTimezone: "Нет/Такой" }, NOW)).toThrow(ValidationError);
  });

  it("в публичных настройках нет полей про YouGile", () => {
    const pub = repos.settings.getPublic() as Record<string, unknown>;
    expect(pub.yougileMcpUrl).toBeUndefined();
    expect(pub.hasYougileToken).toBeUndefined();
  });
});
