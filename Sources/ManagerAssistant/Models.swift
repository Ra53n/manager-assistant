// Models.swift — доменная модель и DTO для API.
//
// Здесь живут:
//  - доменные типы: Chat (один чат со своей историей/настройками/токенами),
//    ChatMessage, GenerationSettings, MessageMetrics. Все Codable — они
//    сериализуются на диск через ChatStore (см. Chat.CodingKeys: runtime-поля
//    isLoading/errorText сознательно НЕ сохраняются);
//  - DTO запроса/ответа OpenAI-совместимого chat/completions (ChatRequest,
//    ChatResponse, APIErrorResponse) и списка моделей (ModelsResponse);
//  - PromptBuilder — собирает системный промпт из настроек чата.
//
// Важно: «память» модели реализована повторной отправкой ВСЕЙ истории чата
// в каждом запросе (API stateless) — поэтому promptTokens растут с каждым
// сообщением. Подробности отправки — в DeepSeekClient.swift.

import Foundation

/// Роль сообщения в диалоге.
enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

/// Метрики ответа модели (для сравнения скорости и стоимости).
struct MessageMetrics: Equatable, Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let duration: TimeInterval        // время ответа, сек (wall-clock)
    let promptCost: Double?           // USD за токены запроса (если известна цена)
    let completionCost: Double?       // USD за токены ответа

    var totalCost: Double? {
        guard let p = promptCost, let c = completionCost else { return nil }
        return p + c
    }
}

/// Одно сообщение в чате (для UI, отправки в API и сохранения на диск).
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: ChatRole
    let content: String
    /// Метрики ответа (только у сообщений ассистента).
    var metrics: MessageMetrics? = nil
}

/// Стратегия управления контекстом (по ТЗ).
enum ContextStrategy: String, Codable, CaseIterable, Identifiable {
    case full           // вся история целиком (для сравнения)
    case slidingWindow  // только последние N сообщений, остальное отбрасываем
    case stickyFacts    // блок «факты» (ключ-значение) + последние N
    case branching      // ветки диалога: чекпоинт, 2 ветки, переключение

    var id: String { rawValue }

    /// Снисходительное декодирование: неизвестное значение (напр. удалённый
    /// «summary» из старого файла) трактуем как .full, чтобы chats.json не падал.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ContextStrategy(rawValue: raw) ?? .full
    }

    /// Стратегии «что слать модели» — доступны и в сравнении (без ветвления,
    /// которое структурное и в сравнении смысла не имеет).
    static let sendStrategies: [ContextStrategy] = [.full, .slidingWindow, .stickyFacts]

    var label: String {
        switch self {
        case .full: return "Полная история"
        case .slidingWindow: return "Скользящее окно"
        case .stickyFacts: return "Факты (key-value) + окно"
        case .branching: return "Ветвление диалога"
        }
    }

    var usesWindow: Bool { self == .slidingWindow || self == .stickyFacts }

    var hint: String {
        switch self {
        case .full: return "Шлём всю историю. Точно, но токены растут с каждым сообщением."
        case .slidingWindow: return "Шлём только последние N сообщений, старое отбрасываем."
        case .stickyFacts: return "Ведём блок фактов (цель, ограничения, решения, договорённости); шлём факты + последние N."
        case .branching: return "Сохраняй чекпоинты и веди несколько веток диалога от одной точки. «Ветка отсюда» на сообщении, переключение — над лентой."
        }
    }
}

/// Что уходит в запрос при выбранной стратегии: хвост сообщений + опц. факты.
struct ContextPayload {
    let tail: [ChatMessage]
    let facts: String?
}

/// Единая логика стратегий «что слать» — используется и чатом, и окном сравнения.
enum ContextManager {
    static func payload(messages: [ChatMessage], settings: GenerationSettings, facts: String) -> ContextPayload {
        let n = max(1, settings.historyWindow)
        switch settings.contextStrategy {
        case .full, .branching:
            // Ветвление шлёт активную ветку целиком (как полная история).
            return ContextPayload(tail: messages, facts: nil)
        case .slidingWindow:
            return ContextPayload(tail: Array(messages.suffix(n)), facts: nil)
        case .stickyFacts:
            return ContextPayload(tail: Array(messages.suffix(n)), facts: facts.isEmpty ? nil : facts)
        }
    }
}

