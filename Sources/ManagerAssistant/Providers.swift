// Providers.swift — мультипровайдерность и хранение ключей.
//
// Provider — перечисление OpenAI-совместимых провайдеров: облачные (DeepSeek,
// OpenRouter — нужен ключ) и локальные раннеры (Ollama, LM Studio, llama.cpp —
// ключ не нужен, isLocal=true, endpoint'ы читаются из LocalEndpoints).
// Добавление нового провайдера = новый case + заполнение этих полей; UI
// (пикер моделей, лист ключей) подхватит его автоматически через allCases.
// Лист ключей фильтрует по requiresKey — локальным поля ключа не показываются.
//
// LocalEndpoints — базовые адреса локальных серверов с override в UserDefaults
// (конфиг машины, не чата — поэтому НЕ в GenerationSettings: нулевая миграция
// chats.json и синхронный доступ из computed props enum'а).
//
// KeyStore — ключи лежат ВНЕ репозитория в ~/.config/manager-assistant/<p>.key
// (или в env-переменных, env приоритетнее). Никогда не хардкодить ключи в код
// и не коммитить их: перед каждым коммитом диф сканируется на «sk-».
//
// DeepSeekPricing — захардкоженный прайс DeepSeek (их /models цен не отдаёт);
// цены OpenRouter приходят живыми из их /models. Используется для расчёта
// стоимости в MessageMetrics (см. ChatViewModel.send).

import Foundation

/// Поставщик OpenAI-совместимого API (облачный или локальный раннер).
enum Provider: String, CaseIterable, Codable, Hashable {
    case deepseek
    case openrouter
    // Своя Ollama на VPS за Caddy-прокси с bearer-токеном (agent/deploy/install-llm.sh):
    // не локальная (ничего не спавним), но и не облако (адрес из LocalEndpoints,
    // цен нет, инференс медленный — см. isSelfHosted).
    case vps
    // Локальные раннеры (облачные выше — остаются первыми в пикерах).
    case ollama
    case lmstudio
    case llamacpp

    /// Локальный раннер на этой машине (без ключа, endpoint из LocalEndpoints).
    var isLocal: Bool {
        switch self {
        case .deepseek, .openrouter, .vps: return false
        case .ollama, .lmstudio, .llamacpp: return true
        }
    }

    /// Наш собственный инференс-сервер (локальный раннер или Ollama на VPS):
    /// CPU-инференс медленный → длинный таймаут и честный маппинг сетевых ошибок.
    var isSelfHosted: Bool { isLocal || self == .vps }

    /// Нужен ли ключ API для работы (локальным — нет; VPS — да, endpoint публичный).
    var requiresKey: Bool { !isLocal }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openrouter: return "OpenRouter"
        case .vps: return "VPS (Ollama)"
        case .ollama: return "Ollama (локально)"
        case .lmstudio: return "LM Studio (локально)"
        case .llamacpp: return "llama.cpp (локально)"
        }
    }

    /// Endpoint chat/completions.
    var chatURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .vps, .ollama, .lmstudio, .llamacpp:
            return LocalEndpoints.baseURL(for: self) + "/v1/chat/completions"
        }
    }

    /// Endpoint со списком моделей.
    var modelsURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/models"
        case .openrouter: return "https://openrouter.ai/api/v1/models"
        case .vps, .ollama, .lmstudio, .llamacpp:
            return LocalEndpoints.baseURL(for: self) + "/v1/models"
        }
    }

    /// Имя файла с ключом в каталоге KeyStore. У локальных ключ НЕ обязателен,
    /// но файл/переменная позволяют задать его для «llama-server --api-key».
    var keyFileName: String {
        switch self {
        case .deepseek: return "deepseek.key"
        case .openrouter: return "openrouter.key"
        case .vps: return "vps.key"
        case .ollama: return "ollama.key"
        case .lmstudio: return "lmstudio.key"
        case .llamacpp: return "llamacpp.key"
        }
    }

    /// Переменная окружения с ключом (имеет приоритет над файлом).
    var envVar: String {
        switch self {
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .openrouter: return "OPENROUTER_API_KEY"
        case .vps: return "VPS_LLM_API_KEY"
        case .ollama: return "OLLAMA_API_KEY"
        case .lmstudio: return "LMSTUDIO_API_KEY"
        case .llamacpp: return "LLAMACPP_API_KEY"
        }
    }

    /// Подсказка, где взять ключ.
    var keyHint: String {
        switch self {
        case .deepseek: return "Ключ с platform.deepseek.com (sk-...)"
        case .openrouter: return "Ключ с openrouter.ai/keys (sk-or-...)"
        case .vps: return "Токен LLM-прокси с VPS (печатает install-llm.sh)"
        case .ollama, .lmstudio, .llamacpp: return "Ключ не нужен (локальный сервер)"
        }
    }

    /// Снисходительное декодирование (паттерн ContextStrategy): неизвестный
    /// провайдер из будущего/переименованного файла → .deepseek, а не крах
    /// всего chats.json в .corrupt.json.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Provider(rawValue: raw) ?? .deepseek
    }
}

