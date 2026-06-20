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
    /// Этап FSM (если сообщение — вывод этапа) + прогресс шага (для .execution). nil — обычное.
    var state: TaskState? = nil
    var step: Int? = nil
    var total: Int? = nil
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

    // MARK: Многоуровневая память (см. Memory.swift) — ОРТОГОНАЛЬНА стратегии.
    /// Подставлять долговременную (глобальную) память в системный промпт.
    var injectLongTermMemory: Bool = true
    /// Подставлять кратко-/рабочую память этого чата/его задачи.
    var injectChatMemory: Bool = true
    /// Потолок токенов на весь блок памяти (закреплённые записи не выкидываются).
    var memoryTokenBudget: Int = 1500
    /// Ассистент памяти: после каждого обмена фоном разбирает диалог на записи.
    /// По умолчанию ВКЛ — память наполняется сама (это +1 фоновый вызов на сообщение).
    /// Выкл — никаких фоновых вызовов (память пополняется только вручную).
    var memoryAssistEnabled: Bool = true
    /// Режим ассистента памяти: вкл — пишет важное САМ; выкл — ПРЕДЛАГАЕТ
    /// кандидатов, которые подтверждаешь ты (явный контроль). Работает только
    /// если memoryAssistEnabled включён. По умолчанию ВКЛ (пишет сам).
    var autoMemory: Bool = true
    /// Автосекции в проект: вкл — содержательные ответы агента целиком
    /// добавляются секцией в привязанный проект; выкл — только вручную («В проект»).
    var autoProjectSections: Bool = false

    /// Режим конечного автомата задачи (FSM): off — обычный чат; auto — все этапы
    /// (план → выполнение → проверка → ответ) подряд; plan — стоп после
    /// планирования (нужно «Принять план», как в Claude Code).
    var pipelineMode: PipelineMode = .off

    /// Как валидировать ответы на соответствие инвариантам (см. Invariant.swift):
    /// off — только промпт; code — вхождение запрещённых слов; llm — доп. запрос; both.
    var invariantValidation: InvariantValidationMode = .code

    static let `default` = GenerationSettings()

    /// Диапазоны/границы для UI.
    static let temperatureRange = 0.0...2.0
    static let topPRange = 0.0...1.0
    static let maxTokensRange = 256...8192
    static let maxStopCount = 16
    static let historyWindowRange = 4...50
    static let memoryTokenBudgetRange = 200...4000

    enum CodingKeys: String, CodingKey {
        case provider, model, temperature, topP, maxTokens, stop, responseFormat
        case contextStrategy, historyWindow
        case injectLongTermMemory, injectChatMemory, memoryTokenBudget
        case memoryAssistEnabled, autoMemory, autoProjectSections
        case pipelineMode
        case invariantValidation
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
        injectLongTermMemory = try c.decodeIfPresent(Bool.self, forKey: .injectLongTermMemory) ?? d.injectLongTermMemory
        injectChatMemory = try c.decodeIfPresent(Bool.self, forKey: .injectChatMemory) ?? d.injectChatMemory
        memoryTokenBudget = try c.decodeIfPresent(Int.self, forKey: .memoryTokenBudget) ?? d.memoryTokenBudget
        memoryAssistEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryAssistEnabled) ?? d.memoryAssistEnabled
        autoMemory = try c.decodeIfPresent(Bool.self, forKey: .autoMemory) ?? d.autoMemory
        autoProjectSections = try c.decodeIfPresent(Bool.self, forKey: .autoProjectSections) ?? d.autoProjectSections
        pipelineMode = try c.decodeIfPresent(PipelineMode.self, forKey: .pipelineMode) ?? d.pipelineMode
        invariantValidation = try c.decodeIfPresent(InvariantValidationMode.self, forKey: .invariantValidation) ?? d.invariantValidation
    }
}

