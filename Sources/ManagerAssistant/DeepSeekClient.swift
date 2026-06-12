// DeepSeekClient.swift — HTTP-клиент к OpenAI-совместимым API.
//
// Несмотря на имя, клиент обслуживает ВСЕХ провайдеров (DeepSeek, OpenRouter):
// endpoint и ключ берутся из settings.provider (см. Providers.swift).
//
// send(): собирает payload = системный промпт (PromptBuilder) + вся история
// чата, POST на chat/completions без стриминга, возвращает SendResult
// (текст + usage-токены). Ошибки локализованы для показа пользователю.
//
// fetchModels(): GET /models провайдера → [ModelInfo] (id + цены за токен,
// если провайдер их отдаёт — OpenRouter отдаёт, DeepSeek нет).
//
// Параметры генерации: temperature, top_p, max_tokens, stop. top_k и
// frequency/presence_penalty сознательно НЕ отправляются — DeepSeek их
// не поддерживает/игнорирует.

import Foundation

/// Ошибки клиента с понятными для пользователя текстами.
enum DeepSeekError: LocalizedError {
    case missingAPIKey(Provider)
    case invalidURL
    case badStatus(code: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Не задан API-ключ для \(provider.displayName). Открой «API-ключи» и вставь ключ."
        case .invalidURL:
            return "Некорректный URL запроса."
        case .badStatus(let code, let message):
            return "Ошибка API (\(code)): \(message)"
        case .emptyResponse:
            return "Пустой ответ от модели."
        }
    }
}

/// Клиент к OpenAI-совместимым провайдерам (DeepSeek, OpenRouter).
struct DeepSeekClient {

    /// Отправляет всю историю переписки с заданными параметрами генерации
    /// нужному провайдеру и возвращает текст ответа вместе с расходом токенов.
    func send(messages: [ChatMessage], settings: GenerationSettings) async throws -> SendResult {
        let provider = settings.provider
        let key = KeyStore.key(for: provider)
        guard !key.isEmpty else { throw DeepSeekError.missingAPIKey(provider) }
        guard let url = URL(string: provider.chatURL) else { throw DeepSeekError.invalidURL }

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
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if provider == .openrouter {
            // Необязательные заголовки OpenRouter для атрибуции.
            request.setValue("Manager assistant", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.badStatus(code: -1, message: "нет HTTP-ответа")
        }

        guard (200...299).contains(http.statusCode) else {
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

    /// Загружает модели провайдера (id + цены, если они есть в /models).
    func fetchModels(provider: Provider) async throws -> [ModelInfo] {
        let key = KeyStore.key(for: provider)
        guard !key.isEmpty else { throw DeepSeekError.missingAPIKey(provider) }
        guard let url = URL(string: provider.modelsURL) else { throw DeepSeekError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DeepSeekError.badStatus(code: code, message: "не удалось получить список моделей")
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { model in
            ModelInfo(
                id: model.id,
                promptPrice: model.pricing?.prompt.flatMap(Double.init),
                completionPrice: model.pricing?.completion.flatMap(Double.init),
                contextLength: model.context_length
            )
        }
    }
}