/// Базовые адреса локальных раннеров. Дефолты — стандартные порты; override
/// хранится в UserDefaults («localBaseURL.<provider>»), т.к. это конфиг машины,
/// а не чата (per-chat поля потребовали бы миграции chats.json и рассинхрон).
enum LocalEndpoints {
    private static func defaultsKey(for provider: Provider) -> String {
        "localBaseURL.\(provider.rawValue)"
    }

    /// Стандартный адрес раннера (для облачных — пусто).
    /// У .vps дефолта нет: пока пользователь не задал адрес (лист «API-ключи»),
    /// провайдер неактивен — loadModels/панель его молча пропускают.
    static func defaultBaseURL(for provider: Provider) -> String {
        switch provider {
        case .ollama: return "http://127.0.0.1:11434"
        case .lmstudio: return "http://127.0.0.1:1234"
        case .llamacpp: return "http://127.0.0.1:8080"
        case .deepseek, .openrouter, .vps: return ""
        }
    }

    /// Нормализация ввода пользователя: трим + без хвостового «/».
    static func normalize(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Актуальный базовый адрес: override из UserDefaults или дефолт.
    static func baseURL(for provider: Provider) -> String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey(for: provider))
        let normalized = normalize(stored ?? "")
        return normalized.isEmpty ? defaultBaseURL(for: provider) : normalized
    }

    /// Сохраняет адрес; пустая строка сбрасывает к дефолту.
    static func setBaseURL(_ value: String, for provider: Provider) {
        let normalized = normalize(value)
        if normalized.isEmpty || normalized == defaultBaseURL(for: provider) {
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: provider))
        } else {
            UserDefaults.standard.set(normalized, forKey: defaultsKey(for: provider))
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

// MARK: - Подключение к VPS-агенту рутин (bootstrap)

/// Адрес и токен доступа к сервису-агенту рутин. Это ЕДИНСТВЕННОЕ, что хранится
/// локально (всё остальное — провайдер/ключ/YouGile — живёт на VPS и задаётся
/// через «Настройки агента»). Лежит вне репозитория: env приоритетнее файла.
///   ~/.config/manager-assistant/agent.url   (или env MANAGER_AGENT_URL)
///   ~/.config/manager-assistant/agent.token (или env MANAGER_AGENT_TOKEN)
extension KeyStore {
    private static var agentURLFile: URL { directory.appendingPathComponent("agent.url") }
    private static var agentTokenFile: URL { directory.appendingPathComponent("agent.token") }

    private static func read(_ url: URL, env: String) -> String {
        if let v = ProcessInfo.processInfo.environment[env],
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func write(_ value: String, to url: URL) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Корневой адрес VPS, напр. «https://vps.example» (без /agent).
    static var agentURL: String { read(agentURLFile, env: "MANAGER_AGENT_URL") }
    static var agentToken: String { read(agentTokenFile, env: "MANAGER_AGENT_TOKEN") }
    static var agentConfigured: Bool { !agentURL.isEmpty && !agentToken.isEmpty }

    static func setAgentURL(_ value: String) { write(value, to: agentURLFile) }
    static func setAgentToken(_ value: String) { write(value, to: agentTokenFile) }
}
