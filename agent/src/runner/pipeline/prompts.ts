// prompts.ts — промпты этапов пайплайна (порт ролей из Swift `PipelinePrompts`,
// Models.swift ~558-665, 804-858). Headless-вариант: БЕЗ инвариантов, БЕЗ профиля,
// БЕЗ guidance/ASK_USER (нет живого пользователя в кроне). Только содержательные роли
// и структурный контекст.

import { NEXT_STEP_MARKER, REPLAN_MARKER } from "./parsers.js";

export type PipelineState = "planning" | "execution" | "validation" | "answer";

const STATE_LABEL: Record<PipelineState, string> = {
  planning: "Планирование",
  execution: "Выполнение",
  validation: "Проверка",
  answer: "Ответ",
};

/** Контекст для сборки user-сообщения главного цикла (sequential-путь). */
export interface PromptContext {
  task: string;
  state: PipelineState;
  current: string;
  plan: string[];
  done: string[];
  step: number;
  total: number;
  validationResult: string;
  executionRetries: number;
  planFeedback: string;
}

/** Нумерованный список с выравниванием под метку блока (как в приложении). */
export function numbered(items: string[]): string {
  if (items.length === 0) return "—";
  return items.map((s, i) => `${i + 1}. ${s}`).join("\n           ");
}

/** Системный промпт (роль) этапа. `swarm` — просить у планировщика блок зависимостей. */
export function systemPromptFor(state: PipelineState, swarm = false): string {
  switch (state) {
    case "planning": {
      let s =
        "Ты — планировщик. По задаче из [QUERY] составь чёткий пошаговый план: " +
        "пронумерованные шаги (1., 2., 3., …), каждый шаг — одно конкретное действие по " +
        "сути задачи, без воды. Не выполняй задачу — только спланируй. НЕ добавляй " +
        "служебных/протокольных шагов (например «заверши ответ строкой …», «выведи " +
        "маркер») — только содержательные действия. Верни ТОЛЬКО план.";
      if (swarm) {
        s +=
          "\n\n" +
          "После плана ОБЯЗАТЕЛЬНО добавь раздел зависимостей в формате:\n" +
          "ЗАВИСИМОСТИ:\n" +
          "<номер шага>: <номера шагов, от которых он зависит через запятую>\n" +
          "Указывай ТОЛЬКО реальные зависимости по данным/порядку. Независимые шаги не " +
          "перечисляй (или пиши «<номер>: -») — они будут выполнены параллельно. Стремись к " +
          "максимальной параллельности: не вводи лишних зависимостей.";
      }
      return s;
    }
    case "execution":
      return (
        "Ты — исполнитель. Выполни ТОЛЬКО текущий шаг [CURRENT] (НЕ весь план сразу). Уже " +
        "сделанное в [DONE] используй как контекст. Для действий вызывай доступные " +
        "инструменты и доводи шаг до фактического результата. Дай полный результат этого " +
        `шага. Когда шаг выполнен — заверши ответ ОТДЕЛЬНОЙ ПОСЛЕДНЕЙ строкой «${NEXT_STEP_MARKER}». ` +
        "Если по ходу стало ясно, что план непригоден и нужно перепланировать — вместо этого " +
        `заверши ответ строкой «${REPLAN_MARKER}».`
      );
    case "validation":
      return (
        "Ты — проверяющий. Сверь сделанное ([DONE]) с планом и исходной задачей ([QUERY]). " +
        "Перечисли, что выполнено, что нет, и какие есть проблемы. ПОСЛЕДНЕЙ строкой выведи " +
        "РОВНО одно из двух: «ВЕРДИКТ: ВЫПОЛНЕНО» либо «ВЕРДИКТ: НЕ ВЫПОЛНЕНО»."
      );
    case "answer":
      return (
        "Сформируй ФИНАЛЬНЫЙ ОТВЕТ на исходную задачу ([QUERY]) — именно его получит " +
        "пользователь как результат. Опираясь на план и сделанное ([DONE]), дай полный, " +
        "готовый к использованию ответ ПО СУЩЕСТВУ: само решение и всю полезную информацию — " +
        "что сделано, важные детали, итоги. Пиши так, будто отвечаешь на запрос напрямую. " +
        "КАТЕГОРИЧЕСКИ НЕ описывай процесс/этапы и НЕ пиши мета-фразы вроде «задача " +
        "выполнена», «всё проверено» — выдай только сам ответ."
      );
  }
}

