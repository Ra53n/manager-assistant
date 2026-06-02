import Foundation

/// Роль сообщения в диалоге.
enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

/// Одно сообщение в чате (для UI и для отправки в API).
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let content: String
}

/// Параметры генерации DeepSeek, настраиваемые на каждый чат.
/// Включены только реально поддерживаемые API параметры.
/// (top_k DeepSeek не принимает; frequency/presence_penalty — deprecated.)
struct GenerationSettings: Equatable {
    /// Температура сэмплирования, 0…2. Выше — креативнее, ниже — детерминированнее.
    var temperature: Double = 1.0
    /// Nucleus sampling (top_p), 0…1.
    var topP: Double = 1.0
    /// Максимум токенов в ответе.
    var maxTokens: Int = 4096
    /// Стоп-последовательности (до 16). Пустой массив — не отправлять.
    var stop: [String] = []

    static let `default` = GenerationSettings()

    /// Диапазоны/границы для UI.
    static let temperatureRange = 0.0...2.0
    static let topPRange = 0.0...1.0
    static let maxTokensRange = 256...8192
    static let maxStopCount = 16
}

/// Отдельный чат со своим контекстом (историей), тайтлом, состоянием и настройками.
/// У каждого чата своя история — удаление чата полностью очищает его контекст.
struct Chat: Identifiable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var isLoading: Bool = false
    var errorText: String? = nil
    var settings = GenerationSettings()
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

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let role: String
        let content: String
    }
}

/// Формат ошибки, который возвращает DeepSeek при не-2xx.
struct APIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
        let type: String?
    }
}
