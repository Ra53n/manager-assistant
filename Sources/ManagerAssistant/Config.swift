import Foundation

/// Базовая конфигурация приложения.
///
/// Ключи провайдеров хранятся вне репозитория (см. `KeyStore`):
///   ~/.config/manager-assistant/deepseek.key
///   ~/.config/manager-assistant/openrouter.key
/// Их можно задать прямо в приложении (кнопка «API-ключи») или переменными
/// окружения DEEPSEEK_API_KEY / OPENROUTER_API_KEY.
enum Config {
    /// Модель по умолчанию (DeepSeek).
    static let model = "deepseek-chat"

    /// Системный промпт, задающий поведение ассистента.
    static let systemPrompt = "Ты — полезный ассистент. Отвечай кратко и по делу."
}
