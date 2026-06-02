import Foundation

/// Конфигурация приложения.
///
/// Безопасность: API-ключ НЕ хранится в коде и НЕ попадает в git.
/// Ключ читается во время выполнения из (в порядке приоритета):
///   1. переменной окружения `DEEPSEEK_API_KEY` (удобно для `swift run` / схемы Xcode);
///   2. файла `~/.config/manager-assistant/deepseek.key` (работает и для собранного .app).
///
/// Чтобы задать ключ, положи его в файл:
///   mkdir -p ~/.config/manager-assistant
///   echo "sk-..." > ~/.config/manager-assistant/deepseek.key
enum Config {
    /// OpenAI-совместимый endpoint DeepSeek.
    static let baseURL = "https://api.deepseek.com/chat/completions"

    /// Модель: "deepseek-chat" (V3) — обычный чат;
    /// "deepseek-reasoner" (R1) — с рассуждениями.
    static let model = "deepseek-chat"

    /// Системный промпт, задающий поведение ассистента.
    static let systemPrompt = "Ты — полезный ассистент. Отвечай кратко и по делу."

    /// Путь к локальному файлу с ключом (вне репозитория).
    static let keyFileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/manager-assistant/deepseek.key")

    /// Ключ DeepSeek, прочитанный из окружения или локального файла.
    static var deepSeekAPIKey: String {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fileKey = try? String(contentsOf: keyFileURL, encoding: .utf8) {
            return fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Признак того, что ключ не найден.
    static var isAPIKeyMissing: Bool {
        deepSeekAPIKey.isEmpty
    }
}
