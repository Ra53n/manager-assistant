// cron.ts — валидация cron-выражений, расчёт следующего запуска (с таймзоной)
// и человекочитаемое описание расписания для UI. Опирается на croner.

import { Cron } from "croner";

/** true, если выражение cron корректно (5- или 6-польное) и таймзона валидна. */
export function isValidCron(pattern: string, timezone?: string): boolean {
  const p = (pattern ?? "").trim();
  if (!p) return false;
  try {
    // Конструктор croner бросает на некорректном паттерне/таймзоне.
    // paused: не запускаем реальный таймер при валидации.
    const c = new Cron(p, { timezone, paused: true });
    // Должен уметь посчитать следующий запуск — иначе паттерн «пустой».
    return c.nextRun() !== null;
  } catch {
    return false;
  }
}

/**
 * Следующий запуск после `from` (по умолчанию — текущий момент) в заданной
 * таймзоне. Возвращает ISO-8601 (UTC) либо null, если запусков больше нет
 * или выражение некорректно.
 */
export function nextRunISO(
  pattern: string,
  timezone: string,
  from?: Date,
): string | null {
  try {
    const c = new Cron(pattern, { timezone, paused: true });
    const next = from ? c.nextRun(from) : c.nextRun();
    return next ? next.toISOString() : null;
  } catch {
    return null;
  }
}

const RU_DAYS: Record<string, string> = {
  "0": "воскресенье",
  "1": "понедельник",
  "2": "вторник",
  "3": "среда",
  "4": "четверг",
  "5": "пятница",
  "6": "суббота",
  "7": "воскресенье",
};

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

/**
 * Человекочитаемое описание расписания на русском для частых случаев.
 * Для нестандартных выражений — возвращает само выражение как фолбэк.
 */
export function describeCron(pattern: string): string {
  const p = (pattern ?? "").trim();
  const parts = p.split(/\s+/);
  // Поддерживаем 5-польный формат (min hour dom mon dow). 6-польный (с секундами)
  // сводим к 5 последним полям для описания.
  const fields = parts.length === 6 ? parts.slice(1) : parts;
  if (fields.length !== 5) return p;

  const [min, hour, dom, mon, dow] = fields as [string, string, string, string, string];

  // каждые N минут
  const everyMin = /^\*\/(\d+)$/.exec(min);
  if (everyMin && hour === "*" && dom === "*" && mon === "*" && dow === "*") {
    return `каждые ${everyMin[1]} мин`;
  }

  // каждый час (в M минут)
  if (/^\d+$/.test(min) && hour === "*" && dom === "*" && mon === "*" && dow === "*") {
    return `каждый час в :${pad2(parseInt(min, 10))}`;
  }

  // конкретное время суток
  if (/^\d+$/.test(min) && /^\d+$/.test(hour) && mon === "*") {
    const time = `${pad2(parseInt(hour, 10))}:${pad2(parseInt(min, 10))}`;

    // каждый день
    if (dom === "*" && dow === "*") return `каждый день в ${time}`;

    // по будням
    if (dom === "*" && (dow === "1-5" || dow === "1,2,3,4,5")) {
      return `по будням в ${time}`;
    }

    // по конкретным дням недели
    if (dom === "*" && /^[0-7](,[0-7])*$/.test(dow)) {
      const days = dow
        .split(",")
        .map((d) => RU_DAYS[d] ?? d)
        .join(", ");
      return `по ${days} в ${time}`;
    }

    // конкретное число месяца
    if (/^\d+$/.test(dom) && dow === "*") {
      return `${parseInt(dom, 10)}-го числа в ${time}`;
    }
  }

  return p;
}