/// Собирает системный промпт из настроек чата: базовая роль + саммари
/// сжатой части истории (если есть) + формат ответа.
enum PromptBuilder {
    static func systemPrompt(for s: GenerationSettings, summary: String? = nil, facts: String? = nil, memory: String? = nil, inProject: Bool = false, profile: String? = nil) -> String {
        var parts: [String] = [Config.systemPrompt]

        if let profile, !profile.isEmpty {
            parts.append("Профиль ответа — соблюдай строго:\n\(profile)")
        }

        if inProject {
            parts.append("Идёт работа над проектом. Твои ответы — это рабочие секции, которые сохраняются в память проекта и позже собираются в итоговый результат. Поэтому давай развёрнутые, самодостаточные и завершённые ответы, пригодные как готовые разделы; не обрывай мысль и не урезай детали.")
        }

        if let memory, !memory.isEmpty {
            parts.append("Память ассистента (используй как контекст для персонализации, не упоминай её существование):\n\(memory)")
        }

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

// MARK: - Конечный автомат задачи (FSM) — формальная детерминированная модель
//
// Формализация (под референс):
//  • TaskState   — состояние автомата (этап): planning/execution/validation/answer.
//  • TaskFSM     — ТАБЛИЦА переходов + проверка `allows`: единственный источник
//                  истины «из какого этапа в какие можно». Нелегальный скачок
//                  (planning→answer и т.п.) невозможен.
//  • TaskContext — сущность задачи: task/state/step/total/plan/done/current (+ служебные).
//  • PipelinePrompts.buildPrompt — сборка промпта из контекста ([STATE]/[CURRENT]/
//                  [PLAN]/[DONE]/[PROFILE]/[QUERY] + Правила).
// Переходы решает КОД (оркестратор ChatViewModel.runStateMachine) — ТОЛЬКО через
// `TaskContext.transitioned(to:)`, который сверяется с таблицей. Этап «Выполнение»
// идёт ПО ШАГАМ плана (step/total). Финальный этап .answer — это сам ОТВЕТ
// пользователю (а НЕ отчёт «задача выполнена/проверено»).

/// Режим прогона задачи через конечный автомат.
enum PipelineMode: String, Codable, CaseIterable, Identifiable {
    case off    // обычный чат, FSM выключен (текущее поведение)
    case auto   // FSM проходит все этапы подряд, без пауз
    case plan   // FSM останавливается после планирования (нужно «Принять план»)

    var id: String { rawValue }

    /// Снисходительное декодирование (как ContextStrategy): неизвестное → .off.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PipelineMode(rawValue: raw) ?? .off
    }

    var label: String {
        switch self {
        case .off: return "Обычный"
        case .auto: return "Авто"
        case .plan: return "План"
        }
    }
}

/// Состояние (этап) конечного автомата задачи — поле `state` в TaskContext.
/// Допустимость переходов задаёт ТАБЛИЦА `TaskFSM.transitions`, НЕ сам enum.
/// `.answer` — терминал (в референсе DONE), но этап выдаёт ОТВЕТ на задачу.
enum TaskState: String, Codable, CaseIterable, Identifiable {
    case planning, execution, validation, answer

    var id: String { rawValue }

    /// Снисходительное декодирование: неизвестное → .planning.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskState(rawValue: raw) ?? .planning
    }

    var label: String {
        switch self {
        case .planning: return "Планирование"
        case .execution: return "Выполнение"
        case .validation: return "Проверка"
        case .answer: return "Ответ"
        }
    }
}

/// Детерминированный конечный автомат: ЕДИНСТВЕННЫЙ источник истины о том, из какого
/// состояния в какие МОЖНО перейти. Любой переход вне таблицы запрещён — это и есть
/// «детерминизм на уровне кода» (аналог `val transitions = mapOf(...)`).
enum TaskFSM {
    static let transitions: [TaskState: [TaskState]] = [
        .planning:   [.execution],                 // только вперёд
        .execution:  [.validation, .planning],     // вперёд ИЛИ шаг назад (перепланировать)
        .validation: [.answer, .execution],        // вперёд ИЛИ шаг назад (переделать)
        .answer:     []                             // терминал
    ]

    /// Разрешён ли переход from → to по таблице.
    static func allows(_ from: TaskState, to: TaskState) -> Bool {
        transitions[from, default: []].contains(to)
    }
}