/** User-сообщение главного цикла (sequential-путь): структурный блок контекста + правила. */
export function buildPrompt(ctx: PromptContext): string {
  const stepInfo =
    ctx.state === "execution" && ctx.total > 0 ? `, шаг ${ctx.step + 1}/${ctx.total}` : "";
  let s =
    `[STATE]    ${ctx.state}${stepInfo}\n` +
    `[CURRENT]  ${ctx.current || "—"}\n` +
    `[PLAN]     ${numbered(ctx.plan)}\n` +
    `[DONE]     ${numbered(ctx.done)}\n` +
    `[QUERY]    ${ctx.task}\n\n` +
    "Правила:\n" +
    "- Работай только в рамках текущего шага [CURRENT]; не перепрыгивай этапы и шаги.\n" +
    `- Если текущий шаг выполнен — заверши ответ строкой «${NEXT_STEP_MARKER}».\n` +
    `- Если план непригоден — заверши ответ строкой «${REPLAN_MARKER}».\n` +
    "- Переходы между этапами решает оркестратор. Соблюдай молча, не упоминай.";

  // Замечания проверки прокидываем в повтор выполнения.
  const v = ctx.validationResult.trim();
  if (ctx.state === "execution" && ctx.executionRetries > 0 && v) {
    s += `\n\n[ЗАМЕЧАНИЯ ПРОВЕРКИ — учти при переделке]\n${v}`;
  }
  // Причину перепланирования прокидываем в планирование.
  const fb = ctx.planFeedback.trim();
  if (ctx.state === "planning" && fb) {
    s += `\n\n[ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ / ПРАВКИ]\n${fb}`;
  }
  return s;
}

/** Системный промпт подагента роя (исполнитель ОДНОГО шага с узким контекстом). */
export function subAgentSystemPrompt(): string {
  return (
    "Ты — подагент-исполнитель в рое. Выполни ТОЛЬКО порученный шаг [STEP] полностью и " +
    "самодостаточно. Используй [DEPS] (результаты шагов, от которых зависит твой) как вход; " +
    "[PLAN] — общий контекст. Для действий вызывай доступные инструменты. НЕ выполняй другие " +
    "шаги и НЕ задавай вопросов — дай готовый результат своего шага. Если шаг невозможен без " +
    `переплана — заверши ответ строкой «${REPLAN_MARKER}».`
  );
}

/**
 * User-сообщение подагенту: узкий контекст (обзор плана + ТОЛЬКО выводы зависимостей +
 * текущий шаг). Полный [DONE] НЕ передаём — экономия токенов/контекста.
 */
export function subAgentPrompt(params: {
  task: string;
  stepIndex: number;
  plan: string[];
  deps: Set<number>;
  stepResults: string[];
}): string {
  const { task, stepIndex, plan, deps, stepResults } = params;
  const depList = [...deps].sort((a, b) => a - b);
  let depsText: string;
  if (depList.length === 0) {
    depsText = "—";
  } else {
    depsText = depList
      .map((idx) => {
        const res = (idx < stepResults.length ? stepResults[idx]! : "").trim();
        const title = idx < plan.length ? plan[idx]! : `шаг ${idx + 1}`;
        return `• Шаг ${idx + 1} (${title}):\n${res || "—"}`;
      })
      .join("\n");
  }
  const step = stepIndex < plan.length ? plan[stepIndex]! : "";
  return (
    `[QUERY]    ${task}\n` +
    `[PLAN]     ${numbered(plan)}\n` +
    `[STEP]     ${stepIndex + 1}. ${step}\n` +
    "[DEPS]\n" +
    `${depsText}\n\n` +
    "Дай полный результат шага [STEP]."
  );
}

export { STATE_LABEL };
