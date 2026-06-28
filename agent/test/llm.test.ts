import { describe, it, expect } from "vitest";
import { runToolLoop, stripModelMarkup, type ChatRequest, type ChatCompletion } from "../src/runner/llm.js";

describe("stripModelMarkup", () => {
  it("срезает протёкшую DSML-разметку tool-calls", () => {
    const dirty = "Сводка готова.\n<｜｜DSML｜｜tool_calls>\n<｜｜DSML｜｜invoke name=\"x\"></｜｜DSML｜｜invoke>";
    expect(stripModelMarkup(dirty)).toBe("Сводка готова.");
  });
  it("чистый текст не меняет", () => {
    expect(stripModelMarkup("Просто ответ")).toBe("Просто ответ");
  });
});

describe("runToolLoop: финальная итерация без tools", () => {
  it("на последней итерации НЕ передаёт tools (чистый текстовый ответ)", async () => {
    const seen: Array<ChatRequest["tools"]> = [];
    const client = {
      async chat(req: ChatRequest): Promise<ChatCompletion> {
        seen.push(req.tools);
        return { message: { content: "финал" }, usage: { promptTokens: 1, completionTokens: 1, totalTokens: 2 } };
      },
    };
    const res = await runToolLoop({
      client,
      model: "m",
      temperature: 0.4,
      maxTokens: 100,
      messages: [{ role: "user", content: "x" }],
      tools: [{ type: "function", function: { name: "t", parameters: {} } }],
      maxIterations: 1,
      execute: async () => "ok",
    });
    expect(res.text).toBe("финал");
    expect(seen[0]).toBeUndefined(); // tools НЕ переданы на единственной (=последней) итерации
  });
});

import { trimLeadingChatter } from "../src/runner/runner.js";
describe("trimLeadingChatter", () => {
  it("срезает преамбулу до первого заголовка", () => {
    const t = "Теперь составлю сводку.\n\n## 🗓 Задачи — 7\n- [ ] A";
    expect(trimLeadingChatter(t)).toBe("## 🗓 Задачи — 7\n- [ ] A");
  });
  it("без заголовка не меняет", () => {
    expect(trimLeadingChatter("Просто ответ без заголовков")).toBe("Просто ответ без заголовков");
  });
});
