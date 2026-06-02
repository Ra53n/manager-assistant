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

/// Отдельный чат со своим контекстом (историей), тайтлом и состоянием.
/// У каждого чата своя история — удаление чата полностью очищает его контекст.
struct Chat: Identifiable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var isLoading: Bool = false
    var errorText: String? = nil
}

// MARK: - DTO запроса (OpenAI-совместимый формат)

struct ChatRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let stream: Bool

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
