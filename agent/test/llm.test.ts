import { describe, it, expect } from "vitest";
import {
  runToolLoop,
  stripModelMarkup,
  HttpLlmClient,
  type ChatRequest,
  type ChatCompletion,
} from "../src/runner/llm.js";

// ── HttpLlmClient: ретраи транзиентных сбоев ─────────────────────────────────
function okResp(text: string): Response {
  return new Response(
    JSON.stringify({
      choices: [{ message: { content: text } }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    }),
    { status: 200 },
  );
}
const noSleep = async () => {};
function makeClient(fetchImpl: typeof fetch, maxRetries = 3): HttpLlmClient {
  return new HttpLlmClient({ url: "http://x", apiKey: "k", provider: "deepseek", maxRetries, fetchImpl, sleep: noSleep });
}
const REQ: ChatRequest = { model: "m", messages: [], temperature: 0, maxTokens: 10 };

describe("HttpLlmClient retry", () => {
  it("повторяет сетевой сбой «fetch failed» и затем успешно отвечает", async () => {
    let n = 0;
    const client = makeClient(async () => {
      n++;
      if (n < 3) throw new TypeError("fetch failed");
      return okResp("готово");
    });
    const r = await client.chat(REQ);
    expect(r.message.content).toBe("готово");
    expect(n).toBe(3);
  });

  it("повторяет 503 и затем 200", async () => {
    let n = 0;
    const client = makeClient(async () => {
      n++;
      return n < 2 ? new Response("oops", { status: 503 }) : okResp("ок");
    });
    expect((await client.chat(REQ)).message.content).toBe("ок");
    expect(n).toBe(2);
  });

  it("4xx не повторяется (клиентская ошибка)", async () => {
    let n = 0;
    const client = makeClient(async () => {
      n++;
      return new Response(JSON.stringify({ error: { message: "bad" } }), { status: 400 });
    });
    await expect(client.chat(REQ)).rejects.toThrow(/Ошибка LLM \(400\)/);
    expect(n).toBe(1);
  });

  it("исчерпание повторов → UpstreamError", async () => {
    let n = 0;
    const client = makeClient(async () => {
      n++;
      throw new TypeError("fetch failed");
    }, 2);
    await expect(client.chat(REQ)).rejects.toThrow(/Сбой запроса к LLM/);
    expect(n).toBe(3); // 1 попытка + 2 повтора
  });

  it("отмену (abort) не повторяет", async () => {
    let n = 0;
    const client = makeClient(async () => {
      n++;
      throw new DOMException("Aborted", "AbortError");
    });
    await expect(client.chat(REQ)).rejects.toThrow();
    expect(n).toBe(1);
  });
});

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