/// Параметры генерации DeepSeek, настраиваемые на каждый чат.
/// Включены только реально поддерживаемые API параметры.
/// (top_k DeepSeek не принимает; frequency/presence_penalty — deprecated.)
struct GenerationSettings: Equatable, Codable {
    /// Провайдер выбранной модели.
    var provider: Provider = .deepseek
    /// Выбранная модель (id из списка /models этого провайдера).
    var model: String = Config.model
    /// Температура сэмплирования, 0…2. Выше — креативнее, ниже — детерминированнее.
    var temperature: Double = 1.0
    /// Nucleus sampling (top_p), 0…1.
    var topP: Double = 1.0
    /// Максимум токенов в ответе.
    var maxTokens: Int = 4096
    /// Стоп-последовательности (до 16). Пустой массив — не отправлять.
    var stop: [String] = []

    /// Формат ответа — свободная текст-инструкция, как форматировать ответ.
    /// Пусто — без специальных требований к формату.
    var responseFormat: String = ""

    /// Стратегия управления контекстом (см. ContextStrategy) и размер окна N
    /// для стратегий, которые им пользуются.
    var contextStrategy: ContextStrategy = .full
    var historyWindow: Int = 10

    static let `default` = GenerationSettings()

    /// Диапазоны/границы для UI.
    static let temperatureRange = 0.0...2.0
    static let topPRange = 0.0...1.0
    static let maxTokensRange = 256...8192
    static let maxStopCount = 16
    static let historyWindowRange = 4...50

    enum CodingKeys: String, CodingKey {
        case provider, model, temperature, topP, maxTokens, stop, responseFormat
        case contextStrategy, historyWindow
    }
}

/// Миграционно-устойчивое декодирование: поля, которых нет в старом chats.json,
/// получают дефолты вместо ошибки decode (иначе любое новое поле ломало бы файл).
extension GenerationSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GenerationSettings()
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        topP = try c.decodeIfPresent(Double.self, forKey: .topP) ?? d.topP
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        stop = try c.decodeIfPresent([String].self, forKey: .stop) ?? d.stop
        responseFormat = try c.decodeIfPresent(String.self, forKey: .responseFormat) ?? d.responseFormat
        historyWindow = try c.decodeIfPresent(Int.self, forKey: .historyWindow) ?? d.historyWindow
        // Неизвестная/удалённая стратегия (старый «summary») → .full (см. ContextStrategy.init).
        contextStrategy = try c.decodeIfPresent(ContextStrategy.self, forKey: .contextStrategy) ?? .full
    }
}

/// Собирает системный промпт из настроек чата: базовая роль + саммари
/// сжатой части истории (если есть) + формат ответа.
enum PromptBuilder {
    static func systemPrompt(for s: GenerationSettings, summary: String? = nil, facts: String? = nil) -> String {
        var parts: [String] = [Config.systemPrompt]

        if let summary, !summary.isEmpty {
            parts.append("Краткое содержание более ранней части этого диалога (используй как контекст, не упоминай его существование):\n\(summary)")
        }

        if let facts, !facts.isEmpty {
            parts.append("Известные факты об этом диалоге (используй как контекст, не упоминай их существование):\n\(facts)")
        }

        let format = s.responseFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !format.isEmpty {
            parts.append("Формат ответа: \(format)")
        }

        return parts.joined(separator: "\n\n")
    }
}

/// Ветка диалога (стратегия .branching): независимая линия сообщений,
/// разделяющая общий префикс до чекпоинта с другими ветками.
struct ChatBranch: Identifiable, Codable {
    var id = UUID()
    var name: String
    var messages: [ChatMessage]
    var facts: String = ""
}

