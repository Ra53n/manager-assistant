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
    /// Группа волны роя (см. MsgNode.waveGroupID): общие у параллельных шагов одной волны.
    var waveGroupID: UUID? = nil
    var waveSize: Int? = nil
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

    /// Рой агентов (FSM): на этапе «Выполнение» независимые шаги плана выполняются
    /// ПАРАЛЛЕЛЬНО подагентами со своим узким контекстом (экономия токенов/времени).
    /// По умолчанию ВКЛ. Зависимые шаги всё равно идут по порядку (топосортировка волн).
    var swarmEnabled: Bool = true
    /// Максимум одновременно работающих подагентов в одной волне.
    var maxParallelAgents: Int = 3

    static let `default` = GenerationSettings()

    /// Диапазоны/границы для UI.
    static let temperatureRange = 0.0...2.0
    static let topPRange = 0.0...1.0
    static let maxTokensRange = 256...8192
    static let maxStopCount = 16
    static let historyWindowRange = 4...50
    static let memoryTokenBudgetRange = 200...4000
    static let maxParallelAgentsRange = 2...6

    enum CodingKeys: String, CodingKey {
        case provider, model, temperature, topP, maxTokens, stop, responseFormat
        case contextStrategy, historyWindow
        case injectLongTermMemory, injectChatMemory, memoryTokenBudget
        case memoryAssistEnabled, autoMemory, autoProjectSections
        case pipelineMode
        case invariantValidation
        case swarmEnabled, maxParallelAgents
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
        swarmEnabled = try c.decodeIfPresent(Bool.self, forKey: .swarmEnabled) ?? d.swarmEnabled
        maxParallelAgents = try c.decodeIfPresent(Int.self, forKey: .maxParallelAgents) ?? d.maxParallelAgents
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
        .planning:   [.execution],                       // только вперёд
        .execution:  [.validation, .planning],           // вперёд ИЛИ шаг назад (перепланировать)
        .validation: [.answer, .execution, .planning],   // вперёд / переделать выполнение / перепланировать
        .answer:     []                                  // терминал
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
    case awaitingInput // агент задал уточняющий вопрос — ждём ответ пользователя
    case paused        // пользователь поставил паузу / отмена / перезапуск в середине
    case failed        // этап упал с ошибкой (не отмена)
    case finished      // дошли до Готово (терминал)

    /// Снисходительное декодирование: неизвестное → .paused (всегда возобновляемо).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskRunStatus(rawValue: raw) ?? .paused
    }
}

/// Уточняющий вопрос агента с вариантами ответа (как AskUserQuestion в Claude Code).
/// Агент выводит его, когда для корректной работы не хватает данных; пользователь
/// выбирает вариант (или пишет свой), после чего прогон продолжается с той же стадии.
struct PendingQuestion: Codable, Equatable {
    var question: String = ""
    var options: [String] = []

    enum CodingKeys: String, CodingKey { case question, options }

    init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
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
    // --- интерактивность (пауза/уточнения, см. ChatViewModel.interject/answerClarification) ---
    var guidance: [String] = []           // уточнения пользователя, прокидываются в промпт текущей стадии
    var pendingQuestion: PendingQuestion? = nil  // заданный агентом вопрос (status == .awaitingInput)
    // --- рой агентов (параллельное выполнение независимых шагов) ---
    var waves: [[Int]] = []               // волны выполнения: группы индексов шагов, выполнимых параллельно
    var waveIndex: Int = 0                // текущая волна (для возобновления)
    var stepResults: [String] = []        // результаты по индексу шага (для зависимостей подагентов)
    var stepDeps: [[Int]] = []            // зависимости по индексу шага (какие шаги нужны как вход)
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
        case guidance, pendingQuestion
        case waves, waveIndex, stepResults, stepDeps
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
        guidance = try c.decodeIfPresent([String].self, forKey: .guidance) ?? []
        pendingQuestion = try c.decodeIfPresent(PendingQuestion.self, forKey: .pendingQuestion)
        waves = try c.decodeIfPresent([[Int]].self, forKey: .waves) ?? []
        waveIndex = try c.decodeIfPresent(Int.self, forKey: .waveIndex) ?? 0
        stepResults = try c.decodeIfPresent([String].self, forKey: .stepResults) ?? []
        stepDeps = try c.decodeIfPresent([[Int]].self, forKey: .stepDeps) ?? []
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
    static let askUserMarker  = "ASK_USER"    // модель просит уточнение у пользователя

