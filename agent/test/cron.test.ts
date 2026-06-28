import { describe, it, expect } from "vitest";
import { describeCron, isValidCron, nextRunISO } from "../src/domain/cron.js";

describe("isValidCron", () => {
  it("принимает корректные выражения", () => {
    expect(isValidCron("0 9 * * *")).toBe(true);
    expect(isValidCron("*/15 * * * *")).toBe(true);
    expect(isValidCron("0 9 * * 1-5", "Europe/Moscow")).toBe(true);
    expect(isValidCron("30 8 1 * *")).toBe(true);
  });

  it("отвергает мусор и пустое", () => {
    expect(isValidCron("")).toBe(false);
    expect(isValidCron("не cron")).toBe(false);
    expect(isValidCron("99 99 * * *")).toBe(false);
    expect(isValidCron("0 9 * * *", "Нет/Такой")).toBe(false);
  });
});

describe("nextRunISO (таймзона)", () => {
  it("09:00 МСК = 06:00 UTC (без перехода на летнее время в РФ)", () => {
    const from = new Date("2026-06-27T00:00:00.000Z");
    const next = nextRunISO("0 9 * * *", "Europe/Moscow", from);
    expect(next).toBe("2026-06-27T06:00:00.000Z");
  });

  it("следующий слот строго после from", () => {
    const from = new Date("2026-06-27T06:00:00.000Z"); // ровно 09:00 МСК
    const next = nextRunISO("0 9 * * *", "Europe/Moscow", from);
    expect(next).toBe("2026-06-28T06:00:00.000Z");
  });

  it("возвращает null для некорректного выражения", () => {
    expect(nextRunISO("мусор", "Europe/Moscow")).toBeNull();
  });
});

describe("describeCron", () => {
  it("частые случаи на русском", () => {
    expect(describeCron("0 9 * * *")).toBe("каждый день в 09:00");
    expect(describeCron("0 9 * * 1-5")).toBe("по будням в 09:00");
    expect(describeCron("*/15 * * * *")).toBe("каждые 15 мин");
    expect(describeCron("0 * * * *")).toBe("каждый час в :00");
    expect(describeCron("30 8 1 * *")).toBe("1-го числа в 08:30");
  });

  it("нестандартное выражение возвращается как есть", () => {
    expect(describeCron("5 4 3 2 1")).toBe("5 4 3 2 1");
  });
});
