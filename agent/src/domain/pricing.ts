// pricing.ts — оценка стоимости прогона в USD по числу токенов.
// Цены DeepSeek захардкожены (их API цен не отдаёт), как в Providers.swift.
// Для OpenRouter и неизвестных моделей — null (нет данных о цене здесь).

interface PerToken {
  prompt: number;
  completion: number;
}

function per1M(input: number, output: number): PerToken {
  return { prompt: input / 1_000_000, completion: output / 1_000_000 };
}

const DEEPSEEK_PRICING: Record<string, PerToken> = {
  "deepseek-v4-flash": per1M(0.14, 0.28),
  "deepseek-v4-pro": per1M(1.74, 3.48),
  "deepseek-chat": per1M(0.14, 0.28),
  "deepseek-reasoner": per1M(1.74, 3.48),
};

/** Оценка стоимости; null, если цена модели неизвестна. */
export function estimateCostUsd(
  model: string,
  promptTokens: number,
  completionTokens: number,
): number | null {
  const p = DEEPSEEK_PRICING[model];
  if (!p) return null;
  return promptTokens * p.prompt + completionTokens * p.completion;
}
