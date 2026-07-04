// config.ts — чтение и валидация bootstrap-конфигурации из окружения.
//
// ВАЖНО (по дизайну): в /etc/manager-agent.env лежит ТОЛЬКО bootstrap:
//   AGENT_API_TOKEN — bearer-токен, который приложение предъявляет API;
//   AGENT_PORT / AGENT_HOST — где слушает HTTP (по умолчанию 127.0.0.1:3100);
//   AGENT_DB_PATH — путь к SQLite-файлу;
//   AGENT_DEFAULT_TZ — дефолтная таймзона расписаний (фолбэк);
//   LOG_LEVEL — уровень логов.
// LLM-ключ, провайдер, модель и доступ к YouGile MCP здесь НЕ ХРАНЯТСЯ — они
// задаются из приложения и лежат в серверном хранилище настроек (см. settings/).

export interface BootstrapConfig {
  apiToken: string;
  host: string;
  port: number;
  dbPath: string;
  defaultTimezone: string;
  logLevel: string;
}

/** Ошибка отсутствия обязательной bootstrap-переменной (видна в journalctl). */
export class ConfigError extends Error {}

/**
 * Считывает конфигурацию из переданного окружения (по умолчанию process.env).
 * Падает с понятным сообщением, если нет обязательной переменной.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): BootstrapConfig {
  const apiToken = (env.AGENT_API_TOKEN ?? "").trim();
  if (!apiToken) {
    throw new ConfigError(
      "Не задан AGENT_API_TOKEN. Добавь его в /etc/manager-agent.env — это bearer-токен, " +
        "который вводится в приложении для доступа к агенту.",
    );
  }

  const port = parseInt(env.AGENT_PORT ?? "3100", 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new ConfigError(`Некорректный AGENT_PORT: ${env.AGENT_PORT}`);
  }

  return {
    apiToken,
    host: (env.AGENT_HOST ?? "127.0.0.1").trim(),
    port,
    dbPath: (env.AGENT_DB_PATH ?? "/opt/manager-agent/data/agent.db").trim(),
    defaultTimezone: (env.AGENT_DEFAULT_TZ ?? "Europe/Moscow").trim(),
    logLevel: (env.LOG_LEVEL ?? "info").trim(),
  };
}
