// settingsRepo.ts — единственная строка настроек агента (id=1), С СЕКРЕТАМИ.
// Маскирование и логика «не затирать пустым секретом» — в settingsService.
// Колонки yougile_* в таблице остались от миграции v1, но БОЛЬШЕ НЕ ИСПОЛЬЗУЮТСЯ
// (доступ к MCP идёт через синхронизируемый список mcp_servers, не через настройки).

import type { DB } from "./db.js";
import type { AgentSettings, Provider } from "../domain/types.js";

interface SettingsRow {
  id: number;
  provider: string;
  llm_api_key: string;
  default_model: string;
  default_timezone: string;
  updated_at: string;
}

export class SettingsRepo {
  constructor(private readonly db: DB) {}

  get(): AgentSettings {
    const row = this.db
      .prepare(`SELECT id, provider, llm_api_key, default_model, default_timezone, updated_at FROM settings WHERE id=1`)
      .get() as SettingsRow | undefined;
    return {
      provider: (row?.provider as Provider) ?? "deepseek",
      llmApiKey: row?.llm_api_key ?? "",
      defaultModel: row?.default_model ?? "deepseek-chat",
      defaultTimezone: row?.default_timezone ?? "Europe/Moscow",
      updatedAt: row?.updated_at ?? "",
    };
  }

  replace(s: AgentSettings): AgentSettings {
    this.db
      .prepare(
        `UPDATE settings SET
           provider=@provider, llm_api_key=@llm_api_key, default_model=@default_model,
           default_timezone=@default_timezone, updated_at=@updated_at
         WHERE id=1`,
      )
      .run({
        provider: s.provider,
        llm_api_key: s.llmApiKey,
        default_model: s.defaultModel,
        default_timezone: s.defaultTimezone,
        updated_at: s.updatedAt,
      });
    return s;
  }
}
