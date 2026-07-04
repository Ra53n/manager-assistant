// settingsService.ts — настройки агента (провайдер/модель/таймзона/секреты),
// которые задаются ТОЛЬКО из приложения. Паттерн write-only секрет:
//  • getPublic() НИКОГДА не отдаёт сам секрет — только hasKey + keyHint (…last4);
//  • update() применяет секрет ТОЛЬКО если он передан непустым (пустой = «не менять»).

import type { SettingsRepo } from "../store/settingsRepo.js";
import {
  PROVIDERS,
  type AgentSettings,
  type AgentSettingsPublic,
  type Provider,
  type UpdateAgentSettingsInput,
} from "../domain/types.js";
import { ValidationError } from "../domain/errors.js";

/** Маска секрета: "" если пусто, иначе "…" + последние 4 символа. */
export function maskSecret(secret: string): string {
  if (!secret) return "";
  const tail = secret.slice(-4);
  return `…${tail}`;
}

export function toPublic(s: AgentSettings): AgentSettingsPublic {
  return {
    provider: s.provider,
    defaultModel: s.defaultModel,
    defaultTimezone: s.defaultTimezone,
    hasLlmKey: s.llmApiKey.length > 0,
    llmKeyHint: maskSecret(s.llmApiKey),
    updatedAt: s.updatedAt,
  };
}

export class SettingsService {
  constructor(private readonly repo: SettingsRepo) {}

  /** Полные настройки С СЕКРЕТАМИ — только для внутреннего использования (runner). */
  getInternal(): AgentSettings {
    return this.repo.get();
  }

  /** Публичные настройки с замаскированными секретами — для GET /agent/settings. */
  getPublic(): AgentSettingsPublic {
    return toPublic(this.repo.get());
  }

  /**
   * Применяет частичное обновление. Несекретные поля — если переданы; секрет
   * (llmApiKey) — ТОЛЬКО если передан непустым (пустой = «не менять»). Возвращает
   * замаскированное публичное представление.
   */
  update(input: UpdateAgentSettingsInput, now: string): AgentSettingsPublic {
    const current = this.repo.get();
    const next: AgentSettings = { ...current, updatedAt: now };

    if (input.provider !== undefined) {
      if (!PROVIDERS.includes(input.provider as Provider)) {
        throw new ValidationError(`Неизвестный провайдер: ${input.provider}`);
      }
      next.provider = input.provider;
    }
    if (input.defaultModel !== undefined) {
      next.defaultModel = input.defaultModel.trim();
    }
    if (input.defaultTimezone !== undefined) {
      const tz = input.defaultTimezone.trim();
      if (tz && !isValidTimezone(tz)) {
        throw new ValidationError(`Некорректная таймзона: ${tz}`);
      }
      if (tz) next.defaultTimezone = tz;
    }
    if (typeof input.llmApiKey === "string" && input.llmApiKey.trim().length > 0) {
      next.llmApiKey = input.llmApiKey.trim();
    }

    return toPublic(this.repo.replace(next));
  }
}

/** Проверка IANA-таймзоны через Intl (без внешних зависимостей). */
export function isValidTimezone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