/// Статус прогона задачи.
enum TaskRunStatus: String, Codable {
    case running       // этап в полёте (есть активный Task)
    case awaitingPlan  // план готов, ждём «Принять план» (только режим .plan)
    case paused        // пользователь поставил паузу / отмена / перезапуск в середине
    case failed        // этап упал с ошибкой (не отмена)
    case finished      // дошли до Готово (терминал)

    /// Снисходительное декодирование: неизвестное → .paused (всегда возобновляемо).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskRunStatus(rawValue: raw) ?? .paused
    }
}

/// Формализованная сущность задачи (контекст автомата) — аналог `data class TaskContext`.
/// Поля task/state/step/total/plan/done/current — как в референсе; остальные —
/// служебные для оркестрации/персистентности. Имя НЕ `Task` (конфликт с `Task{}`).
struct TaskContext: Codable, Identifiable {
    var id = UUID()
    // --- поля формальной модели (референс TaskContext) ---
    var task: String                    // суть задачи (исходный запрос)
    var state: TaskState = .planning     // текущий этап автомата
    var step: Int = 0                    // прогресс ВНУТРИ этапа (индекс текущего шага, 0-based)
    var total: Int = 0                   // всего шагов на этапе (= plan.count для выполнения)
    var plan: [String] = []              // утверждённый план — СПИСОК шагов
    var done: [String] = []              // что уже сделано — результаты выполненных шагов
    var current: String = ""             // что делаем сейчас — текущий шаг
    // --- служебные поля оркестрации ---
    var mode: PipelineMode = .auto        // .auto / .plan (копируется на старте)
    var status: TaskRunStatus = .running
    var validationResult: String = ""     // вывод последней Проверки
    var validationPassed: Bool? = nil     // распарсенный вердикт
    var answer: String = ""               // вывод этапа Ответ — финальный ответ пользователю
    var executionRetries: Int = 0         // возвраты Проверка→Выполнение
    var planRetries: Int = 0              // возвраты Выполнение→Планирование
    var planFeedback: String = ""         // правки к плану (кнопка/маркер REPLAN)
    var invariantRetries: Int = 0         // перегенерации текущего ответа из-за нарушения инвариантов
    var invariantViolations: [String] = [] // нарушения для прокидывания в retry-промпт
    var errorText: String? = nil
    var startedAt: Date = Date()

    /// Лимиты возвратов (шагов назад).
    static let maxExecutionRetries = 2
    static let maxPlanRetries = 2
    static let maxInvariantRetries = 2

    enum CodingKeys: String, CodingKey {
        case id, task, state, step, total, plan, done, current
        case mode, status, validationResult, validationPassed, answer
        case executionRetries, planRetries, planFeedback, errorText, startedAt
        case invariantRetries, invariantViolations
    }
}

/// Миграционно-устойчивое декодирование + детерминированный переход.
extension TaskContext {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        state = try c.decodeIfPresent(TaskState.self, forKey: .state) ?? .planning
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        // plan: новый формат — [String]; старый тестовый — String (разобьём по шагам).
        if let arr = try? c.decode([String].self, forKey: .plan) {
            plan = arr
        } else if let s = try? c.decode(String.self, forKey: .plan) {
            plan = PipelinePrompts.parsePlanSteps(s)
        } else {
            plan = []
        }
        done = try c.decodeIfPresent([String].self, forKey: .done) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current) ?? ""
        mode = try c.decodeIfPresent(PipelineMode.self, forKey: .mode) ?? .auto
        status = try c.decodeIfPresent(TaskRunStatus.self, forKey: .status) ?? .paused
        validationResult = try c.decodeIfPresent(String.self, forKey: .validationResult) ?? ""
        validationPassed = try c.decodeIfPresent(Bool.self, forKey: .validationPassed)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        executionRetries = try c.decodeIfPresent(Int.self, forKey: .executionRetries) ?? 0
        planRetries = try c.decodeIfPresent(Int.self, forKey: .planRetries) ?? 0
        planFeedback = try c.decodeIfPresent(String.self, forKey: .planFeedback) ?? ""
        invariantRetries = try c.decodeIfPresent(Int.self, forKey: .invariantRetries) ?? 0
        invariantViolations = try c.decodeIfPresent([String].self, forKey: .invariantViolations) ?? []
        errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    }

    /// Детерминированный переход по таблице TaskFSM — аналог `fun transition(ctx, target)`.
    /// Нелегальный скачок (например planning → answer) — ошибка программиста
    /// (precondition = их `require`): такого перехода в рантайме быть не может.
    func transitioned(to target: TaskState) -> TaskContext {
        precondition(TaskFSM.allows(state, to: target),
                     "Недопустимый переход \(state.rawValue) → \(target.rawValue)")
        var c = self
        c.state = target
        return c
    }
}

