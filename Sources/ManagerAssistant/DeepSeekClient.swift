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

    /// Отправляет историю переписки (хвост после компакции) с заданными
    /// параметрами генерации; summary сжатой части истории подставляется
    /// в системный промпт. Возвращает текст ответа + расход токенов.
    func send(messages: [ChatMessage], settings: GenerationSettings, summary: String? = nil) async throws -> SendResult {
        var payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: PromptBuilder.systemPrompt(for: settings, summary: summary))
        ]
        payloadMessages.append(contentsOf: messages.map {
            .init(role: $0.role.rawValue, content: $0.content)
        })
        return try await post(
            payloadMessages: payloadMessages,
            settings: settings,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            stop: settings.stop
        )
    }

    /// Сворачивает блок старых сообщений в саммари (обновляя предыдущее).
    /// Используется компакцией истории (ChatViewModel.maybeCompact).
    func summarize(previousSummary: String, block: [ChatMessage], settings: GenerationSettings) async throws -> SendResult {
        let system = """
        Ты сжимаешь историю диалога пользователя с ассистентом. Составь компактное \
        саммари (до ~200 слов): сохрани все факты, имена, числа, решения и \
        договорённости; опусти вежливость и повторы. Верни ТОЛЬКО текст саммари.
        """
        var text = ""
        if !previousSummary.isEmpty {
            text += "Текущее саммари (обнови его с учётом новых сообщений):\n\(previousSummary)\n\n"
        }
        text += "Сообщения для сжатия:\n"
        for m in block {
            text += "[\(m.role == .user ? "Пользователь" : "Ассистент")]: \(m.content)\n"
        }
        let payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: system),
            .init(role: ChatRole.user.rawValue, content: text),
        ]
        // Низкая температура — саммари должно быть фактологичным.
        return try await post(
            payloadMessages: payloadMessages,
            settings: settings,
            temperature: 0.3,
            maxTokens: 1024,
            stop: []
        )
    }

    /// Общий POST chat/completions для send() и summarize().
    private func post(
        payloadMessages: [ChatRequest.RequestMessage],
        settings: GenerationSettings,
        temperature: Double,
        maxTokens: Int,
        stop: [String]
    ) async throws -> SendResult {
        let provider = settings.provider
        let key = KeyStore.key(for: provider)
        guard !key.isEmpty else { throw DeepSeekError.missingAPIKey(provider) }
        guard let url = URL(string: provider.chatURL) else { throw DeepSeekError.invalidURL }

        let model = settings.model.isEmpty ? Config.model : settings.model
        let body = ChatRequest(
            model: model,
            messages: payloadMessages,
            stream: false,
            temperature: temperature,
            top_p: settings.topP,
            max_tokens: maxTokens,
            stop: stop.isEmpty ? nil : stop
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
