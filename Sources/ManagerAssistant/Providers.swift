// Providers.swift — мультипровайдерность и хранение ключей.
//
// Provider — перечисление OpenAI-совместимых провайдеров (DeepSeek, OpenRouter):
// у каждого свой chat-endpoint, endpoint списка моделей, файл ключа и env-var.
// Добавление нового провайдера = новый case + заполнение этих полей; UI
// (пикер моделей, лист ключей) подхватит его автоматически через allCases.
//
// KeyStore — ключи лежат ВНЕ репозитория в ~/.config/manager-assistant/<p>.key
// (или в env-переменных, env приоритетнее). Никогда не хардкодить ключи в код
// и не коммитить их: перед каждым коммитом диф сканируется на «sk-».
//
// DeepSeekPricing — захардкоженный прайс DeepSeek (их /models цен не отдаёт);
// цены OpenRouter приходят живыми из их /models. Используется для расчёта
// стоимости в MessageMetrics (см. ChatViewModel.send).

import Foundation

/// Поставщик OpenAI-совместимого API.
enum Provider: String, CaseIterable, Codable, Hashable {
    case deepseek
    case openrouter

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Endpoint chat/completions.
    var chatURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        }
    }

    /// Endpoint со списком моделей.
    var modelsURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/models"
        case .openrouter: return "https://openrouter.ai/api/v1/models"
        }
    }

    /// Имя файла с ключом в каталоге KeyStore.
    var keyFileName: String {
        switch self {
        case .deepseek: return "deepseek.key"
        case .openrouter: return "openrouter.key"
        }
    }

    /// Переменная окружения с ключом (имеет приоритет над файлом).
    var envVar: String {
        switch self {
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .openrouter: return "OPENROUTER_API_KEY"
        }
    }

    /// Подсказка, где взять ключ.
    var keyHint: String {
        switch self {
        case .deepseek: return "Ключ с platform.deepseek.com (sk-...)"
        case .openrouter: return "Ключ с openrouter.ai/keys (sk-or-...)"
        }
    }
}

/// Цена модели в USD за один токен.
struct ModelPricing: Equatable {
    let promptPerToken: Double
    let completionPerToken: Double
}

/// Прайс DeepSeek (их /models не отдаёт цены). USD за 1M токенов → за токен.
/// Источник: api-docs.deepseek.com/quick_start/pricing (стандартные ставки, cache miss).
enum DeepSeekPricing {
    private static func perToken(_ inputPer1M: Double, _ outputPer1M: Double) -> ModelPricing {
        ModelPricing(promptPerToken: inputPer1M / 1_000_000, completionPerToken: outputPer1M / 1_000_000)
    }

    static let table: [String: ModelPricing] = [
        "deepseek-v4-flash": perToken(0.14, 0.28),
        "deepseek-v4-pro":   perToken(1.74, 3.48),
        // Алиасы — приблизительно по соответствующему тиру.
        "deepseek-chat":     perToken(0.14, 0.28),
        "deepseek-reasoner": perToken(1.74, 3.48),
    ]

    /// Окна контекста DeepSeek (их /models этого не отдаёт).
    /// По докам V4: 1M контекст у обеих моделей; алиасы указывают на V4-Flash.
    static let contextLimits: [String: Int] = [
        "deepseek-v4-flash": 1_000_000,
        "deepseek-v4-pro":   1_000_000,
        "deepseek-chat":     1_000_000,
        "deepseek-reasoner": 1_000_000,
    ]
}

/// Хранилище ключей в ~/.config/manager-assistant/<provider>.key (вне репозитория).
enum KeyStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/manager-assistant")
    }

    static func keyURL(for provider: Provider) -> URL {
        directory.appendingPathComponent(provider.keyFileName)
    }

    /// Ключ провайдера: сначала переменная окружения, затем файл.
    static func key(for provider: Provider) -> String {
        if let value = ProcessInfo.processInfo.environment[provider.envVar],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fileKey = try? String(contentsOf: keyURL(for: provider), encoding: .utf8) {
            return fileKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func hasKey(for provider: Provider) -> Bool {
        !key(for: provider).isEmpty
    }

    /// Сохраняет ключ; пустая строка удаляет файл.
    static func setKey(_ value: String, for provider: Provider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: keyURL(for: provider))
        } else {
            try? trimmed.write(to: keyURL(for: provider), atomically: true, encoding: .utf8)
        }
    }
}