/// Сборка промптов из контекста — «уровень кода»: ЧТО делает модель на каждом
/// шаге/этапе, задаёт код. Системный промпт = роль этапа; user-сообщение =
/// `buildPrompt` (блок [STATE]/[CURRENT]/[PLAN]/[DONE]/[PROFILE]/[QUERY] + Правила).
enum PipelinePrompts {
    static let nextStepMarker = "NEXT_STEP"   // модель сообщает: текущий шаг выполнен
    static let replanMarker   = "REPLAN"      // модель сообщает: план непригоден, нужен возврат

    /// Системный промпт = РОЛЬ этапа.
    static func systemPrompt(for state: TaskState) -> String {
        switch state {
        case .planning:
            return """
            Ты — планировщик. По задаче из [QUERY] составь чёткий пошаговый план: \
            пронумерованные шаги (1., 2., 3., …), каждый шаг — одно конкретное \
            действие, без воды. Не выполняй задачу — только спланируй. Верни ТОЛЬКО план.
            """
        case .execution:
            return """
            Ты — исполнитель. Выполни ТОЛЬКО текущий шаг [CURRENT] (НЕ весь план сразу). \
            Уже сделанное в [DONE] используй как контекст. Дай полный результат этого \
            шага. Когда шаг выполнен — заверши ответ ОТДЕЛЬНОЙ ПОСЛЕДНЕЙ строкой \
            «\(nextStepMarker)». Если по ходу стало ясно, что план непригоден и нужно \
            перепланировать — вместо этого заверши ответ строкой «\(replanMarker)».
            """
        case .validation:
            return """
            Ты — проверяющий. Сверь сделанное ([DONE]) с планом и исходной задачей \
            ([QUERY]). Перечисли, что выполнено, что нет, и какие есть проблемы. \
            ПОСЛЕДНЕЙ строкой выведи РОВНО одно из двух: «ВЕРДИКТ: ВЫПОЛНЕНО» либо \
            «ВЕРДИКТ: НЕ ВЫПОЛНЕНО».
            """
        case .answer:
            return """
            Сформируй ФИНАЛЬНЫЙ ОТВЕТ на исходную задачу ([QUERY]) — именно его получит \
            пользователь как результат. Опираясь на план и сделанное ([DONE]), дай \
            полный, готовый к использованию ответ ПО СУЩЕСТВУ: само решение (код / \
            текст / вывод) и всю полезную информацию — как работает, важные детали, \
            примеры использования, ограничения. Пиши так, будто отвечаешь на запрос \
            напрямую. КАТЕГОРИЧЕСКИ НЕ описывай процесс/этапы и НЕ пиши мета-фразы \
            вроде «задача выполнена», «всё проверено» — выдай только сам ответ.
            """
        }
    }

