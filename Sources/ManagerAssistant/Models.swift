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

    static let `default` = GenerationSettings()

    /// Диапазоны/границы для UI.
    static let temperatureRange = 0.0...2.0
    static let topPRange = 0.0...1.0
    static let maxTokensRange = 256...8192
    static let maxStopCount = 16
}

/// Собирает системный промпт из настроек чата: базовая роль + формат ответа.
enum PromptBuilder {
    static func systemPrompt(for s: GenerationSettings) -> String {
        var parts: [String] = [Config.systemPrompt]

        let format = s.responseFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !format.isEmpty {
            parts.append("Формат ответа: \(format)")
        }

        return parts.joined(separator: "\n\n")
    }
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

    /// Накопленный расход токенов по этому чату (суммарно за все запросы).
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0

    /// На диск уходят только данные диалога; runtime-состояние (isLoading,
    /// errorText) не сохраняется — после перезапуска оно должно быть чистым.
    enum CodingKeys: String, CodingKey {
        case id, title, messages, settings, promptTokens, completionTokens, totalTokens
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
        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
        }
    }
}

/// Сведения о модели, полученные из /models: id + цена за токен (если есть).
struct ModelInfo {
    let id: String
    let promptPrice: Double?
    let completionPrice: Double?
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
