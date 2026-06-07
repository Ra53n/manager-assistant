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