    /// User-сообщение = структурный блок контекста (аналог тела `buildPrompt(query, ctx, profile, invariants)`).
    static func buildPrompt(query: String, ctx: TaskContext, profile: String, invariants: [Invariant] = []) -> String {
        func numbered(_ items: [String]) -> String {
            items.isEmpty ? "—"
                : items.enumerated().map { "\($0.offset + 1). \($0.element)" }
                       .joined(separator: "\n           ")
        }
        let stepInfo = (ctx.state == .execution && ctx.total > 0) ? ", шаг \(ctx.step + 1)/\(ctx.total)" : ""
        let prof = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = """
        [STATE]    \(ctx.state.rawValue)\(stepInfo)
        [CURRENT]  \(ctx.current.isEmpty ? "—" : ctx.current)
        [PLAN]     \(numbered(ctx.plan))
        [DONE]     \(numbered(ctx.done))
        [PROFILE]  \(prof.isEmpty ? "—" : prof)
        [QUERY]    \(query)

        Правила:
        - Работай только в рамках текущего шага [CURRENT]; не перепрыгивай этапы и шаги.
        - Если текущий шаг выполнен — заверши ответ строкой «\(nextStepMarker)».
        - Если план непригоден — заверши ответ строкой «\(replanMarker)».
        """
        // Инварианты (ограничения) — агент ОБЯЗАН их учитывать и отказывать в нарушениях.
        let invBlock = InvariantValidator.promptBlock(invariants)
        if !invBlock.isEmpty { s += "\n\n\(invBlock)" }
        // Уже выявленные нарушения инвариантов — исправить в перегенерации.
        if !ctx.invariantViolations.isEmpty {
            s += "\n\n[НАРУШЕНЫ ИНВАРИАНТЫ — ИСПРАВЬ, перегенерируй без нарушений]\n"
                + ctx.invariantViolations.map { "- \($0)" }.joined(separator: "\n")
        }
        // Замечания проверки прокидываем в повтор выполнения.
        let v = ctx.validationResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if ctx.state == .execution, ctx.executionRetries > 0, !v.isEmpty {
            s += "\n\n[ЗАМЕЧАНИЯ ПРОВЕРКИ — учти при переделке]\n\(v)"
        }
        // Причину перепланирования прокидываем в планирование.
        let fb = ctx.planFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if ctx.state == .planning, !fb.isEmpty {
            s += "\n\n[ПРИЧИНА ПЕРЕПЛАНИРОВАНИЯ / ПРАВКИ]\n\(fb)"
        }
        return s
    }

    /// Текст плана → список шагов: снимает нумерацию/маркеры; пустой план → весь текст одним шагом.
    static func parsePlanSteps(_ text: String) -> [String] {
        var steps: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let r = line.range(of: #"^\s*(\d+[.)]|[-–•*])\s+"#, options: .regularExpression) {
                line.removeSubrange(r)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { steps.append(line) }
        }
        return steps.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : steps
    }

    static func wantsNextStep(_ text: String) -> Bool { text.uppercased().contains(nextStepMarker) }
    static func wantsReplan(_ text: String)   -> Bool { text.uppercased().contains(replanMarker) }

