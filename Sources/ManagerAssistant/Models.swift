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
    /// Выбранная модель DeepSeek (id из списка /models).
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
struct Chat: Identifiable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var isLoading: Bool = false
    var errorText: String? = nil
    var settings = GenerationSettings()

    /// Накопленный расход токенов по этому чату (суммарно за все запросы).
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var totalTokens: Int = 0
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

/// Ответ эндпоинта GET /models — список доступных моделей DeepSeek.
struct ModelsResponse: Decodable {
    let data: [Model]
    struct Model: Decodable {
        let id: String
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
