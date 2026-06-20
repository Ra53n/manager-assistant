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
    func send(messages: [ChatMessage], settings: GenerationSettings, summary: String? = nil, facts: String? = nil, memory: String? = nil, inProject: Bool = false, profile: String? = nil) async throws -> SendResult {
        var payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: PromptBuilder.systemPrompt(for: settings, summary: summary, facts: facts, memory: memory, inProject: inProject, profile: profile))
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

    /// Один шаг конечного автомата задачи (FSM): отдельный запрос с захардкоженным
    /// системным промптом этапа (PipelinePrompts) и собранным user-сообщением.
    /// Уважает отмену Task (внутри URLSession.data(for:)).
    func runPhase(systemPrompt: String, userMessage: String, settings: GenerationSettings) async throws -> SendResult {
        let payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: systemPrompt),
            .init(role: ChatRole.user.rawValue, content: userMessage),
        ]
        return try await post(
            payloadMessages: payloadMessages,
            settings: settings,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            stop: settings.stop
        )
    }

    /// Доп. запрос-валидатор инвариантов: проверяет ОТВЕТ на список ограничений и
    /// возвращает нарушенные (парсит строки «НАРУШЕН: <название>»). Best-effort.
    func checkInvariants(response: String, invariants: [Invariant], settings: GenerationSettings) async throws -> [InvariantViolation] {
        let checkable = invariants.filter { $0.enabled }
        guard !checkable.isEmpty, !response.isEmpty else { return [] }
        let list = checkable.map { inv in
            "- \(inv.name.isEmpty ? inv.kind.title : inv.name): \(inv.description)"
        }.joined(separator: "\n")
        let system = """
        Ты — проверяющий инвариантов (ограничений). Дан ОТВЕТ и список ИНВАРИАНТОВ. \
        Определи, какие инварианты НАРУШЕНЫ этим ответом. Для КАЖДОГО нарушенного выведи \
        ОТДЕЛЬНОЙ строкой «НАРУШЕН: <название>». Если все соблюдены — выведи ровно \
        «ВСЕ СОБЛЮДЕНЫ». Без пояснений и лишнего текста.
        """
        let user = "ИНВАРИАНТЫ:\n\(list)\n\nОТВЕТ:\n\(response)"
        let payload: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: system),
            .init(role: ChatRole.user.rawValue, content: user),
        ]
        let result = try await post(payloadMessages: payload, settings: settings,
                                    temperature: 0.1, maxTokens: 512, stop: [])
        var violations: [InvariantViolation] = []
        for raw in result.text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: "НАРУШЕН:", options: [.caseInsensitive]) else { continue }
            let nm = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " «»\"<>"))
            guard !nm.isEmpty else { continue }
            let inv = checkable.first { $0.name.caseInsensitiveCompare(nm) == .orderedSame }
            violations.append(InvariantViolation(name: nm, description: inv?.description ?? nm))
        }
        return violations
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

    /// Обновляет блок «факты» (ключ-значение) по последним сообщениям —
    /// для стратегии Sticky Facts.
    func updateFacts(previousFacts: String, recent: [ChatMessage], settings: GenerationSettings) async throws -> SendResult {
        let system = """
        Ты ведёшь компактный блок ФАКТОВ о диалоге пользователя с ассистентом в формате \
        «ключ: значение» (по одному на строку). Сохраняй важное: цель, ограничения, \
        предпочтения, принятые решения, договорённости, имена, числа. Если новое сообщение \
        отменяет старый факт — обнови/удали его, не дублируй. Верни ТОЛЬКО обновлённый \
        список фактов, без пояснений.
        """
        var text = ""
        if !previousFacts.isEmpty {
            text += "Текущие факты:\n\(previousFacts)\n\n"
        }
        text += "Новые сообщения:\n"
        for m in recent {
            text += "[\(m.role == .user ? "Пользователь" : "Ассистент")]: \(m.content)\n"
        }
        let payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: system),
            .init(role: ChatRole.user.rawValue, content: text),
        ]
        return try await post(
            payloadMessages: payloadMessages,
            settings: settings,
            temperature: 0.2,
            maxTokens: 1024,
            stop: []
        )
    }

    /// Предлагает кандидатов в память по последним сообщениям (ассистент памяти).
    /// Возвращает строки строго формата `SCOPE | KIND | текст` — их парсит
    /// ChatViewModel.parseSuggestions. Низкая температура — детерминированность.
    func suggestMemory(recent: [ChatMessage], existing: String, settings: GenerationSettings) async throws -> SendResult {
        // Два уровня: долговременный профиль ПОЛЬЗОВАТЕЛЯ + ДЕТАЛИ текущего диалога
        // (краткосрочная). «Замок» от затопления долговременной — и здесь в промпте,
        // и в парсере (ChatViewModel.parseSuggestions). Промпт спроектирован и
        // состязательно проверен воркфлоу design-memory-extraction-prompt.
        let system = """
        Ты — модуль извлечения памяти. На вход подаются ПОСЛЕДНИЕ сообщения чата (реплики пользователя и ассистента). Извлеки из них записи памяти ДВУХ уровней и выведи каждую отдельной строкой строго в формате:

        SCOPE | KIND | текст

        где SCOPE ∈ {longTerm, shortTerm}, KIND ∈ {profile, preference, knowledge, decision, note}.

        УРОВНИ (SCOPE):
        - longTerm — устойчивое о САМОМ ПОЛЬЗОВАТЕЛЕ, что верно и пригодится ВНЕ этого диалога и этой задачи: кто он (роль, профессия, команда, контекст), его постоянные предпочтения и привычки, универсальные знания о нём. Это переживёт текущий разговор.
        - shortTerm — ВАЖНЫЕ ДЕТАЛИ ТЕКУЩЕГО диалога/задачи: конкретные факты, принятые решения, выборы технологий, ограничения, числа, форматы, сроки, договорённости, имена, на чём сейчас фокус. Их легко потерять — фиксируй обязательно.

        ГЛАВНОЕ ПРАВИЛО (анти-баг, соблюдай строго): детали ТЕКУЩЕЙ задачи/диалога ВСЕГДА идут в shortTerm, НЕ в longTerm. В longTerm — ТОЛЬКО то, что относится к пользователю вообще и переживёт этот разговор. Сомневаешься, привязан ли факт к текущей теме, — ставь shortTerm.

        КАК РЕШАТЬ (для каждого нового факта):
        1. Сформулируй факт одной короткой фразой.
        2. Спроси: «Переживёт ли он текущий диалог/задачу и описывает ли он пользователя вообще?» ДА → longTerm. Если это конкретное значение, выбор, ограничение, договорённость, имя, число, формат, сущность/поле или текущий фокус → НЕТ → shortTerm.
        3. При любом сомнении → shortTerm.

        ЗАМОК ПРОТИВ ЗАТОПЛЕНИЯ longTerm: KIND knowledge в longTerm допустим ТОЛЬКО про самого пользователя (что ОН устойчиво знает/умеет). Названия технологий, библиотек, инструментов, архитектура, модель данных, сущности, поля, форматы и любые технические факты, выбранные ИЛИ обсуждаемые ДЛЯ текущей задачи, — это shortTerm (decision/note), даже если звучат как устойчивое знание. Пример: «Core Data / модель данных Meeting,Segment» и «движок Whisper medium» → shortTerm, НЕ longTerm.

        KIND — как выбирать:
        - profile — кто пользователь (роль, сфера, команда, контекст). Только longTerm.
        - preference — как он постоянно предпочитает, чтобы было. Только longTerm.
        - knowledge — устойчивое знание/навык САМОГО пользователя. Только longTerm.
        - decision — принятое в диалоге решение или выбор. Только shortTerm.
        - note — конкретная деталь, число, ограничение, форма, фокус, договорённость задачи. Только shortTerm.

        ОБРАЗЦЫ ВЫВОДА:
        longTerm | profile | Пользователь — Android-разработчик, пишет на Kotlin
        longTerm | preference | Предпочитает краткие ответы по пунктам
        longTerm | profile | Работает в команде Avito Android
        shortTerm | note | Фокус диалога — экран импорта
        shortTerm | decision | Поддерживаемые форматы: mp3/wav, лимит файла 1 час
        shortTerm | decision | Движок распознавания — Whisper medium офлайн
        shortTerm | decision | Хранилище — Core Data; модель: Meeting(uuid,title,createdAt), Segment(meetingID,startTime,text)

        КОНТР-ПРИМЕР (как НЕ надо): «в этом проекте используем шрифт Inter 16px» — это деталь текущей задачи, а НЕ постоянное предпочтение пользователя. Неверно: longTerm | preference | ... . Верно: shortTerm | note | В текущем проекте шрифт Inter 16px.

        ПРАВИЛА ВЫВОДА:
        - Не извлекай вежливость, общие фразы, воду, рассуждения ассистента и дубли.
        - До 6 строк, по одной записи на строку. Бери только действительно важное.
        - Текст записи — короткий, самодостаточный, по-русски.
        - Никаких заголовков, нумерации, markdown и пояснений — только строки формата SCOPE | KIND | текст.
        - Если извлекать нечего — выведи пустую строку и ничего больше.
        """
        var text = ""
        if !existing.isEmpty {
            text += "Уже в памяти (не дублируй):\n\(existing)\n\n"
        }
        text += "Новые сообщения:\n"
        for m in recent {
            text += "[\(m.role == .user ? "Пользователь" : "Ассистент")]: \(m.content)\n"
        }
        let payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: system),
            .init(role: ChatRole.user.rawValue, content: text),
        ]
        return try await post(
            payloadMessages: payloadMessages,
            settings: settings,
            temperature: 0.2,
            maxTokens: 700,
            stop: []
        )
    }

    /// Короткий заголовок (3–7 слов) для секции проекта по её тексту.
    func sectionTitle(for body: String, settings: GenerationSettings) async throws -> SendResult {
        let system = """
        Придумай короткий заголовок (3–7 слов) для этого фрагмента работы по проекту. \
        Верни ТОЛЬКО заголовок, без кавычек и пояснений.
        """
        // Тело можно усечь для дешевизны — заголовку хватит начала.
        let snippet = String(body.prefix(2000))
        let payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: system),
            .init(role: ChatRole.user.rawValue, content: snippet),
        ]
        return try await post(payloadMessages: payloadMessages, settings: settings,
                              temperature: 0.2, maxTokens: 32, stop: [])
    }

    /// «Собрать»: сшивает ПОЛНЫЕ тела секций проекта в единый итоговый документ.
    func assembleProject(title: String, brief: String, entries: [ProjectEntry], settings: GenerationSettings) async throws -> SendResult {
        let system = """
        Ты собираешь связный итоговый документ из рабочих секций проекта. Дано \
        название, цель (бриф) и набор секций (полные тексты). Объедини их в единый, \
        непротиворечивый, структурированный результат: убери дубли и противоречия, \
        сохрани ВСЕ важные детали, числа и решения. Пиши развёрнуто и полно. Верни \
        готовый документ.
        """
        var text = "Проект: \(title)\n"
        if !brief.isEmpty { text += "Инструкции: \(brief)\n" }
        text += "\nСекции:\n"
        for e in entries where !e.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n## \(e.title)\n\(e.body)\n"
        }
        let payloadMessages: [ChatRequest.RequestMessage] = [
            .init(role: ChatRole.system.rawValue, content: system),
            .init(role: ChatRole.user.rawValue, content: text),
        ]
        // Большой лимит ответа — итог может быть длинным.
        return try await post(payloadMessages: payloadMessages, settings: settings,
                              temperature: 0.3, maxTokens: max(settings.maxTokens, 4096), stop: [])
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