/// Отдельный чат со своим контекстом (историей), тайтлом, состоянием и настройками.
/// У каждого чата своя история — удаление чата полностью очищает его контекст.
struct Chat: Identifiable, Codable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var isLoading: Bool = false
    var errorText: String? = nil
    var settings = GenerationSettings()

    /// Накопленный расход токенов по этому чату (суммарно за все запросы,
    /// ВКЛЮЧАЯ фоновые запросы саммаризации).
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
    /// Накопленная стоимость чата в USD (ответы + саммаризация), если цена известна.
    var totalCost: Double = 0
    /// Из общего расхода — сколько ушло именно на саммаризацию (подмножество).
    var summaryTokens: Int = 0
    var summaryCost: Double = 0

    /// Компакция (стратегия .summary): messages[0..<summarizedUpTo] свёрнуты в
    /// summary и в запрос не отправляются (в UI остаются).
    var summary: String = ""
    var summarizedUpTo: Int = 0
    /// Блок «факты» (стратегия .stickyFacts) — ключ-значение, накапливается.
    var facts: String = ""
    /// Ветвление (.branching): все ветки + активная. activeBranchID == nil —
    /// ветвление ещё не создано (обычная линейная история в messages).
    /// Инвариант при ветвлении: messages == активная ветка (зеркало).
    var branches: [ChatBranch] = []
    var activeBranchID: UUID? = nil
    /// Runtime-флаг обновления фактов (не сохраняется).
    var isUpdatingFacts: Bool = false

    /// На диск уходят только данные диалога; runtime-состояние (isLoading,
    /// errorText, isSummarizing) не сохраняется.
    enum CodingKeys: String, CodingKey {
        case id, title, messages, settings, promptTokens, completionTokens, totalTokens, totalCost
        case summaryTokens, summaryCost, summary, summarizedUpTo, facts
        case branches, activeBranchID
    }
}

/// Миграционно-устойчивое декодирование (см. комментарий у GenerationSettings).
extension Chat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Новый чат"
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        settings = try c.decodeIfPresent(GenerationSettings.self, forKey: .settings) ?? GenerationSettings()
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        summaryTokens = try c.decodeIfPresent(Int.self, forKey: .summaryTokens) ?? 0
        summaryCost = try c.decodeIfPresent(Double.self, forKey: .summaryCost) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summarizedUpTo = try c.decodeIfPresent(Int.self, forKey: .summarizedUpTo) ?? 0
        facts = try c.decodeIfPresent(String.self, forKey: .facts) ?? ""
        branches = try c.decodeIfPresent([ChatBranch].self, forKey: .branches) ?? []
        activeBranchID = try c.decodeIfPresent(UUID.self, forKey: .activeBranchID)
    }
}

// MARK: - DTO запроса (OpenAI-совместимый формат)

struct ChatRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let stream: Bool
    let temperature: Double
    let top_p: Double
    let max_tokens: Int
    /// nil — ключ не отправляется (синтезированный Encodable использует encodeIfPresent).
    let stop: [String]?

    struct RequestMessage: Encodable {
        let role: String
        let content: String
    }
}

// MARK: - DTO ответа

struct ChatResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let role: String
        let content: String
    }

    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

/// Результат отправки: текст ответа + потраченные на запрос токены.
struct SendResult {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

/// Ответ эндпоинта GET /models — список доступных моделей провайдера.
/// У OpenRouter в каждой модели есть pricing (USD за токен, строками).
struct ModelsResponse: Decodable {
    let data: [Model]
    struct Model: Decodable {
        let id: String
        let pricing: Pricing?
        /// Окно контекста модели (OpenRouter отдаёт, DeepSeek — нет).
        let context_length: Int?
        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
        }
    }
}

/// Сведения о модели, полученные из /models: id + цена за токен + окно контекста.
struct ModelInfo {
    let id: String
    let promptPrice: Double?
    let completionPrice: Double?
    let contextLength: Int?
}

/// Модель в объединённом списке: провайдер + id модели.
struct ModelOption: Identifiable, Hashable {
    let provider: Provider
    let model: String
    var id: String { "\(provider.rawValue)|\(model)" }
}

/// Формат ошибки, который возвращает DeepSeek при не-2xx.
struct APIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
        let type: String?
    }
}