    /// Убирает служебные маркеры из текста перед показом/сохранением.
    static func stripMarkers(_ text: String) -> String {
        var t = text
        for m in [nextStepMarker, replanMarker] { t = t.replacingOccurrences(of: m, with: "") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Парсит вердикт Проверки. true = выполнено. Смотрит ПОСЛЕДНИЙ «ВЕРДИКТ:»;
    /// при отсутствии/неоднозначности → true (число повторов ограничено лимитом).
    static func parseVerdict(_ text: String) -> Bool {
        let upper = text.uppercased()
        if let r = upper.range(of: "ВЕРДИКТ:", options: .backwards) {
            let tail = upper[r.upperBound...]
            if tail.contains("НЕ ВЫПОЛНЕНО") { return false }
            if tail.contains("ВЫПОЛНЕНО") { return true }
        }
        return true
    }
}

/// Узел дерева сообщений (стратегия .branching). Ветки разделяют общие узлы:
/// общий префикс хранится один раз, ветки расходятся дочерними узлами.
struct MsgNode: Identifiable, Codable {
    var id = UUID()
    var parentID: UUID?
    var role: ChatRole
    var content: String
    var metrics: MessageMetrics?
    /// Этап FSM (если узел — вывод этапа) + прогресс шага (для .execution). nil — обычное.
    var state: TaskState? = nil
    var step: Int? = nil
    var total: Int? = nil
}

/// Именованная ветка = указатель на «кончик» (leaf) ветки в дереве узлов.
struct BranchLeaf: Identifiable, Codable {
    var id = UUID()
    var name: String
    var tipID: UUID?       // последний узел этой ветки
}

/// Отдельный чат со своим контекстом (историей), тайтлом, состоянием и настройками.
/// У каждого чата своя история — удаление чата полностью очищает его контекст.
struct Chat: Identifiable, Codable {
    var id = UUID()
    var title: String
    /// Сообщения хранятся как дерево узлов; активная история — путь от tip к корню.
    var nodes: [MsgNode] = []
    var currentTipID: UUID? = nil
    var isLoading: Bool = false
    var errorText: String? = nil
    var settings = GenerationSettings()

    /// Активная история (вычисляется из дерева): путь от currentTipID к корню.
    var messages: [ChatMessage] {
        get {
            guard !nodes.isEmpty else { return [] }
            let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var result: [ChatMessage] = []
            var cur = currentTipID
            while let id = cur, let n = byID[id] {
                result.append(ChatMessage(id: n.id, role: n.role, content: n.content, metrics: n.metrics, state: n.state, step: n.step, total: n.total))
                cur = n.parentID
            }
            return result.reversed()
        }
        set {
            // Перестроить дерево из линейного массива (используется при создании чата).
            nodes = []
            var parent: UUID? = nil
            for m in newValue {
                let node = MsgNode(id: m.id, parentID: parent, role: m.role, content: m.content, metrics: m.metrics, state: m.state, step: m.step, total: m.total)
                nodes.append(node)
                parent = node.id
            }
            currentTipID = parent
        }
    }

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
    /// Ветвление (.branching): именованные ветки (указатели на узлы дерева) +
    /// активная. Пусто — ветвление ещё не создано (линейная история).
    var branchLeaves: [BranchLeaf] = []
    var activeLeafID: UUID? = nil

    // MARK: Память (см. Memory.swift)
    /// Краткосрочная память этого чата (заметки на текущий диалог).
    /// Долговременная — глобальна (MemoryStore), рабочая — в проекте (Project).
    var memory: [MemoryItem] = []
    /// Ссылка на проект (рабочая память). nil — проект не привязан.
    /// JSON-ключ — старый "taskID" (обратная совместимость chats.json).
    var projectID: UUID? = nil
    /// Активный «Профиль ответа» этого чата (см. Profile.swift). nil — без профиля.
    var profileID: UUID? = nil

    /// Runtime-флаг обновления фактов (не сохраняется).
    var isUpdatingFacts: Bool = false

    /// Runtime: текст баннера о конфликте инвариантов (модель отказала из-за запроса
    /// пользователя). Не сохраняется (см. CodingKeys).
    var invariantConflict: String? = nil

    /// Активный/последний контекст задачи (конечный автомат FSM). nil — нет.
    /// Сохраняется (нужен для возобновления после перезапуска).
    var taskContext: TaskContext? = nil

    /// На диск — данные диалога (дерево узлов); runtime-состояние не сохраняется.
    enum CodingKeys: String, CodingKey {
        case id, title, nodes, currentTipID, settings, promptTokens, completionTokens, totalTokens, totalCost
        case summaryTokens, summaryCost, summary, summarizedUpTo, facts
        case branchLeaves, activeLeafID
        case memory
        case projectID = "taskID"   // старый ключ — читаем прозрачно
        case profileID
        case taskContext
    }
    /// Старый ключ — линейный массив сообщений (миграция в дерево).
    enum LegacyKeys: String, CodingKey { case messages }
}

/// Миграционно-устойчивое декодирование (см. комментарий у GenerationSettings).
extension Chat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Новый чат"
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
        branchLeaves = try c.decodeIfPresent([BranchLeaf].self, forKey: .branchLeaves) ?? []
        activeLeafID = try c.decodeIfPresent(UUID.self, forKey: .activeLeafID)
        memory = try c.decodeIfPresent([MemoryItem].self, forKey: .memory) ?? []
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        taskContext = try c.decodeIfPresent(TaskContext.self, forKey: .taskContext)

        if let nodes = try c.decodeIfPresent([MsgNode].self, forKey: .nodes) {
            self.nodes = nodes
            currentTipID = try c.decodeIfPresent(UUID.self, forKey: .currentTipID) ?? nodes.last?.id
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let old = try? legacy.decodeIfPresent([ChatMessage].self, forKey: .messages) {
            // Миграция старого линейного массива в дерево.
            self.messages = old
        }
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
