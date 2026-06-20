// ChatViewModel.swift — единственный источник состояния приложения (MVVM).
//
// Владеет списком чатов, выбранным чатом, полем ввода и объединённым списком
// моделей всех провайдеров. ContentView только читает это состояние и зовёт
// методы; сам ничего не хранит.
//
// Ключевые потоки:
//  - send(): добавляет сообщение пользователя → авто-тайтл из первого
//    сообщения → уходит в DeepSeekClient со снапшотом истории. Ответ
//    привязывается к chatID (не к индексу!) — поэтому можно переключить чат,
//    пока идёт запрос, и ответ попадёт куда нужно. Здесь же считаются
//    MessageMetrics (время, токены, стоимость по таблице pricing).
//  - loadModels(): опрашивает /models всех провайдеров с ключом, строит
//    общий список и карту цен «provider|model» → ModelPricing.
//  - Персистентность: история грузится из ChatStore в init; автосохранение —
//    подписка на $chats с дебаунсом 300 мс (слайдеры настроек генерируют
//    шквал изменений) + запись без дебаунса на willTerminate.
//
// Всё на @MainActor — мутации chats только из главного потока.

import Foundation
import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var selectedChatID: UUID?
    @Published var input: String = ""

    // MARK: Память (см. Memory.swift)
    /// Долговременная (глобальная) память — общий профиль и знания (memory.json).
    @Published var memory: [MemoryItem] = []
    /// Проекты — контейнеры рабочей памяти (projects.json): бриф + полные секции.
    @Published var projects: [Project] = []
    /// Кандидаты от ассистента памяти, ждущие подтверждения (режим «предлагать»).
    @Published var memorySuggestions: [MemoryItem] = []
    /// Результат «Собрать» (итог из секций проекта) для показа в листе; nil — нет.
    @Published var assemblyResult: String? = nil
    @Published var isAssembling = false
    /// Профили ответа — пресеты стиля/формата/ограничений (profiles.json).
    @Published var profiles: [ResponseProfile] = []

    /// Объединённый список моделей всех провайдеров с ключами (из их /models).
    @Published var availableModels: [ModelOption] = [
        ModelOption(provider: .deepseek, model: Config.model)
    ]
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    private var hasLoadedModels = false

    /// Цены по моделям, ключ — "<provider>|<model>". Сидим прайсом DeepSeek сразу.
    private var pricing: [String: ModelPricing] = ChatViewModel.seedPricing()

    /// Окна контекста моделей (OpenRouter — из /models, DeepSeek — из таблицы).
    /// @Published, чтобы предупреждение об усечении появлялось после загрузки.
    @Published private(set) var contextLimits: [String: Int] = ChatViewModel.seedContextLimits()

    /// Цена выбранной модели (для режима сравнения и др.).
    func price(for option: ModelOption) -> ModelPricing? {
        pricing[option.id]
    }

    private static func seedPricing() -> [String: ModelPricing] {
        var prices: [String: ModelPricing] = [:]
        for (model, price) in DeepSeekPricing.table {
            prices["\(Provider.deepseek.rawValue)|\(model)"] = price
        }
        return prices
    }

    private static func seedContextLimits() -> [String: Int] {
        var limits: [String: Int] = [:]
        for (model, limit) in DeepSeekPricing.contextLimits {
            limits["\(Provider.deepseek.rawValue)|\(model)"] = limit
        }
        return limits
    }

    private let client = DeepSeekClient()
    /// Хэндлы активных прогонов FSM (для паузы/отмены), ключ — chatID.
    private var pipelineTasks: [UUID: Task<Void, Never>] = [:]
    private var saveCancellable: AnyCancellable?
    private var memorySaveCancellable: AnyCancellable?
    private var projectsSaveCancellable: AnyCancellable?
    private var profilesSaveCancellable: AnyCancellable?

    static let defaultTitle = "Новый чат"

    init() {
        // История с диска; при первом запуске — один пустой чат.
        let loaded = ChatStore.load()
        if loaded.isEmpty {
            let first = Chat(title: Self.defaultTitle)
            chats = [first]
            selectedChatID = first.id
        } else {
            chats = loaded
            selectedChatID = loaded.first?.id
        }

        // «Висящие» прогоны FSM (running) после перезапуска переводим в paused —
        // живых Task нет, прогон должен остаться возобновляемым (не «висеть»).
        normalizeTaskRuns()

        // Память: долговременная (глобальная) и проекты — из своих файлов.
        memory = MemoryStore.load()
        projects = ProjectStore.load()
        // Профили ответа (при первом запуске — стартовый набор).
        profiles = ProfileStore.load()

        // Автосохранение при любом изменении чатов. Дебаунс гасит шквал
        // обновлений (например, перетаскивание слайдеров в настройках).
        saveCancellable = $chats
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { chats in
                DispatchQueue.global(qos: .utility).async { ChatStore.save(chats) }
            }
        // Те же дебаунс-сохранения для памяти и задач (отдельные файлы).
        memorySaveCancellable = $memory
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { items in
                DispatchQueue.global(qos: .utility).async { MemoryStore.save(items) }
            }
        projectsSaveCancellable = $projects
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { projects in
                DispatchQueue.global(qos: .utility).async { ProjectStore.save(projects) }
            }
        profilesSaveCancellable = $profiles
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { profiles in
                DispatchQueue.global(qos: .utility).async { ProfileStore.save(profiles) }
            }

        // Лимиты контекста и цены нужны сразу (для предупреждения об усечении),
        // а не только при первом открытии настроек.
        loadModels()

        // Страховка на выход из приложения — пишем без дебаунса.
        // willTerminate приходит на главном потоке, поэтому assumeIsolated корректен.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ChatStore.save(self.chats)
                MemoryStore.save(self.memory)
                ProjectStore.save(self.projects)
                ProfileStore.save(self.profiles)
            }
        }
    }

    // MARK: - Доступ к выбранному чату

    var selectedIndex: Int? {
        guard let id = selectedChatID else { return nil }
        return chats.firstIndex { $0.id == id }
    }

    var selectedChat: Chat? {
        selectedIndex.map { chats[$0] }
    }

    /// Можно ли отправлять: есть выбранный чат, непустой текст, он не грузится и по
    /// нему нет НЕзавершённого прогона FSM (активным прогоном управляют кнопки полосы).
    var canSend: Bool {
        guard let idx = selectedIndex else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let run = chats[idx].taskRun, run.status != .finished { return false }
        return !text.isEmpty && !chats[idx].isLoading
    }

    // MARK: - Управление чатами

    func newChat() {
        let chat = Chat(title: Self.defaultTitle)
        chats.insert(chat, at: 0) // новые сверху
        selectedChatID = chat.id
        input = ""
    }

    /// Новый диалог ВНУТРИ проекта (вкладка «Проекты», cowork). Для проектных
    /// чатов сразу включаем дефолты, чтобы агент сам вёл проект.
    @discardableResult
    func newChat(inProject projectID: UUID) -> UUID {
        var chat = Chat(title: Self.defaultTitle)
        chat.projectID = projectID
        chat.settings.injectChatMemory = true
        chat.settings.autoProjectSections = true
        chats.insert(chat, at: 0)
        selectedChatID = chat.id
        input = ""
        return chat.id
    }

    /// Диалоги проекта (новые сверху — как в общем списке).
    func chats(in projectID: UUID) -> [Chat] {
        chats.filter { $0.projectID == projectID }
    }

    /// Обычные чаты (вкладка «Чаты») — не привязанные к проекту.
    var looseChats: [Chat] {
        chats.filter { $0.projectID == nil }
    }

    // MARK: - Профили ответа (см. Profile.swift)

    /// Активный профиль чата (или nil).
    func profile(for chat: Chat) -> ResponseProfile? {
        guard let pid = chat.profileID else { return nil }
        return profiles.first(where: { $0.id == pid })
    }

    @discardableResult
    func newProfile() -> UUID {
        let p = ResponseProfile()
        profiles.insert(p, at: 0)
        return p.id
    }

    func updateProfile(_ p: ResponseProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
    }

    /// Удалить профиль и снять его со всех чатов.
    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        for ci in chats.indices where chats[ci].profileID == id { chats[ci].profileID = nil }
    }

    func setChatProfile(chatID: UUID, profileID: UUID?) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[ci].profileID = profileID
    }

    /// Обновляет параметры генерации выбранного чата.
    func updateSelectedSettings(_ newValue: GenerationSettings) {
        guard let idx = selectedIndex else { return }
        chats[idx].settings = newValue
    }

    /// Загружает модели из всех провайдеров, у кого задан ключ.
    /// По умолчанию — один раз; force — принудительно (после смены ключей).
    func loadModels(force: Bool = false) {
        if isLoadingModels { return }
        if hasLoadedModels && !force { return }
        isLoadingModels = true
        modelsError = nil
        Task {
            var combined: [ModelOption] = []
            var prices: [String: ModelPricing] = [:]
            var limits: [String: Int] = Self.seedContextLimits()
            var failed: [String] = []
            for provider in Provider.allCases where KeyStore.hasKey(for: provider) {
                do {
                    let infos = try await client.fetchModels(provider: provider)
                    for info in infos {
                        let option = ModelOption(provider: provider, model: info.id)
                        combined.append(option)
                        if let pp = info.promptPrice, let cp = info.completionPrice {
                            prices[option.id] = ModelPricing(promptPerToken: pp, completionPerToken: cp)
                        }
                        if let ctx = info.contextLength {
                            limits[option.id] = ctx
                        }
                    }
                } catch {
                    failed.append(provider.displayName)
                }
            }
            // Цены DeepSeek (их API цены не отдаёт) — из таблицы.
            for (model, price) in DeepSeekPricing.table {
                prices["\(Provider.deepseek.rawValue)|\(model)"] = price
            }
            if !combined.isEmpty { availableModels = combined }
            pricing = prices
            contextLimits = limits
            modelsError = failed.isEmpty ? nil : "Не удалось загрузить: \(failed.joined(separator: ", "))"
            hasLoadedModels = true
            isLoadingModels = false
        }
    }

    /// Удаляет чат и тем самым полностью очищает его контекст.
    func deleteChat(_ id: UUID) {
        chats.removeAll { $0.id == id }
        if selectedChatID == id {
            selectedChatID = chats.first?.id
        }
    }

    /// Удаление через свайп/Edit в списке.
    func deleteChats(at offsets: IndexSet) {
        let ids = offsets.map { chats[$0].id }
        chats.removeAll { ids.contains($0.id) }
        if let sel = selectedChatID, !chats.contains(where: { $0.id == sel }) {
            selectedChatID = chats.first?.id
        }
    }

    // MARK: - Отправка сообщения

    func send() {
        guard let idx = selectedIndex else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chats[idx].isLoading else { return }
        // Незавершённый прогон FSM — Enter не стартует новый (управление — на полосе).
        if let run = chats[idx].taskRun, run.status != .finished { return }

        let chatID = chats[idx].id

        // Тайтл чата — из первого сообщения пользователя.
        if !chats[idx].messages.contains(where: { $0.role == .user }) {
            chats[idx].title = Self.makeTitle(from: text)
        }

        addMessage(idx, role: .user, content: text)
        chats[idx].errorText = nil

        // Режим конечного автомата задачи (FSM): дальше ведёт оркестратор на уровне
        // кода (см. startPipeline), а не один запрос модели. Enter запускает автомат.
        if chats[idx].settings.pipelineMode != .off {
            chats[idx].taskRun = TaskRun(task: text,
                                         mode: chats[idx].settings.pipelineMode,
                                         phase: .planning,
                                         status: .running)
            input = ""
            startPipeline(chatID: chatID)
            return
        }

        chats[idx].isLoading = true
        input = ""

        // Что уходит модели — определяет выбранная стратегия контекста.
        let settings = chats[idx].settings
        let payload = ContextManager.payload(messages: chats[idx].messages, settings: settings, facts: chats[idx].facts)
        // Блок памяти (долговременная + проект + краткосрочная) — ортогонален стратегии.
        let memoryText = memoryText(for: chats[idx])
        let inProject = chats[idx].projectID != nil
        // Директивы активного «Профиля ответа» (стиль/формат/ограничения).
        let profileText = profile(for: chats[idx])?.systemDirective
        let price = pricing["\(settings.provider.rawValue)|\(settings.model)"]

        Task {
            let start = Date()
            do {
                let result = try await client.send(
                    messages: payload.tail,
                    settings: settings,
                    facts: payload.facts,
                    memory: memoryText,
                    inProject: inProject,
                    profile: profileText
                )
                let duration = Date().timeIntervalSince(start)
                let metrics = MessageMetrics(
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    totalTokens: result.totalTokens,
                    duration: duration,
                    promptCost: price.map { Double(result.promptTokens) * $0.promptPerToken },
                    completionCost: price.map { Double(result.completionTokens) * $0.completionPerToken }
                )
                if let i = chats.firstIndex(where: { $0.id == chatID }) {
                    addMessage(i, role: .assistant, content: result.text, metrics: metrics)
                    chats[i].promptTokens += result.promptTokens
                    chats[i].completionTokens += result.completionTokens
                    chats[i].totalTokens += result.totalTokens
                    chats[i].totalCost += metrics.totalCost ?? 0
                    chats[i].isLoading = false
                    maybeUpdateFacts(chatID: chatID)
                    maybeMaintainMemory(chatID: chatID)
                    maybeAppendProjectSection(chatID: chatID, answer: result.text)
                }
            } catch {
                if let i = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[i].errorText = error.localizedDescription
                    chats[i].isLoading = false
                }
            }
        }
    }

    // MARK: - Конечный автомат задачи (FSM): planning → execution → validation → answer

    /// Поколение прогона на чат: каждый startPipeline инкрементит. Старый (отменённый)
    /// Task, доигрывая отмену, проверяет совпадение поколения и НЕ трогает состояние,
    /// если его уже сменил новый прогон (защита от гонки пауза→быстрое продолжение).
    private var pipelineGen: [UUID: Int] = [:]

    /// Запускает (или возобновляет) цикл этапов для чата. Переходы решает КОД.
    func startPipeline(chatID: UUID) {
        let gen = (pipelineGen[chatID] ?? 0) + 1
        pipelineGen[chatID] = gen
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = Task { await self.runPhaseLoop(chatID: chatID, gen: gen) }
    }

    /// Цикл этапов: на каждом — отдельный запрос модели, затем переход решает код.
    private func runPhaseLoop(chatID: UUID, gen: Int) async {
        while true {
            guard let i = chats.firstIndex(where: { $0.id == chatID }),
                  let run = chats[i].taskRun, run.status == .running else { break }

            let phase = run.phase
            let settings = chats[i].settings
            let sys = PipelinePrompts.systemPrompt(for: phase)
            let user = PipelinePrompts.userMessage(for: phase, run: run)
            let price = pricing["\(settings.provider.rawValue)|\(settings.model)"]
            chats[i].isLoading = true

            let start = Date()
            do {
                let result = try await client.runPhase(systemPrompt: sys, userMessage: user, settings: settings)
                // Прогон сменили (новый startPipeline) — этот молча выходит, состояние чужое.
                guard pipelineGen[chatID] == gen else { return }
                // Отмена «на проводе» (пауза во время запроса) → тот же этап, не коммитим.
                if Task.isCancelled { pauseAt(chatID, phase: phase, gen: gen); return }
                guard let j = chats.firstIndex(where: { $0.id == chatID }) else {
                    clearTask(chatID, gen: gen); return
                }

                // 1) Структурная копия вывода этапа (для прокидывания вперёд).
                switch phase {
                case .planning:   chats[j].taskRun?.plan = result.text
                case .execution:  chats[j].taskRun?.executionResult = result.text
                case .validation:
                    chats[j].taskRun?.validationResult = result.text
                    chats[j].taskRun?.validationPassed = PipelinePrompts.parseVerdict(result.text)
                case .answer:     chats[j].taskRun?.answer = result.text
                }

                // 2) В ленту — узлом дерева (через addMessage), с меткой этапа.
                let metrics = MessageMetrics(
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    totalTokens: result.totalTokens,
                    duration: Date().timeIntervalSince(start),
                    promptCost: price.map { Double(result.promptTokens) * $0.promptPerToken },
                    completionCost: price.map { Double(result.completionTokens) * $0.completionPerToken }
                )
                addMessage(j, role: .assistant, content: result.text, metrics: metrics, phase: phase)
                chats[j].promptTokens += result.promptTokens
                chats[j].completionTokens += result.completionTokens
                chats[j].totalTokens += result.totalTokens
                chats[j].totalCost += metrics.totalCost ?? 0

                // 3) ПЕРЕХОД РЕШАЕТ КОД.
                switch phase {
                case .planning:
                    if chats[j].taskRun?.mode == .plan {
                        chats[j].taskRun?.status = .awaitingPlan   // СТОП: ждём «Принять план»
                        chats[j].isLoading = false
                        clearTask(chatID, gen: gen)
                        return
                    }
                    chats[j].taskRun?.phase = .execution           // auto: дальше
                case .execution:
                    chats[j].taskRun?.phase = .validation
                case .validation:
                    let passed = chats[j].taskRun?.validationPassed ?? true
                    let retries = chats[j].taskRun?.executionRetries ?? 0
                    if !passed && retries < TaskRun.maxExecutionRetries {
                        chats[j].taskRun?.executionRetries = retries + 1
                        chats[j].taskRun?.phase = .execution       // ВОЗВРАТ к Выполнению
                    } else {
                        chats[j].taskRun?.phase = .answer          // дальше — финальный ОТВЕТ
                    }
                case .answer:
                    chats[j].taskRun?.status = .finished           // терминал
                    chats[j].isLoading = false
                    clearTask(chatID, gen: gen)
                    return
                }
            } catch {
                // Отмена приходит как CancellationError ИЛИ URLError.cancelled (так
                // URLSession сообщает об отменённом запросе) ИЛИ через флаг Task —
                // это ПАУЗА на том же этапе, а не ошибка.
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                    || Task.isCancelled {
                    pauseAt(chatID, phase: phase, gen: gen)
                    return
                }
                guard pipelineGen[chatID] == gen else { return }
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].taskRun?.status = .failed
                    chats[j].taskRun?.errorText = error.localizedDescription
                    chats[j].errorText = error.localizedDescription
                    chats[j].isLoading = false
                }
                clearTask(chatID, gen: gen)
                return
            }
        }
        clearTask(chatID, gen: gen)
        if let i = chats.firstIndex(where: { $0.id == chatID }), pipelineGen[chatID] == gen {
            chats[i].isLoading = false
        }
    }

    /// Снять хэндл Task, только если поколение ещё актуально (иначе чужой прогон).
    private func clearTask(_ chatID: UUID, gen: Int) {
        if pipelineGen[chatID] == gen { pipelineTasks[chatID] = nil }
    }

    /// Пауза прогона: отменяем активный запрос. Статус зафиксирует pauseAt на том же этапе.
    func pausePipeline(chatID: UUID) {
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil
        // Если Task был между этапами (не в await) — фиксируем паузу вручную.
        if let i = chats.firstIndex(where: { $0.id == chatID }),
           chats[i].taskRun?.status == .running {
            chats[i].taskRun?.status = .paused
            chats[i].isLoading = false
        }
    }

    /// Зафиксировать паузу на конкретном этапе (после отмены запроса). Не трогает
    /// состояние, если прогон уже сменили (gen устарел).
    private func pauseAt(_ chatID: UUID, phase: TaskPhase, gen: Int) {
        guard pipelineGen[chatID] == gen else { return }
        pipelineTasks[chatID] = nil
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        if chats[i].taskRun?.status == .running { chats[i].taskRun?.status = .paused }
        chats[i].taskRun?.phase = phase
        chats[i].isLoading = false
    }

    /// Возобновить прогон с текущего этапа (из paused/failed).
    func resumePipeline(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let status = chats[i].taskRun?.status,
              status == .paused || status == .failed else { return }
        chats[i].taskRun?.status = .running
        chats[i].taskRun?.errorText = nil
        chats[i].errorText = nil
        startPipeline(chatID: chatID)
    }

    /// Режим .plan: «Принять план» — перейти к выполнению.
    func approvePlan(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              chats[i].taskRun?.status == .awaitingPlan else { return }
        chats[i].taskRun?.status = .running
        chats[i].taskRun?.phase = .execution
        startPipeline(chatID: chatID)
    }

    /// Режим .plan: «Перепланировать» (опц. с правками) — заново этап планирования.
    func replan(chatID: UUID, feedback: String = "") {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              chats[i].taskRun?.status == .awaitingPlan else { return }
        let fb = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fb.isEmpty { chats[i].taskRun?.planFeedback = fb }
        chats[i].taskRun?.phase = .planning
        chats[i].taskRun?.status = .running
        startPipeline(chatID: chatID)
    }

    /// Сбросить прогон (убрать полосу состояния). История в ленте остаётся.
    func cancelRun(chatID: UUID) {
        pipelineGen[chatID] = (pipelineGen[chatID] ?? 0) + 1   // обесценить хвост старого Task
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil
        if let i = chats.firstIndex(where: { $0.id == chatID }) {
            chats[i].taskRun = nil
            chats[i].isLoading = false
        }
    }

    /// При старте приложения: «висящие» running прогоны → paused (живых Task нет).
    private func normalizeTaskRuns() {
        for i in chats.indices where chats[i].taskRun?.status == .running {
            chats[i].taskRun?.status = .paused
            chats[i].isLoading = false
        }
    }

    // MARK: - Sticky Facts (блок фактов)

    /// Для стратегии .stickyFacts — после каждого обмена обновляет блок фактов
    /// по последней паре сообщений (фоновым запросом).
    private func maybeUpdateFacts(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let chat = chats[i]
        let s = chat.settings
        guard s.contextStrategy == .stickyFacts, !chat.isUpdatingFacts, !chat.isLoading else { return }

        // Кормим последнюю пару (вопрос + ответ).
        let recent = Array(chat.messages.suffix(2))
        guard !recent.isEmpty else { return }
        let previousFacts = chat.facts
        let price = pricing["\(s.provider.rawValue)|\(s.model)"]
        chats[i].isUpdatingFacts = true

        Task {
            do {
                let result = try await client.updateFacts(previousFacts: previousFacts, recent: recent, settings: s)
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].facts = result.text
                    chats[j].promptTokens += result.promptTokens
                    chats[j].completionTokens += result.completionTokens
                    chats[j].totalTokens += result.totalTokens
                    chats[j].summaryTokens += result.totalTokens
                    if let price {
                        let cost = Double(result.promptTokens) * price.promptPerToken
                                 + Double(result.completionTokens) * price.completionPerToken
                        chats[j].totalCost += cost
                        chats[j].summaryCost += cost
                    }
                    chats[j].isUpdatingFacts = false
                }
            } catch {
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].isUpdatingFacts = false
                }
            }
        }
    }

    /// Ручное редактирование блока фактов (стратегия .stickyFacts).
    func setFacts(chatID: UUID, _ text: String) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].facts = text
    }

    // MARK: - Память (см. Memory.swift) — сборка, проекты, явное сохранение, ассистент

    /// Привязанный к чату проект (если есть).
    func project(for chat: Chat) -> Project? {
        guard let pid = chat.projectID else { return nil }
        return projects.first(where: { $0.id == pid })
    }

    /// Текст блока памяти для системного промпта (nil — нечего/выключено).
    func memoryText(for chat: Chat) -> String? {
        MemoryContext.assemble(
            longTerm: memory,
            project: project(for: chat),
            shortTerm: chat.memory,
            settings: chat.settings
        )
    }

    // MARK: Долговременная / краткосрочная память (короткие записи)

    /// Сохраняет короткую запись по scope: long → глобально, short → сам чат.
    /// Рабочая память живёт в проекте (см. addEntry) — сюда не идёт.
    func saveMemory(_ item: MemoryItem, chatID: UUID?) {
        switch item.scope {
        case .longTerm:
            memory.insert(item, at: 0)
        case .shortTerm, .working:
            // .working — легаси-значение; трактуем как заметку чата.
            guard let cid = chatID, let ci = chats.firstIndex(where: { $0.id == cid }) else { return }
            var it = item
            if it.scope == .working { it.scope = .shortTerm }
            chats[ci].memory.insert(it, at: 0)
        }
    }

    func deleteMemory(id: UUID, chatID: UUID?) {
        memory.removeAll { $0.id == id }
        if let cid = chatID, let ci = chats.firstIndex(where: { $0.id == cid }) {
            chats[ci].memory.removeAll { $0.id == id }
        }
    }

    /// Правка записи: удалить по id и сохранить заново (учитывает смену scope).
    func updateMemory(_ item: MemoryItem, chatID: UUID?) {
        deleteMemory(id: item.id, chatID: chatID)
        saveMemory(item, chatID: chatID)
    }

    func togglePin(id: UUID, chatID: UUID?) {
        if let i = memory.firstIndex(where: { $0.id == id }) { memory[i].pinned.toggle(); return }
        if let cid = chatID, let ci = chats.firstIndex(where: { $0.id == cid }),
           let i = chats[ci].memory.firstIndex(where: { $0.id == id }) { chats[ci].memory[i].pinned.toggle() }
    }

    // MARK: Проекты (рабочая память: бриф + полнотекстовые секции)

    /// Создаёт проект (ВСЕГДА явно человеком) и опц. привязывает к чату.
    @discardableResult
    func newProject(title: String, brief: String = "", attachTo chatID: UUID? = nil) -> UUID {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Project(title: t.isEmpty ? "Новый проект" : t, brief: brief)
        projects.insert(p, at: 0)
        if let cid = chatID, let ci = chats.firstIndex(where: { $0.id == cid }) {
            chats[ci].projectID = p.id
        }
        return p.id
    }

    /// Привязать (или отвязать — projectID = nil) проект к чату.
    func attachProject(chatID: UUID, projectID: UUID?) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[ci].projectID = projectID
    }

    func updateProject(id: UUID, title: String? = nil, brief: String? = nil) {
        guard let pi = projects.firstIndex(where: { $0.id == id }) else { return }
        if let title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { projects[pi].title = t }
        }
        if let brief { projects[pi].brief = brief }
    }

    /// Удалить проект и отвязать от всех чатов (его рабочая память теряется).
    func deleteProject(id: UUID) {
        projects.removeAll { $0.id == id }
        for ci in chats.indices where chats[ci].projectID == id { chats[ci].projectID = nil }
    }

    func archiveProject(id: UUID, _ archived: Bool) {
        guard let pi = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[pi].archived = archived
    }

    // MARK: Секции проекта (полные тексты)

    /// Добавляет полнотекстовую секцию в проект (заголовок — или явный, или из тела).
    @discardableResult
    func addEntry(projectID: UUID, title: String, body: String, kind: MemoryKind = .knowledge, sourceChatID: UUID? = nil) -> UUID? {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = ProjectEntry(
            title: t.isEmpty ? ProjectEntry.deriveTitle(from: body) : t,
            body: body, kind: kind, sourceChatID: sourceChatID
        )
        projects[pi].entries.insert(entry, at: 0)
        return entry.id
    }

    func updateEntry(_ entry: ProjectEntry, projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let ei = projects[pi].entries.firstIndex(where: { $0.id == entry.id }) else { return }
        projects[pi].entries[ei] = entry
    }

    func deleteEntry(id: UUID, projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[pi].entries.removeAll { $0.id == id }
    }

    func toggleEntryPin(id: UUID, projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let ei = projects[pi].entries.firstIndex(where: { $0.id == id }) else { return }
        projects[pi].entries[ei].pinned.toggle()
    }

    // MARK: Помощники проекта (ИИ): создание из описания, автосекции, сборка

    /// Автосекции: если чат привязан к проекту и включён autoProjectSections —
    /// добавляет ПОЛНЫЙ ответ ассистента секцией (заголовок — фоновым вызовом).
    private func maybeAppendProjectSection(chatID: UUID, answer: String) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let chat = chats[i]
        guard chat.settings.autoProjectSections, let pid = chat.projectID,
              projects.contains(where: { $0.id == pid }) else { return }
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 400 else { return }   // тривиальные ответы пропускаем
        let s = chat.settings
        let price = pricing["\(s.provider.rawValue)|\(s.model)"]
        Task {
            var title = ProjectEntry.deriveTitle(from: body)
            do {
                let r = try await client.sectionTitle(for: body, settings: s)
                let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"«»"))
                if !t.isEmpty { title = t }
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].promptTokens += r.promptTokens
                    chats[j].completionTokens += r.completionTokens
                    chats[j].totalTokens += r.totalTokens
                    chats[j].summaryTokens += r.totalTokens
                    if let price {
                        let cost = Double(r.promptTokens) * price.promptPerToken
                                 + Double(r.completionTokens) * price.completionPerToken
                        chats[j].totalCost += cost
                        chats[j].summaryCost += cost
                    }
                }
            } catch { /* оставляем заголовок по умолчанию */ }
            addEntry(projectID: pid, title: title, body: body, kind: .knowledge, sourceChatID: chatID)
        }
    }

    /// «Собрать»: сшивает полные секции проекта в итог (результат → assemblyResult).
    func assembleProject(projectID: UUID) {
        guard !isAssembling, let p = projects.first(where: { $0.id == projectID }) else { return }
        let s = selectedChat?.settings ?? .default
        let price = pricing["\(s.provider.rawValue)|\(s.model)"]
        isAssembling = true
        assemblyResult = nil
        Task {
            do {
                let result = try await client.assembleProject(title: p.title, brief: p.brief, entries: p.entries, settings: s)
                assemblyResult = result.text
                if let cid = selectedChatID, let j = chats.firstIndex(where: { $0.id == cid }) {
                    chats[j].promptTokens += result.promptTokens
                    chats[j].completionTokens += result.completionTokens
                    chats[j].totalTokens += result.totalTokens
                    if let price {
                        chats[j].totalCost += Double(result.promptTokens) * price.promptPerToken
                                            + Double(result.completionTokens) * price.completionPerToken
                    }
                }
            } catch {
                assemblyResult = "Не удалось собрать: \(error.localizedDescription)"
            }
            isAssembling = false
        }
    }

    // MARK: Ассистент памяти (тогл авто/предлагать)

    /// Фоновый разбор после обмена — только если включён ассистент памяти.
    /// autoMemory: пишет сам; иначе — складывает в memorySuggestions на подтверждение.
    private func maybeMaintainMemory(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        guard chats[i].settings.memoryAssistEnabled, !chats[i].isLoading else { return }
        runMemoryAssist(chatID: chatID, autoWrite: chats[i].settings.autoMemory)
    }

    /// Ручной запрос подсказок (кнопка в панели памяти) — всегда «предлагать».
    func requestMemorySuggestions(chatID: UUID) {
        runMemoryAssist(chatID: chatID, autoWrite: false)
    }

    private func runMemoryAssist(chatID: UUID, autoWrite: Bool) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let chat = chats[i]
        let s = chat.settings
        let recent = Array(chat.messages.suffix(2))
        guard !recent.isEmpty else { return }
        // Что уже в памяти — полный список (не урезанный бюджетом), чтобы модель
        // не дублировала. + дедуп на ЗАПИСЬ ниже (модели мало доверяем).
        let existing = (memory.map { $0.text } + chat.memory.map { $0.text })
            .joined(separator: "\n")
        let price = pricing["\(s.provider.rawValue)|\(s.model)"]

        Task {
            do {
                let result = try await client.suggestMemory(recent: recent, existing: existing, settings: s)
                // Стоимость разбора — в «вклад стратегии» (как у фактов).
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].promptTokens += result.promptTokens
                    chats[j].completionTokens += result.completionTokens
                    chats[j].totalTokens += result.totalTokens
                    chats[j].summaryTokens += result.totalTokens
                    if let price {
                        let cost = Double(result.promptTokens) * price.promptPerToken
                                 + Double(result.completionTokens) * price.completionPerToken
                        chats[j].totalCost += cost
                        chats[j].summaryCost += cost
                    }
                }
                let items = Self.parseSuggestions(result.text, chatID: chatID)
                if autoWrite {
                    // Дедуп на запись: пропускаем то, что уже есть (точно или почти).
                    for it in items where !isDuplicateForScope(it, chatID: chatID) {
                        saveMemory(it, chatID: chatID)
                    }
                } else {
                    // Не предлагать то, что уже в памяти или уже в очереди подсказок.
                    let fresh = items.filter {
                        !isDuplicateForScope($0, chatID: chatID)
                            && !Self.isDuplicate($0.text, in: memorySuggestions)
                    }
                    memorySuggestions.append(contentsOf: fresh)
                }
            } catch {
                // Ассистент памяти не критичен — ошибку молча гасим.
            }
        }
    }

    /// Подтвердить кандидата (возможно отредактированного) → сохранить.
    func confirmSuggestion(_ item: MemoryItem, chatID: UUID?) {
        memorySuggestions.removeAll { $0.id == item.id }
        saveMemory(item, chatID: chatID)
    }

    func dismissSuggestion(id: UUID) {
        memorySuggestions.removeAll { $0.id == id }
    }

    func clearSuggestions() {
        memorySuggestions.removeAll()
    }

    /// Парсит вывод suggestMemory: строки `SCOPE | KIND | текст`.
    /// Терпим к маркерам списка, бэктикам, регистру и русским подписям.
    static func parseSuggestions(_ text: String, chatID: UUID) -> [MemoryItem] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> MemoryItem? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let f = line.first, "-*•`".contains(f) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, !parts[2].isEmpty else { return nil }
            let body = parts[2]
            var kind = parseKind(parts[1])
            var scope = parseScope(parts[0])
            // Жёсткая привязка KIND→SCOPE — структурный «замок» против затопления
            // долговременной деталями текущей задачи (дублирует промпт suggestMemory).
            switch kind {
            case .profile, .preference:
                scope = .longTerm                      // устойчивое о пользователе
            case .decision, .taskData, .note:
                scope = .shortTerm                     // детали текущего диалога/задачи
            case .knowledge:
                // knowledge в долговременную — только если явно про самого пользователя;
                // иначе это техническая деталь задачи → краткосрочная заметка.
                if scope == .longTerm, !Self.mentionsUser(body) {
                    scope = .shortTerm
                    kind = .note
                }
            }
            return MemoryItem(scope: scope, kind: kind, text: body, sourceChatID: chatID)
        }
    }

    private static func parseScope(_ s: String) -> MemoryScope {
        let v = s.lowercased()
        if v.contains("long") || v.contains("долго") { return .longTerm }
        return .shortTerm
    }

    /// Эвристика «запись про самого пользователя» — пускать knowledge в долговременную.
    private static func mentionsUser(_ text: String) -> Bool {
        let v = text.lowercased()
        return ["пользовател", "я знаю", "я умею", "умеет", "владе", "опыт",
                "предпочит", "его роль", "он —", "он-"].contains { v.contains($0) }
    }

    // MARK: Дедуп памяти (структурный — не полагаемся только на модель)

    /// Дубль ли запись в нужном хранилище (по scope).
    private func isDuplicateForScope(_ item: MemoryItem, chatID: UUID?) -> Bool {
        switch item.scope {
        case .longTerm:
            return Self.isDuplicate(item.text, in: memory)
        case .shortTerm, .working:
            guard let cid = chatID, let ci = chats.firstIndex(where: { $0.id == cid }) else { return false }
            return Self.isDuplicate(item.text, in: chats[ci].memory)
        }
    }

    /// Считается дублем, если совпадает почти дословно (Jaccard токенов ≥ 0.6) —
    /// ловит и точные повторы, и переформулировки («Предпочитает…»/«Рассматривает…»).
    static func isDuplicate(_ text: String, in items: [MemoryItem]) -> Bool {
        let t = dedupTokens(text)
        guard !t.isEmpty else { return false }
        for it in items {
            let o = dedupTokens(it.text)
            guard !o.isEmpty else { continue }
            let union = t.union(o).count
            if union > 0, Double(t.intersection(o).count) / Double(union) >= 0.6 { return true }
        }
        return false
    }

    private static let dedupStopwords: Set<String> = [
        "для","и","в","на","с","по","что","это","он","она","его","её","the","a","of","to","for"
    ]

    private static func dedupTokens(_ s: String) -> Set<String> {
        var toks: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty { toks.append(cur); cur = "" }
        }
        if !cur.isEmpty { toks.append(cur) }
        return Set(toks.filter { $0.count > 1 && !dedupStopwords.contains($0) })
    }

    private static func parseKind(_ s: String) -> MemoryKind {
        let v = s.lowercased()
        if v.contains("profile") || v.contains("проф") { return .profile }
        if v.contains("knowled") || v.contains("знан") { return .knowledge }
        if v.contains("taskdata") || v.contains("task") || v.contains("задач") { return .taskData }
        if v.contains("decision") || v.contains("реш") { return .decision }
        if v.contains("prefer") || v.contains("предпоч") { return .preference }
        return .note
    }

    // MARK: - Ветвление (стратегия .branching) — дерево узлов с общим префиксом

    /// Добавляет сообщение узлом под текущим tip (сохраняя дерево/ветки).
    private func addMessage(_ ci: Int, role: ChatRole, content: String, metrics: MessageMetrics? = nil, phase: TaskPhase? = nil) {
        let node = MsgNode(id: UUID(), parentID: chats[ci].currentTipID, role: role, content: content, metrics: metrics, phase: phase)
        chats[ci].nodes.append(node)
        chats[ci].currentTipID = node.id
        // Активная ветка следует за новым сообщением.
        if let active = chats[ci].activeLeafID,
           let li = chats[ci].branchLeaves.firstIndex(where: { $0.id == active }) {
            chats[ci].branchLeaves[li].tipID = node.id
        }
    }

    /// Путь от узла к корню (id'ы в порядке корень→tip).
    private func pathIDs(_ chat: Chat, tip: UUID?) -> [UUID] {
        let byID = Dictionary(chat.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids: [UUID] = []
        var cur = tip
        while let id = cur, let n = byID[id] { ids.append(id); cur = n.parentID }
        return ids.reversed()
    }

    /// Чекпоинт + 2 ветки от сообщения messageID. Узлы общего префикса НЕ копируются —
    /// ветки просто указывают на разные tip'ы дерева.
    func makeBranchFrom(chatID: UUID, messageID: UUID) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }),
              chats[ci].nodes.contains(where: { $0.id == messageID }) else { return }

        if chats[ci].branchLeaves.isEmpty {
            let current = BranchLeaf(name: "Ветка 1", tipID: chats[ci].currentTipID) // текущее продолжение
            let fork = BranchLeaf(name: "Ветка 2", tipID: messageID)                 // от чекпоинта
            chats[ci].branchLeaves = [current, fork]
            chats[ci].activeLeafID = current.id
            chats[ci].currentTipID = current.tipID
        } else {
            let fork = BranchLeaf(name: "Ветка \(chats[ci].branchLeaves.count + 1)", tipID: messageID)
            chats[ci].branchLeaves.append(fork)
            chats[ci].activeLeafID = fork.id
            chats[ci].currentTipID = messageID
        }
    }

    /// Переключение между ветками — просто меняем активный tip.
    func switchBranch(chatID: UUID, branchID: UUID) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }),
              let leaf = chats[ci].branchLeaves.first(where: { $0.id == branchID }) else { return }
        chats[ci].activeLeafID = branchID
        chats[ci].currentTipID = leaf.tipID
    }

    /// Удаляет ветку. При ≤1 оставшейся — схлопываемся в линейную историю.
    /// Узлы, ни на одну ветку/текущий tip не ведущие, подчищаются.
    func deleteBranch(chatID: UUID, branchID: UUID) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }),
              let ti = chats[ci].branchLeaves.firstIndex(where: { $0.id == branchID }) else { return }
        let wasActive = chats[ci].activeLeafID == branchID
        chats[ci].branchLeaves.remove(at: ti)

        if chats[ci].branchLeaves.count <= 1 {
            if let only = chats[ci].branchLeaves.first {
                chats[ci].currentTipID = only.tipID
            }
            chats[ci].branchLeaves = []
            chats[ci].activeLeafID = nil
        } else if wasActive {
            let survivor = chats[ci].branchLeaves[0]
            chats[ci].activeLeafID = survivor.id
            chats[ci].currentTipID = survivor.tipID
        }
        pruneOrphanNodes(ci)
    }

    /// Влить ветку в активную: расходящийся хвост ветки копируется в конец активной.
    func mergeBranch(chatID: UUID, sourceBranchID: UUID) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }),
              chats[ci].activeLeafID != sourceBranchID,
              let source = chats[ci].branchLeaves.first(where: { $0.id == sourceBranchID }) else { return }
        let srcPath = pathIDs(chats[ci], tip: source.tipID)
        let actPath = pathIDs(chats[ci], tip: chats[ci].currentTipID)
        var k = 0
        while k < srcPath.count, k < actPath.count, srcPath[k] == actPath[k] { k += 1 }
        let tail = Array(srcPath[k...])
        guard !tail.isEmpty else { return }

        let byID = Dictionary(chats[ci].nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var parent = chats[ci].currentTipID
        for tid in tail {
            guard let n = byID[tid] else { continue }
            let copy = MsgNode(id: UUID(), parentID: parent, role: n.role, content: n.content, metrics: n.metrics, phase: n.phase)
            chats[ci].nodes.append(copy)
            parent = copy.id
        }
        chats[ci].currentTipID = parent
        if let active = chats[ci].activeLeafID,
           let li = chats[ci].branchLeaves.firstIndex(where: { $0.id == active }) {
            chats[ci].branchLeaves[li].tipID = parent
        }
    }

    /// Оставляет только узлы, достижимые от какого-либо tip (ветки/текущий).
    private func pruneOrphanNodes(_ ci: Int) {
        var tips = chats[ci].branchLeaves.compactMap { $0.tipID }
        if let cur = chats[ci].currentTipID { tips.append(cur) }
        var keep = Set<UUID>()
        for t in tips { for id in pathIDs(chats[ci], tip: t) { keep.insert(id) } }
        chats[ci].nodes.removeAll { !keep.contains($0.id) }
    }

    // MARK: - Видимость усечения контекста

    /// Грубая оценка токенов текста без токенизатора: кириллица ~2.5 симв/токен,
    /// латиница ~4; усреднённо берём 3 символа на токен.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 3)
    }

    /// Оценка токенов всего запроса: системный промпт (с саммари) + хвост
    /// истории после компакции + накладные.
    static func estimateHistoryTokens(_ chat: Chat) -> Int {
        let p = ContextManager.payload(messages: chat.messages, settings: chat.settings, facts: chat.facts)
        let system = estimateTokens(PromptBuilder.systemPrompt(for: chat.settings, facts: p.facts))
        let messages = p.tail.reduce(0) { $0 + estimateTokens($1.content) + 4 }
        return system + messages
    }

    /// Текст предупреждения, если история чата рискует не влезть в окно модели.
    /// nil — всё помещается (или окно модели неизвестно).
    func truncationWarning(for chat: Chat) -> String? {
        let key = "\(chat.settings.provider.rawValue)|\(chat.settings.model)"
        guard let limit = contextLimits[key] else { return nil }
        var estimated = Self.estimateHistoryTokens(chat)
        if let mem = memoryText(for: chat) { estimated += Self.estimateTokens(mem) }
        guard estimated + chat.settings.maxTokens > limit else { return nil }
        return "История ≈\(estimated.formatted()) ток. + лимит ответа \(chat.settings.maxTokens.formatted()) превышают окно модели (\(limit.formatted()) ток.) — провайдер может молча вырезать середину диалога. Уменьши лимит ответа, начни новый чат или выбери модель с большим окном."
    }

    // MARK: - Хелперы

    /// Короткий тайтл из первой строки сообщения (до 40 символов).
    static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return defaultTitle }
        if trimmed.count <= 40 { return trimmed }
        return String(trimmed.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