    /// Клауза про уточняющий вопрос (как AskUserQuestion в Claude Code): добавляется в
    /// роль планировщика/исполнителя — спрашивай вместо догадок, если данных не хватает.
    static let askUserClause = """
    Если для корректной работы НЕ ХВАТАЕТ данных и любое продолжение было бы догадкой — \
    НЕ угадывай. Вместо ответа выведи блок РОВНО в таком виде и остановись:
    \(askUserMarker)
    QUESTION: <один короткий вопрос>
    OPTION: <вариант 1>
    OPTION: <вариант 2>
    (2–4 варианта). Выводи этот блок ТОЛЬКО при реальной нехватке данных, не злоупотребляй.
    """

    /// Системный промпт = РОЛЬ этапа. `swarm` — просить у планировщика зависимости шагов.
    static func systemPrompt(for state: TaskState, swarm: Bool = false) -> String {
        switch state {
        case .planning:
            var s = """
            Ты — планировщик. По задаче из [QUERY] составь чёткий пошаговый план: \
            пронумерованные шаги (1., 2., 3., …), каждый шаг — одно конкретное \
            действие по сути задачи, без воды. Не выполняй задачу — только спланируй. \
            НЕ добавляй служебных/протокольных шагов (например «заверши ответ строкой …», \
            «выведи маркер») — только содержательные действия. Верни ТОЛЬКО план.
            """
            if swarm {
                s += "\n\n" + """
                После плана ОБЯЗАТЕЛЬНО добавь раздел зависимостей в формате:
                ЗАВИСИМОСТИ:
                <номер шага>: <номера шагов, от которых он зависит через запятую>
                Указывай ТОЛЬКО реальные зависимости по данным/порядку. Независимые шаги \
                не перечисляй (или пиши «<номер>: -») — они будут выполнены параллельно. \
                Стремись к максимальной параллельности: не вводи лишних зависимостей.
                """
            }
            s += "\n\n" + askUserClause
            return s
        case .execution:
            return """
            Ты — исполнитель. Выполни ТОЛЬКО текущий шаг [CURRENT] (НЕ весь план сразу). \
            Уже сделанное в [DONE] используй как контекст. Дай полный результат этого \
            шага. Когда шаг выполнен — заверши ответ ОТДЕЛЬНОЙ ПОСЛЕДНЕЙ строкой \
            «\(nextStepMarker)». Если по ходу стало ясно, что план непригоден и нужно \
            перепланировать — вместо этого заверши ответ строкой «\(replanMarker)».

            \(askUserClause)
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
        - \(transitionRulesLine(from: ctx.state))
        """
        // Уточнения пользователя (на паузе/в ходе прогона) — учесть в ТЕКУЩЕЙ стадии,
        // НЕ начиная заново. Это самые приоритетные указания.
        if !ctx.guidance.isEmpty {
            s += "\n\n[УКАЗАНИЯ ПОЛЬЗОВАТЕЛЯ — учти их в текущей стадии, приоритетно]\n"
                + ctx.guidance.map { "- \($0)" }.joined(separator: "\n")
        }
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

    static let depsHeader = "ЗАВИСИМОСТИ"

    /// Текст плана → список шагов: снимает нумерацию/маркеры; пустой план → весь текст
    /// одним шагом. Останавливается на разделах ЗАВИСИМОСТИ:/ASK_USER (не считает их шагами).
    static func parsePlanSteps(_ text: String) -> [String] {
        var steps: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            // Разделы зависимостей / уточнения — не часть плана; дальше шагов нет.
            if upper.hasPrefix(depsHeader) || upper.hasPrefix(askUserMarker)
                || upper.hasPrefix("QUESTION:") || upper.hasPrefix("OPTION:") { break }
            if let r = line.range(of: #"^\s*(\d+[.)]|[-–•*])\s+"#, options: .regularExpression) {
                line.removeSubrange(r)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // Шаг-артефакт: планировщик включил протокольный маркер как «шаг» (например
            // «заверши ответ строкой NEXT_STEP») — после очистки он невыполним и зациклит
            // проверку. Отбрасываем такие строки.
            let u2 = line.uppercased()
            if u2.contains(nextStepMarker) || u2.contains(replanMarker) || u2.contains(askUserMarker) { continue }
            if !line.isEmpty { steps.append(line) }
        }
        return steps.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : steps
    }

    static func wantsNextStep(_ text: String) -> Bool { text.uppercased().contains(nextStepMarker) }
    static func wantsReplan(_ text: String)   -> Bool { text.uppercased().contains(replanMarker) }

    /// Убирает служебные маркеры/разделы из текста перед показом/сохранением.
    static func stripMarkers(_ text: String) -> String {
        var kept: [String] = []
        var inDeps = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
            if upper.hasPrefix(depsHeader) { inDeps = true; continue }      // раздел зависимостей — убрать
            if inDeps {                                                      // строки вида «3: 1,2» внутри раздела
                if line.range(of: #"^\s*\d+\s*:"#, options: .regularExpression) != nil { continue }
                inDeps = false
            }
            if upper == askUserMarker || upper.hasPrefix("QUESTION:") || upper.hasPrefix("OPTION:") { continue }
            kept.append(line)
        }
        var t = kept.joined(separator: "\n")
        for m in [nextStepMarker, replanMarker, askUserMarker] { t = t.replacingOccurrences(of: m, with: "") }
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

    // MARK: - Уточняющий вопрос (ASK_USER)

    /// Парсит блок ASK_USER → PendingQuestion. Возвращает nil, если нет всех частей
    /// (маркер ASK_USER + строка QUESTION: + хотя бы один OPTION:).
    static func parseQuestion(_ text: String) -> PendingQuestion? {
        guard text.uppercased().contains(askUserMarker) else { return nil }
        var question = ""
        var options: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("QUESTION:") {
                question = String(line.dropFirst("QUESTION:".count)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("OPTION:") {
                let opt = String(line.dropFirst("OPTION:".count)).trimmingCharacters(in: .whitespaces)
                if !opt.isEmpty { options.append(opt) }
            }
        }
        // Дедуп вариантов, ограничение до 4.
        var seen = Set<String>()
        options = options.filter { seen.insert($0.lowercased()).inserted }
        if options.count > 4 { options = Array(options.prefix(4)) }
        guard !question.isEmpty, !options.isEmpty else { return nil }
        return PendingQuestion(question: question, options: options)
    }

    // MARK: - Рой агентов: зависимости шагов → волны (топосортировка)

    /// Парсит раздел «ЗАВИСИМОСТИ:» (строки «3: 1,2», номера 1-based) → для каждого шага
    /// (0-based) множество индексов-предшественников. Вне диапазона/self/дубли отбрасываются.
    static func parseDeps(_ text: String, stepCount n: Int) -> [Set<Int>] {
        var deps = Array(repeating: Set<Int>(), count: max(0, n))
        guard n > 0 else { return [] }
        var inSection = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix(depsHeader) { inSection = true; continue }
            guard inSection, !line.isEmpty else { continue }
            // «<номер>: <номера через запятую/пробел>»
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let stepNum = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let target = stepNum - 1
            guard target >= 0, target < n else { continue }
            let refs = parts[1].split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            for r in refs {
                guard let num = Int(r.trimmingCharacters(in: .whitespaces)) else { continue }
                let dep = num - 1
                if dep >= 0, dep < n, dep != target { deps[target].insert(dep) }
            }
        }
        return deps
    }

    /// Волны выполнения (алгоритм Кана): группы индексов шагов, выполнимых параллельно.
    /// Цикл/тупик или пустой ввод → последовательный фолбэк (каждый шаг — своя волна).
    static func computeWaves(n: Int, deps: [Set<Int>]) -> [[Int]] {
        guard n > 0 else { return [] }
        // Защита от рассинхрона размеров.
        let d: [Set<Int>] = (0..<n).map { i in i < deps.count ? deps[i].filter { $0 >= 0 && $0 < n && $0 != i } : [] }
        var placed = Array(repeating: false, count: n)
        var waves: [[Int]] = []
        var remaining = n
        while remaining > 0 {
            var wave: [Int] = []
            for i in 0..<n where !placed[i] {
                if d[i].allSatisfy({ placed[$0] }) { wave.append(i) }
            }
            if wave.isEmpty { return (0..<n).map { [$0] } }   // цикл/тупик → последовательно
            for i in wave { placed[i] = true }
            remaining -= wave.count
            waves.append(wave.sorted())
        }
        return waves
    }

    /// Системный промпт подагента роя (исполнитель ОДНОГО шага с узким контекстом).
    static func subAgentSystemPrompt() -> String {
        """
        Ты — подагент-исполнитель в рое. Выполни ТОЛЬКО порученный шаг [STEP] полностью и \
        самодостаточно. Используй [DEPS] (результаты шагов, от которых зависит твой) как \
        вход; [PLAN] — общий контекст. НЕ выполняй другие шаги и НЕ задавай вопросов — \
        дай готовый результат своего шага. Если шаг невозможен без переплана — заверши \
        ответ строкой «\(replanMarker)».
        """
    }

    /// User-сообщение подагенту: узкий контекст (обзор плана + ТОЛЬКО выводы зависимостей
    /// + текущий шаг). Полный [DONE] НЕ передаём — экономия токенов/контекста.
    static func subAgentPrompt(task: String, stepIndex: Int, plan: [String],
                               deps: Set<Int>, stepResults: [String],
                               profile: String, invariants: [Invariant] = [],
                               guidance: [String] = []) -> String {
        func numberedPlan() -> String {
            plan.isEmpty ? "—" : plan.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n           ")
        }
        let depList = deps.sorted()
        let depsText: String
        if depList.isEmpty {
            depsText = "—"
        } else {
            depsText = depList.map { idx -> String in
                let res = (idx < stepResults.count ? stepResults[idx] : "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = idx < plan.count ? plan[idx] : "шаг \(idx + 1)"
                return "• Шаг \(idx + 1) (\(title)):\n\(res.isEmpty ? "—" : res)"
            }.joined(separator: "\n")
        }
        let step = stepIndex < plan.count ? plan[stepIndex] : ""
        let prof = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = """
        [QUERY]    \(task)
        [PLAN]     \(numberedPlan())
        [STEP]     \(stepIndex + 1). \(step)
        [DEPS]
        \(depsText)
        [PROFILE]  \(prof.isEmpty ? "—" : prof)

        Дай полный результат шага [STEP].
        """
        if !guidance.isEmpty {
            s += "\n\n[УКАЗАНИЯ ПОЛЬЗОВАТЕЛЯ — учти их, приоритетно]\n"
                + guidance.map { "- \($0)" }.joined(separator: "\n")
        }
        let invBlock = InvariantValidator.promptBlock(invariants)
        if !invBlock.isEmpty { s += "\n\n\(invBlock)" }
        return s
    }

    // MARK: - Запрос смены стадии текстом

    /// Распознаёт в тексте пользователя ПРОСЬБУ СМЕНИТЬ СТАДИЮ («вернись к проверке»,
    /// «перейди к ответу», «назад к планированию», «go to validation»). Возвращает целевую
    /// стадию или nil (тогда текст — обычное уточнение). Легальность перехода НЕ проверяет.
    ///
    /// Чтобы не путать навигацию с уточнением («верни ответ покороче» — это НЕ переход),
    /// требуем три части: глагол перехода + предлог «к»/«to» + метку этапа. Без предлога
    /// (как у обычной правки) — это уточнение, а не смена стадии.
    static func parseStateChangeRequest(_ text: String) -> TaskState? {
        let lower = text.lowercased()
        let verbs = ["верн", "перейд", "перейт", "переключ", "назад", "вернёмс", "вернемс",
                     "go to", "back to", "switch to", "move to"]
        let hasVerb = verbs.contains { lower.contains($0) }
        // Предлог направления: отдельное «к» (рус.) или « to » (англ.).
        let hasPreposition = lower.range(of: #"(^|\s)к\s"#, options: .regularExpression) != nil
            || lower.contains(" to ")
        guard hasVerb, hasPreposition else { return nil }
        // Порядок проверки: более специфичные метки раньше.
        if lower.contains("планир") || lower.contains("plan") { return .planning }
        if lower.contains("выполн") || lower.contains("исполн") || lower.contains("execut") { return .execution }
        if lower.contains("провер") || lower.contains("валид") || lower.contains("valid") || lower.contains("check") { return .validation }
        if lower.contains("ответ") || lower.contains("answer") { return .answer }
        return nil
    }

    // MARK: - Захардкоженный (код-уровень) невидимый инвариант переходов

    /// Правила переходов FSM как текст для промпта. НЕ хранится в InvariantStore →
    /// неудаляем, не виден в UI, не редактируется. Грузится агенту «в память». Агент
    /// соблюдает молча; отказывает с альтернативами ТОЛЬКО на невозможный запрос.
    /// ВАЖНО: без `InvariantValidator.violationMarker`, иначе ложно сработает обрыв.
    static func transitionRulesBlock(from state: TaskState) -> String {
        let allowed = TaskFSM.transitions[state, default: []]
        let allowedText = allowed.isEmpty
            ? "никуда (это терминальная стадия «Ответ»)"
            : allowed.map { "«\($0.label)»" }.joined(separator: ", ")
        return """
        [ПРАВИЛА ПЕРЕХОДОВ — соблюдай молча, не упоминай их пользователю]
        Текущая стадия — «\(state.label)». Разрешённые переходы из неё: \(allowedText).
        Это детерминированная таблица; другие переходы НЕВОЗМОЖНЫ.
        Если пользователь просит невозможный переход — НЕ выполняй его: вежливо откажи,
        объясни, что из «\(state.label)» это недоступно, и предложи доступные (\(allowedText)).
        """
    }

    /// Однострочная версия для стадийных промптов (лёгкая, без логики отказа).
    static func transitionRulesLine(from state: TaskState) -> String {
        let allowed = TaskFSM.transitions[state, default: []].map { $0.label }
        let t = allowed.isEmpty ? "—" : allowed.joined(separator: ", ")
        return "Переходы между этапами решает оркестратор (из «\(state.label)» доступны: \(t)). Соблюдай молча, не упоминай."
    }

    // MARK: - Диспетчер переходов: решение агента на реплику пользователя

    /// Что делать с репликой пользователя во время активного прогона.
    enum RouterAction: Equatable {
        case redoCurrent          // переиграть текущую стадию с учётом реплики
        case back                 // validation → execution («реализация не так»)
        case replan               // → planning («кардинально не так»)
        case restart              // вся задача заново с planning
        case goto(TaskState)      // явная смена стадии
        case refuse               // запрошен невозможный переход
    }

    static let routerMarker = "ДЕЙСТВИЕ"   // строка решения: «ДЕЙСТВИЕ: GOTO:validation»

    /// Парсер строки-решения роутера. Толерантен к регистру/пробелам. nil — не найдено.
    static func parseRouterDecision(_ text: String) -> RouterAction? {
        let upper = text.uppercased()
        guard let r = upper.range(of: routerMarker) else { return nil }
        let tail = upper[r.upperBound...]
        let firstLine = tail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let tok = firstLine.drop(while: { $0 == ":" || $0 == " " })
        if tok.hasPrefix("REDO") { return .redoCurrent }
        if tok.hasPrefix("BACK") { return .back }
        if tok.hasPrefix("REPLAN") { return .replan }
        if tok.hasPrefix("RESTART") { return .restart }
        if tok.hasPrefix("REFUSE") { return .refuse }
        if tok.hasPrefix("GOTO") {
            let p = tok.replacingOccurrences(of: "GOTO", with: "")
            if p.contains("PLAN") || p.contains("ПЛАН") { return .goto(.planning) }
            if p.contains("EXEC") || p.contains("ВЫПОЛН") || p.contains("ИСПОЛН") { return .goto(.execution) }
            if p.contains("VALID") || p.contains("CHECK") || p.contains("ПРОВЕР") || p.contains("ВАЛИД") { return .goto(.validation) }
            if p.contains("ANSW") || p.contains("ОТВЕТ") { return .goto(.answer) }
        }
        return nil
    }

    /// Целевая стадия действия (для проверки по таблице). redo/refuse → nil (не переход).
    static func routerTarget(_ action: RouterAction, from state: TaskState) -> TaskState? {
        switch action {
        case .redoCurrent, .refuse: return nil
        case .back:                 return .execution
        case .replan, .restart:     return .planning
        case .goto(let s):          return s
        }
    }

    /// Текст-объяснение агента до строки ДЕЙСТВИЕ (показываем пользователю при отказе).
    static func stripRouterMarker(_ text: String) -> String {
        if let r = text.range(of: routerMarker) {
            return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Системный промпт диспетчера: правила переходов + грамматика ответа.
    static func routerSystemPrompt(state: TaskState) -> String {
        """
        Ты — диспетчер конечного автомата задачи. Пользователь прислал реплику во время
        активного прогона. Реши ОДНО действие и выведи его ПОСЛЕДНЕЙ строкой строго так:
        \(routerMarker): <одно из: REDO_CURRENT | BACK | REPLAN | RESTART | GOTO:<стадия> | REFUSE>

        Значения:
        - REDO_CURRENT — обычная правка/замечание/уточнение: переиграть ТЕКУЩУЮ стадию с учётом реплики.
        - BACK — «реализация не так»: вернуться к выполнению (имеет смысл со стадии «Проверка»).
        - REPLAN — «кардинально не так» / переделать задачу: вернуться к планированию.
        - RESTART — начать всю задачу заново с планирования.
        - GOTO:<стадия> — пользователь хочет КОНКРЕТНУЮ стадию (planning|execution|validation|answer).
        - REFUSE — реплика не про переход и не про правку (используй редко).

        ЖЁСТКОЕ ПРАВИЛО: если пользователь называет конкретную целевую стадию (например
        «давай к ответу», «сразу к ответу», «перейди к проверке», «вернись к планированию»),
        выведи РОВНО эту стадию в GOTO:<стадия> — ДАЖЕ ЕСЛИ переход в неё сейчас НЕВОЗМОЖЕН.
        НИКОГДА не подменяй запрошенную стадию другой («ближайшей доступной»). Код сам сверит
        с таблицей и, если перейти нельзя, КОРРЕКТНО откажет пользователю и предложит доступные.
        Пример: со стадии «Выполнение» реплика «давай сразу к ответу» → ДЕЙСТВИЕ: GOTO:answer
        (код объяснит, что напрямую в «Ответ» из «Выполнения» нельзя, и предложит «Проверка»/«Планирование»).

        \(transitionRulesBlock(from: state))
        Перед строкой ДЕЙСТВИЕ дай 1–2 предложения дружелюбного объяснения для пользователя
        (если переход невозможен — честно скажи это и назови доступные стадии).
        """
    }

    /// User-сообщение диспетчеру.
    static func routerUserPrompt(task: String, state: TaskState, userText: String) -> String {
        """
        [ЗАДАЧА] \(task)
        [ТЕКУЩАЯ СТАДИЯ] \(state.label)
        [РЕПЛИКА ПОЛЬЗОВАТЕЛЯ] \(userText)
        Выбери ровно одно действие.
        """
    }
}

extension Array {
    /// Разбивает массив на чанки заданного размера (для ограничения параллельности роя).
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
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
    /// Группа волны роя: сообщения одной параллельной волны имеют общий waveGroupID и
    /// рендерятся плитками. nil/waveSize<=1 — обычное (последовательное) сообщение.
    /// ТОЛЬКО Optional — у MsgNode синтезированный Codable (старый JSON без ключей → nil).
    var waveGroupID: UUID? = nil
    var waveSize: Int? = nil
}

/// Живая плитка подагента роя (runtime, НЕ сохраняется). Обновляется по мере работы
/// подагентов текущей волны; рендерится рядом плиток (UI как в Claude Code).
struct LiveSubAgent: Identifiable, Equatable {
    let id: Int            // индекс шага (стабилен внутри волны)
    var title: String      // текст шага плана
    var status: Status = .running
    var output: String = ""
    var tokens: Int = 0

    enum Status: Equatable { case running, done, failed }
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
                result.append(ChatMessage(id: n.id, role: n.role, content: n.content, metrics: n.metrics, state: n.state, step: n.step, total: n.total, waveGroupID: n.waveGroupID, waveSize: n.waveSize))
                cur = n.parentID
            }
            return result.reversed()
        }
        set {
            // Перестроить дерево из линейного массива (используется при создании чата).
            nodes = []
            var parent: UUID? = nil
            for m in newValue {
                let node = MsgNode(id: m.id, parentID: parent, role: m.role, content: m.content, metrics: m.metrics, state: m.state, step: m.step, total: m.total, waveGroupID: m.waveGroupID, waveSize: m.waveSize)
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

    /// Runtime: текст баннера об отказе в смене стадии (запрошенный переход запрещён
    /// таблицей TaskFSM). Не сохраняется (см. CodingKeys).
    var stateChangeError: String? = nil

    /// Runtime: живые плитки подагентов текущей волны роя (статус/вывод по мере готовности).
    /// НЕ сохраняется (транзиентно; на коммите/паузе чистится, при resume пересобирается).
    var liveSubAgents: [LiveSubAgent] = []

    /// Runtime: идёт решение диспетчера переходов по реплике пользователя («Агент решает…»).
    /// НЕ сохраняется (см. CodingKeys).
    var isDeciding: Bool = false

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
