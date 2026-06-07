import Foundation

/// Ошибки клиента с понятными для пользователя текстами.
enum DeepSeekError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case badStatus(code: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API-ключ не найден. Положи ключ в файл ~/.config/manager-assistant/deepseek.key (или задай переменную окружения DEEPSEEK_API_KEY)."
        case .invalidURL:
            return "Некорректный URL запроса."
        case .badStatus(let code, let message):
            return "Ошибка API (\(code)): \(message)"
        case .emptyResponse:
            return "Пустой ответ от модели."
        }
    }
}

/// Клиент к DeepSeek (OpenAI-совместимый chat/completions).
struct DeepSeekClient {

    /// Отправляет всю историю переписки с заданными параметрами генерации
    /// и возвращает текст ответа ассистента вместе с расходом токенов.
    func send(messages: [ChatMessage], settings: GenerationSettings) async throws -> SendResult {
        guard !Config.isAPIKeyMissing else {
            throw DeepSeekError.missingAPIKey
        }
        guard let url = URL(string: Config.baseURL) else {
            throw DeepSeekError.invalidURL
        }

        // Собираем сообщения: системный промпт (из настроек чата) + вся история диалога.
        var payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: PromptBuilder.systemPrompt(for: settings))
        ]
        payloadMessages.append(contentsOf: messages.map {
            .init(role: $0.role.rawValue, content: $0.content)
        })

        let model = settings.model.isEmpty ? Config.model : settings.model
        let body = ChatRequest(
            model: model,
            messages: payloadMessages,
            stream: false,
            temperature: settings.temperature,
            top_p: settings.topP,
            max_tokens: settings.maxTokens,
            stop: settings.stop.isEmpty ? nil : settings.stop
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Config.deepSeekAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.badStatus(code: -1, message: "нет HTTP-ответа")
        }

        guard (200...299).contains(http.statusCode) else {
            // Пытаемся достать осмысленное сообщение об ошибке от API.
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)
                ?? "неизвестная ошибка"
            throw DeepSeekError.badStatus(code: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw DeepSeekError.emptyResponse
        }
        return SendResult(
            text: text,
            promptTokens: decoded.usage?.prompt_tokens ?? 0,
            completionTokens: decoded.usage?.completion_tokens ?? 0,
            totalTokens: decoded.usage?.total_tokens ?? 0
        )
    }

    /// Загружает список доступных моделей через GET /models.
    func fetchModels() async throws -> [String] {
        guard !Config.isAPIKeyMissing else { throw DeepSeekError.missingAPIKey }
        guard let url = URL(string: Config.modelsURL) else { throw DeepSeekError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(Config.deepSeekAPIKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DeepSeekError.badStatus(code: code, message: "не удалось получить список моделей")
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { $0.id }
    }
}
