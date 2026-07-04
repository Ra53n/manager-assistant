import { describe, it, expect } from "vitest";
import {
  parsePlanSteps,
  parseDeps,
  computeWaves,
  parseVerdict,
  stripMarkers,
  wantsReplan,
} from "../src/runner/pipeline/parsers.js";

describe("parsePlanSteps", () => {
  it("снимает нумерацию и буллеты", () => {
    expect(parsePlanSteps("1. Первый\n2) Второй\n- Третий\n• Четвёртый")).toEqual([
      "Первый",
      "Второй",
      "Третий",
      "Четвёртый",
    ]);
  });

  it("останавливается на разделе ЗАВИСИМОСТИ:", () => {
    const text = "1. A\n2. B\nЗАВИСИМОСТИ:\n2: 1";
    expect(parsePlanSteps(text)).toEqual(["A", "B"]);
  });

  it("останавливается на ASK_USER/QUESTION/OPTION", () => {
    expect(parsePlanSteps("1. A\nASK_USER\nQUESTION: ?\nOPTION: x")).toEqual(["A"]);
  });

  it("отбрасывает строки-артефакты с маркерами", () => {
    expect(parsePlanSteps("1. Сделай X\n2. заверши строкой NEXT_STEP")).toEqual(["Сделай X"]);
  });

  it("пустой/неструктурный план → весь текст одним шагом", () => {
    expect(parsePlanSteps("просто сделай задачу")).toEqual(["просто сделай задачу"]);
  });
});

describe("parseDeps", () => {
  it("разбирает 1-based в 0-based, разделители запятая/пробел/точка с запятой", () => {
    const deps = parseDeps("ЗАВИСИМОСТИ:\n1: -\n2: 1\n3: 1,2\n4: 2 3\n5: 1; 2", 5);
    expect(deps.map((s) => [...s].sort((a, b) => a - b))).toEqual([[], [0], [0, 1], [1, 2], [0, 1]]);
  });

  it("отбрасывает out-of-range и self-ссылки", () => {
    const deps = parseDeps("ЗАВИСИМОСТИ:\n1: 1\n2: 9\n3: 0", 3);
    expect(deps.map((s) => [...s])).toEqual([[], [], []]);
  });

  it("без раздела → все пустые", () => {
    expect(parseDeps("1. A\n2. B", 2).map((s) => [...s])).toEqual([[], []]);
  });

  it("n<=0 → пустой массив", () => {
    expect(parseDeps("ЗАВИСИМОСТИ:\n1: 2", 0)).toEqual([]);
  });
});

describe("computeWaves", () => {
  it("группирует независимые шаги в одну волну", () => {
    // 5 шагов: 0→(нет), 1→0, 2→0,1, 3→1, 4→(нет)
    const deps = parseDeps("ЗАВИСИМОСТИ:\n2: 1\n3: 1,2\n4: 2", 5);
    expect(computeWaves(5, deps)).toEqual([
      [0, 4],
      [1],
      [2, 3],
    ]);
  });

  it("цикл → последовательный фолбэк", () => {
    const deps = [new Set([1]), new Set([0])]; // 0↔1
    expect(computeWaves(2, deps)).toEqual([[0], [1]]);
  });

  it("нет зависимостей → одна волна со всеми", () => {
    expect(computeWaves(3, [new Set(), new Set(), new Set()])).toEqual([[0, 1, 2]]);
  });

  it("n=0 → []", () => {
    expect(computeWaves(0, [])).toEqual([]);
  });
});

describe("parseVerdict", () => {
  it("ВЫПОЛНЕНО → true", () => {
    expect(parseVerdict("отчёт\nВЕРДИКТ: ВЫПОЛНЕНО")).toBe(true);
  });
  it("НЕ ВЫПОЛНЕНО → false", () => {
    expect(parseVerdict("есть проблемы\nВЕРДИКТ: НЕ ВЫПОЛНЕНО")).toBe(false);
  });
  it("без вердикта → true (дефолт)", () => {
    expect(parseVerdict("всё ок")).toBe(true);
  });
  it("берёт ПОСЛЕДНИЙ вердикт", () => {
    expect(parseVerdict("ВЕРДИКТ: ВЫПОЛНЕНО\n...\nВЕРДИКТ: НЕ ВЫПОЛНЕНО")).toBe(false);
  });
});

describe("stripMarkers", () => {
  it("убирает раздел зависимостей и маркеры", () => {
    const text = "Результат шага\nNEXT_STEP\nЗАВИСИМОСТИ:\n2: 1";
    expect(stripMarkers(text)).toBe("Результат шага");
  });
  it("убирает блок ASK_USER/QUESTION/OPTION", () => {
    expect(stripMarkers("текст\nASK_USER\nQUESTION: ?\nOPTION: a")).toBe("текст");
  });
});

describe("wantsReplan", () => {
  it("ловит REPLAN", () => {
    expect(wantsReplan("план плох\nREPLAN")).toBe(true);
    expect(wantsReplan("всё хорошо")).toBe(false);
  });
});
