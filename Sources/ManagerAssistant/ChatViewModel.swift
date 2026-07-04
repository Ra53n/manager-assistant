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
    /// Инварианты — ограничения (стек/арх/бюджет/запреты/…). Хранятся ОТДЕЛЬНО от
    /// диалога (invariants.json), со скоупами global/project/chat (см. Invariant.swift).
    @Published var invariants: [Invariant] = []
    /// MCP-серверы (конфиг как в Claude) — источники инструментов для агентов
    /// (mcp-servers.json, см. MCPClient.swift).
    @Published var mcpServers: [MCPServer] = []
    /// Последние статусы соединений с MCP-серверами (для UI: подключён / ошибка / число инструментов).
    @Published var mcpStatuses: [UUID: MCPServerStatus] = [:]

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
    /// Менеджер MCP-серверов (actor): живые соединения + маршрутизация вызовов инструментов.
    let mcp = MCPManager()
    /// Хэндлы активных прогонов FSM (для паузы/отмены), ключ — chatID.
    private var pipelineTasks: [UUID: Task<Void, Never>] = [:]
    private var saveCancellable: AnyCancellable?
    private var memorySaveCancellable: AnyCancellable?
    private var projectsSaveCancellable: AnyCancellable?
    private var profilesSaveCancellable: AnyCancellable?
    private var invariantsSaveCancellable: AnyCancellable?
    private var mcpSaveCancellable: AnyCancellable?

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

        // Одноразовая миграция: MCP-инструменты теперь ВКЛ по умолчанию. Включаем их
        // в УЖЕ существующих чатах ОДИН раз (новые получают дефолт сами). Будущие
        // ручные выключения пользователем сохраняются — повторно не трогаем.
        let mcpDefaultKey = "mcpEnabledByDefaultMigration.v1"
        if !UserDefaults.standard.bool(forKey: mcpDefaultKey) {
            for i in chats.indices where !chats[i].settings.mcpEnabled {
                chats[i].settings.mcpEnabled = true
            }
            UserDefaults.standard.set(true, forKey: mcpDefaultKey)
        }

        // Память: долговременная (глобальная) и проекты — из своих файлов.
        memory = MemoryStore.load()
        projects = ProjectStore.load()
        // Профили ответа (при первом запуске — стартовый набор).
        profiles = ProfileStore.load()
        invariants = InvariantStore.load()
        mcpServers = MCPServerStore.load()

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
        invariantsSaveCancellable = $invariants
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { invariants in
                DispatchQueue.global(qos: .utility).async { InvariantStore.save(invariants) }
            }
        mcpSaveCancellable = $mcpServers
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { servers in
                DispatchQueue.global(qos: .utility).async { MCPServerStore.save(servers) }
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
                InvariantStore.save(self.invariants)
                MCPServerStore.save(self.mcpServers)
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
        guard !text.isEmpty else { return false }
        // Активный прогон FSM — текст уходит как уточнение/ответ/смена стадии (см. send()).
        if let run = chats[idx].taskContext, run.status != .finished { return true }
        return !chats[idx].isLoading
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

    // MARK: - Инварианты (см. Invariant.swift) — отдельный стор invariants.json

    /// Эффективный набор инвариантов для чата: глобальные + инварианты его проекта +
    /// инварианты самого чата (только enabled). Это идёт в промпт и в валидацию.
    func effectiveInvariants(for chat: Chat) -> [Invariant] {
        invariants.filter { inv in
            guard inv.enabled else { return false }
            switch inv.scope {
            case .global:  return true
            case .project: return inv.ownerID != nil && inv.ownerID == chat.projectID
            case .chat:    return inv.ownerID == chat.id
            }
        }
    }

    @discardableResult
    func addInvariant(_ inv: Invariant) -> UUID {
        invariants.insert(inv, at: 0)
        return inv.id
    }

    func updateInvariant(_ inv: Invariant) {
        guard let i = invariants.firstIndex(where: { $0.id == inv.id }) else { return }
        invariants[i] = inv
    }

    func removeInvariant(id: UUID) {
        invariants.removeAll { $0.id == id }
    }

    /// Сбросить баннер конфликта инвариантов (после прочтения пользователем).
    func clearInvariantConflict(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].invariantConflict = nil
    }

    // MARK: - MCP-серверы (инструменты для агентов)

    func addMCPServer(_ s: MCPServer) { mcpServers.insert(s, at: 0) }

    func updateMCPServer(_ s: MCPServer) {
        if let i = mcpServers.firstIndex(where: { $0.id == s.id }) { mcpServers[i] = s }
        else { mcpServers.insert(s, at: 0) }
        // Конфиг сервера мог поменяться — сбросим соединение, переподключится по требованию.
        mcpStatuses[s.id] = nil
        let mcp = self.mcp, id = s.id
        Task { await mcp.disconnect(id) }
    }

    func removeMCPServer(id: UUID) {
        mcpServers.removeAll { $0.id == id }
        mcpStatuses[id] = nil
        let mcp = self.mcp
        Task { await mcp.disconnect(id) }
    }

    /// Импорт серверов из JSON-блока в стиле Claude (`mcpServers`). Возвращает число добавленных.
    @discardableResult
    func importMCPConfig(_ json: String) -> Int {
        let parsed = MCPServer.parseClaudeConfig(json)
        guard !parsed.isEmpty else { return 0 }
        mcpServers.insert(contentsOf: parsed, at: 0)
        return parsed.count
    }

    /// Тест соединения (подключить + получить список инструментов) — статус в mcpStatuses.
    func testMCPServer(_ s: MCPServer) {
        let mcp = self.mcp
        Task { [weak self] in
            let st = await mcp.testConnection(s)
            self?.mcpStatuses[s.id] = st
        }
    }

    /// Эффективные MCP-серверы для чата: если включён mcpEnabled — enabled-серверы
    /// (пересечение с enabledMCPServerIDs, либо все, если множество пусто).
    func effectiveMCPServers(for settings: GenerationSettings) -> [MCPServer] {
        guard settings.mcpEnabled else { return [] }
        let enabled = mcpServers.filter { $0.enabled }
        if settings.enabledMCPServerIDs.isEmpty { return enabled }
        return enabled.filter { settings.enabledMCPServerIDs.contains($0.id) }
    }

    /// Подключает нужные серверы и возвращает их инструменты как DTO для LLM.
    /// Обновляет mcpStatuses (для UI). Пусто — если MCP выключен/нет серверов.
    private func mcpToolDTOs(for settings: GenerationSettings) async -> [ChatRequest.Tool] {
        let servers = effectiveMCPServers(for: settings)
        guard !servers.isEmpty else { return [] }
        await mcp.ensureConnected(servers)
        for s in servers { if let st = await mcp.status(for: s.id) { mcpStatuses[s.id] = st } }
        let specs = await mcp.availableTools(serverIDs: Set(servers.map { $0.id }))
        return specs.map { ChatRequest.Tool(spec: $0) }
    }

    /// Замыкание-исполнитель для tool-loop: захватывает ТОЛЬКО actor `mcp` (Sendable),
    /// не таща @MainActor-состояние — легально уходит в группу подагентов роя.
    private func mcpExecutor() -> @Sendable (_ name: String, _ argsJSON: String) async -> String {
        let mcp = self.mcp
        return { name, argsJSON in await mcp.call(qualifiedName: name, argumentsJSON: argsJSON) }
    }

    /// Компактный блок «что вызвал агент» для ленты (перед текстом этапа).
    static func toolTranscriptBlock(_ records: [ToolCallRecord]) -> String {
        guard !records.isEmpty else { return "" }
        return records.map { "🔧 \($0.name) → \($0.ok ? "ok" : "ошибка")" }.joined(separator: "\n")
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
        guard !text.isEmpty else { return }
        let chatID = chats[idx].id

        // Активный прогон FSM: новое сообщение — НЕ новый запуск. Это либо ответ на
        // уточняющий вопрос агента, либо реплика, по которой АГЕНТ-ДИСПЕТЧЕР сам решает,
        // что делать (доработать текущую стадию / вернуться назад / перепланировать / …).
        if let run = chats[idx].taskContext, run.status != .finished {
            addMessage(idx, role: .user, content: text)
            input = ""
            if run.status == .awaitingInput {
                answerClarification(chatID: chatID, answer: text)
            } else {
                handleInterjection(chatID: chatID, text: text)
            }
            return
        }

        guard !chats[idx].isLoading else { return }

        // Тайтл чата — из первого сообщения пользователя.
        if !chats[idx].messages.contains(where: { $0.role == .user }) {
            chats[idx].title = Self.makeTitle(from: text)
        }

        addMessage(idx, role: .user, content: text)
        chats[idx].errorText = nil

        // Режим конечного автомата задачи (FSM): дальше ведёт оркестратор на уровне
        // кода (см. startPipeline), а не один запрос модели. Enter запускает автомат.
        if chats[idx].settings.pipelineMode != .off {
            chats[idx].invariantConflict = nil
            chats[idx].stateChangeError = nil
            chats[idx].taskContext = TaskContext(task: text,
                                                 state: .planning,
                                                 mode: chats[idx].settings.pipelineMode,
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
        // Последние реплики ДО только что добавленного вопроса — контекст для query rewrite
        // (снапшот на MainActor: messages — computed путь по дереву, в Task не лезем).
        let ragHistory = Array(chats[idx].messages.dropLast().suffix(6))

        Task {
            let start = Date()
            do {
                // RAG: релевантные фрагменты из выбранного индекса (async, не блокирует UI).
                // Дописываются к блоку памяти — модель видит их как контекст (см. PromptBuilder).
                let ragBlock = await ragRetrieval(settings: settings, query: text, history: ragHistory)
                let memoryForSend = Self.mergeMemory(memoryText, ragBlock)
                // MCP в обычном чате: если включено и есть инструменты — агентный tool-loop
                // (модель сама дёргает инструменты перед ответом). Иначе — обычный send().
                let toolDTOs = settings.mcpEnabled ? await mcpToolDTOs(for: settings) : []
                let result: SendResult
                var toolTranscript: [ToolCallRecord] = []
                if toolDTOs.isEmpty {
                    result = try await client.send(
                        messages: payload.tail,
                        settings: settings,
                        facts: payload.facts,
                        memory: memoryForSend,
                        inProject: inProject,
                        profile: profileText
                    )
                } else {
                    let loop = try await client.sendWithTools(
                        messages: payload.tail,
                        settings: settings,
                        facts: payload.facts,
                        memory: memoryForSend,
                        inProject: inProject,
                        profile: profileText,
                        tools: toolDTOs,
                        execute: mcpExecutor()
                    )
                    result = loop.sendResult
                    toolTranscript = loop.transcript
                }
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
                    // В ленте — с блоком «что вызвал агент»; в память/секции — чистый текст.
                    let toolBlock = Self.toolTranscriptBlock(toolTranscript)
                    let display = toolBlock.isEmpty ? result.text : toolBlock + "\n\n" + result.text
                    addMessage(i, role: .assistant, content: display, metrics: metrics)
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

    // MARK: - Конечный автомат задачи (FSM): planning → execution(пошагово) → validation → answer

    /// Поколение прогона на чат: каждый startPipeline инкрементит. Старый (отменённый)
    /// Task, доигрывая отмену, проверяет совпадение поколения и НЕ трогает состояние,
    /// если его уже сменил новый прогон (защита от гонки пауза→быстрое продолжение).
    private var pipelineGen: [UUID: Int] = [:]

    /// Запускает (или возобновляет) автомат для чата. Переходы решает КОД (по таблице TaskFSM).
    func startPipeline(chatID: UUID) {
        // FSM (пере)стартует → решения диспетчера на этот момент уже нет (страховка от
        // зависшего индикатора «Агент решает…», если роутер-Task был вытеснен).
        if let i = chats.firstIndex(where: { $0.id == chatID }) { chats[i].isDeciding = false }
        let gen = (pipelineGen[chatID] ?? 0) + 1
        pipelineGen[chatID] = gen
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = Task { await self.runStateMachine(chatID: chatID, gen: gen) }
    }

    /// Главный цикл автомата. Один проход = один запрос модели (этап ИЛИ один шаг
    /// выполнения). ВСЕ переходы — только через `ctx.transitioned(to:)` (сверка с таблицей).
    private func runStateMachine(chatID: UUID, gen: Int) async {
        // RAG-контекст задачи (один раз на весь прогон): релевантные фрагменты по тексту
        // задачи. Одинаков для всех этапов/шагов/подагентов → эмбеддер не гоняется повторно.
        // Пусто, если RAG выключен/не выбран индекс (см. ragRetrieval). Инжектится в
        // buildPrompt/subAgentPrompt ортогонально контекст-стратегиям и памяти.
        var ragBlock = ""
        if let chat = chats.first(where: { $0.id == chatID }), let ctx0 = chat.taskContext {
            ragBlock = await ragRetrieval(settings: chat.settings, query: ctx0.task) ?? ""
        }
        while true {
            // Инструменты MCP подключаем ДО основного guard — вне мутаций ctx, чтобы
            // await не пересёкся с правкой состояния. Выключено → путь без MCP не меняется.
            guard let settingsSnap = chats.first(where: { $0.id == chatID })?.settings,
                  chats.first(where: { $0.id == chatID })?.taskContext?.status == .running else { break }
            let toolDTOs = settingsSnap.mcpEnabled ? await mcpToolDTOs(for: settingsSnap) : []
            guard pipelineGen[chatID] == gen else { return }

            guard let i = chats.firstIndex(where: { $0.id == chatID }),
                  var ctx = chats[i].taskContext, ctx.status == .running else { break }

            let state = ctx.state
            let settings = chats[i].settings
            let profileText = profile(for: chats[i])?.systemDirective ?? ""
            let invs = effectiveInvariants(for: chats[i])   // глобальные + проект + чат
            let price = pricing["\(settings.provider.rawValue)|\(settings.model)"]

            // ЖЁСТКАЯ ГОТОВНОСТЬ ЭТАПА (последний рубеж на уровне кода): НЕ генерируем
            // промпт стадии без РЕАЛЬНОГО результата предыдущей. «Нет результата → нет
            // следующего prompt». Транзишены это и так гарантируют — это страховка от
            // любого пути (меню/диспетчер/гонки), чтобы FSM была по-настоящему жёсткой.
            if state == .validation, ctx.done.isEmpty {
                chats[i].taskContext = ctx.transitioned(to: .execution)   // нет выполнения — назад
                continue
            }
            if state == .answer, ctx.validationResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // «Ответ» терминален — назад нельзя транзишеном; останавливаемся с пояснением.
                chats[i].taskContext?.status = .paused
                chats[i].stateChangeError = "Нельзя сформировать ответ: этап «Проверка» не дал результата."
                chats[i].isLoading = false
                clearTask(chatID, gen: gen)
                return
            }

            // На выполнении выбираем ТЕКУЩИЙ шаг плана (current) и сохраняем для UI/промпта.
            if state == .execution {
                guard !ctx.plan.isEmpty else {                       // плана нет — НЕ прыгаем в проверку,
                    chats[i].taskContext = ctx.transitioned(to: .planning)   // а возвращаемся строить план
                    continue
                }
                ctx.total = ctx.plan.count
                // Рой ВКЛ → волновое (параллельное) выполнение через runWave; иначе пошагово.
                if settings.swarmEnabled {
                    if ctx.waves.isEmpty { ctx.waves = (0..<ctx.plan.count).map { [$0] } }
                    ctx.waveIndex = min(max(0, ctx.waveIndex), ctx.waves.count - 1)
                    chats[i].taskContext = ctx
                    await runWave(chatID: chatID, gen: gen, rag: ragBlock)
                    if pipelineGen[chatID] != gen { return }
                    continue                                          // следующий проход: новая волна / проверка
                }
                ctx.step = min(ctx.step, ctx.plan.count - 1)
                ctx.current = ctx.plan[ctx.step]
                chats[i].taskContext = ctx
            }

            let sys = PipelinePrompts.systemPrompt(for: state, swarm: settings.swarmEnabled, invariants: invs)
            let user = PipelinePrompts.buildPrompt(query: ctx.task, ctx: ctx, profile: profileText, invariants: invs, rag: ragBlock)
            chats[i].isLoading = true

            let start = Date()
            do {
                let result: SendResult
                var toolTranscript: [ToolCallRecord] = []
                if toolDTOs.isEmpty {
                    result = try await client.runPhase(systemPrompt: sys, userMessage: user, settings: settings)
                } else {
                    // Tool-loop: модель может вызывать инструменты MCP, прежде чем дать текст этапа.
                    let loop = try await client.runPhaseWithTools(
                        systemPrompt: sys, userMessage: user, settings: settings,
                        tools: toolDTOs, execute: mcpExecutor())
                    result = loop.sendResult
                    toolTranscript = loop.transcript
                }
                // Прогон сменили (новый startPipeline) — этот молча выходит, состояние чужое.
                guard pipelineGen[chatID] == gen else { return }
                // Отмена «на проводе» (пауза) → тот же этап/шаг, не коммитим.
                if Task.isCancelled { pauseAt(chatID, gen: gen); return }

                // --- Валидация инвариантов: доп. LLM-запрос (await) ДО синхронных мутаций ---
                let invMethod = settings.invariantValidation
                var llmViolations: [InvariantViolation] = []
                if (invMethod == .llm || invMethod == .both), !invs.isEmpty {
                    llmViolations = (try? await client.checkInvariants(response: result.text, invariants: invs, settings: settings)) ?? []
                    guard pipelineGen[chatID] == gen else { return }
                    if Task.isCancelled { pauseAt(chatID, gen: gen); return }
                }

                guard let j = chats.firstIndex(where: { $0.id == chatID }),
                      var c = chats[j].taskContext else { clearTask(chatID, gen: gen); return }

                let pure = PipelinePrompts.stripMarkers(result.text)
                let toolBlock = Self.toolTranscriptBlock(toolTranscript)
                // В ленту показываем «что вызвал агент» + текст; в ctx (done/feedback) — чистый текст.
                let cleaned = toolBlock.isEmpty ? pure : toolBlock + "\n\n" + pure
                let metrics = MessageMetrics(
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    totalTokens: result.totalTokens,
                    duration: Date().timeIntervalSince(start),
                    promptCost: price.map { Double(result.promptTokens) * $0.promptPerToken },
                    completionCost: price.map { Double(result.completionTokens) * $0.completionPerToken }
                )

                // Инварианты (детектится даже при методе .off — они всё равно в промпте).
                // ВАЖНО: НЕ применяем к этапу «Проверка» — он по роли ОБСУЖДАЕТ нарушения
                // (называет запрещённые термины, чтобы их выявить), иначе ложно сработал бы
                // конфликт/код-чек и отчёт проверки ушёл бы «в ответ». Соблюдение инвариантов
                // обеспечивают этапы генерации (планирование/выполнение/ответ).
                if state != .validation, !invs.isEmpty {
                    // КОНФЛИКТ с запросом юзера (модель пометила маркером) → ОБРЫВАЕМ
                    // конвейер: дальше по шагам идти бессмысленно (трата токенов). Показываем
                    // отказ + альтернативу как ИТОГ, ставим баннер, завершаем прогон.
                    if InvariantValidator.modelFlaggedConflict(result.text) {
                        addMessage(j, role: .assistant, content: cleaned, metrics: metrics, state: .answer)
                        accumulateTokens(j, result, metrics)
                        c.answer = cleaned
                        c.status = .finished
                        c.invariantRetries = 0; c.invariantViolations = []
                        chats[j].invariantConflict = "Запрос нарушает инвариант — выполнение остановлено, предложена допустимая альтернатива (см. ответ)."
                        chats[j].taskContext = c
                        persistNow()
                        chats[j].isLoading = false
                        clearTask(chatID, gen: gen)
                        return
                    }
                    // Ошибка МОДЕЛИ (запрещённое вошло в ответ без маркера). Метод .off
                    // проверку не гоняет. Бюджет повторов — НА ВЕСЬ ПРОГОН (invariantRetries
                    // не сбрасывается между шагами), чтобы не зацикливаться и не жечь токены.
                    if invMethod != .off {
                        var violations = (invMethod == .code || invMethod == .both)
                            ? InvariantValidator.codeViolations(result.text, invs) : []
                        violations += llmViolations
                        if !violations.isEmpty {
                            if c.invariantRetries < TaskContext.maxInvariantRetries {
                                c.invariantRetries += 1
                                c.invariantViolations = violations.map { $0.description }
                                chats[j].taskContext = c
                                persistNow()
                                continue   // ТОТ ЖЕ этап/шаг заново — нарушения уйдут в промпт
                            } else {
                                // Бюджет исчерпан, модель не соблюдает инвариант → ОБРЫВАЕМ
                                // (дальше идти по шагам бессмысленно), сообщаем и завершаем.
                                let msg = "Не удалось выполнить без нарушения инвариантов: "
                                    + violations.map { $0.description }.joined(separator: "; ")
                                    + ".\nВыполнение остановлено — уточни задачу или ослабь ограничения."
                                addMessage(j, role: .assistant, content: msg, metrics: metrics, state: .answer)
                                accumulateTokens(j, result, metrics)
                                c.answer = msg
                                c.status = .finished
                                c.invariantRetries = 0; c.invariantViolations = []
                                chats[j].invariantConflict = msg
                                chats[j].taskContext = c
                                persistNow()
                                chats[j].isLoading = false
                                clearTask(chatID, gen: gen)
                                return
                            }
                        } else {
                            // Чисто на этом шаге — снять прокинутые нарушения. Счётчик повторов
                            // НЕ сбрасываем: бюджет общий на прогон.
                            c.invariantViolations = []
                        }
                    }
                }

                // Уточняющий вопрос агента (ASK_USER): остановиться и спросить пользователя.
                // БЕЗ перехода стадии — после ответа продолжим ту же стадию (interject/answer).
                if let pq = PipelinePrompts.parseQuestion(result.text) {
                    let qText = "❓ \(pq.question)\n"
                        + pq.options.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                    addMessage(j, role: .assistant, content: qText, metrics: metrics, state: c.state)
                    accumulateTokens(j, result, metrics)
                    c.pendingQuestion = pq
                    c.status = .awaitingInput
                    chats[j].taskContext = c
                    persistNow()
                    chats[j].isLoading = false
                    clearTask(chatID, gen: gen)
                    return
                }

                // Вывод этапа в контекст + в ленту + ПЕРЕХОД (только через transitioned).
                switch state {
                case .planning:
                    c.plan = PipelinePrompts.parsePlanSteps(result.text)
                    c.total = c.plan.count
                    c.done = []; c.step = 0
                    c.stepResults = []; c.waveIndex = 0
                    // Рой: распарсить зависимости и разложить шаги по волнам (топосортировка).
                    if settings.swarmEnabled {
                        c.stepDeps = PipelinePrompts.parseDeps(result.text, stepCount: c.plan.count).map { $0.sorted() }
                        c.waves = PipelinePrompts.computeWaves(n: c.plan.count, deps: c.stepDeps.map { Set($0) })
                    } else {
                        c.stepDeps = []; c.waves = []
                    }
                    c.current = c.plan.first ?? ""
                    c.planFeedback = ""
                    addMessage(j, role: .assistant, content: cleaned, metrics: metrics, state: .planning)
                    accumulateTokens(j, result, metrics)
                    if c.mode == .plan {
                        c.status = .awaitingPlan                     // план-режим: ждём «Принять план»
                        chats[j].taskContext = c
                        persistNow()
                        chats[j].isLoading = false
                        clearTask(chatID, gen: gen)
                        return
                    }
                    c = c.transitioned(to: .execution)

                case .execution:
                    let stepIdx = c.step, total = c.total
                    if PipelinePrompts.wantsReplan(result.text), c.planRetries < TaskContext.maxPlanRetries {
                        c.planRetries += 1
                        c.planFeedback = pure                         // причина → в планирование (чистый текст)
                        addMessage(j, role: .assistant, content: cleaned, metrics: metrics, state: .execution, step: stepIdx, total: total)
                        accumulateTokens(j, result, metrics)
                        c = c.transitioned(to: .planning)            // шаг назад: перепланировать
                    } else {
                        c.done.append(pure)
                        addMessage(j, role: .assistant, content: cleaned, metrics: metrics, state: .execution, step: stepIdx, total: total)
                        accumulateTokens(j, result, metrics)
                        c.step += 1
                        if c.step >= c.total {
                            c = c.transitioned(to: .validation)      // все шаги сделаны
                        }
                        // иначе остаёмся в .execution — следующий проход возьмёт следующий шаг
                    }
                    // ВАЖНО: фиксируем шаг на диск ДО следующего запроса (см. ниже общий commit).

                case .validation:
                    c.validationResult = result.text
                    c.validationPassed = PipelinePrompts.parseVerdict(result.text)
                    addMessage(j, role: .assistant, content: cleaned, metrics: metrics, state: .validation)
                    accumulateTokens(j, result, metrics)
                    if c.validationPassed == true {
                        c = c.transitioned(to: .answer)
                    } else if c.executionRetries < TaskContext.maxExecutionRetries {
                        c.executionRetries += 1
                        c.done = []; c.step = 0                       // переделать выполнение с замечаниями
                        c.waveIndex = 0; c.stepResults = []          // рой: перезапустить волны
                        c = c.transitioned(to: .execution)
                    } else {
                        c = c.transitioned(to: .answer)
                    }

                case .answer:
                    c.answer = result.text
                    addMessage(j, role: .assistant, content: cleaned, metrics: metrics, state: .answer)
                    accumulateTokens(j, result, metrics)
                    c.status = .finished                             // терминал
                    chats[j].taskContext = c
                    persistNow()
                    chats[j].isLoading = false
                    clearTask(chatID, gen: gen)
                    return
                }
                chats[j].taskContext = c
                persistNow()    // repo.save(ctx): шаг/переход зафиксирован на диск сразу
            } catch {
                // Отмена приходит как CancellationError ИЛИ URLError.cancelled ИЛИ
                // через флаг Task — это ПАУЗА на том же этапе/шаге, а не ошибка.
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                    || Task.isCancelled {
                    pauseAt(chatID, gen: gen)
                    return
                }
                guard pipelineGen[chatID] == gen else { return }
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].taskContext?.status = .failed
                    chats[j].taskContext?.errorText = error.localizedDescription
                    chats[j].errorText = error.localizedDescription
                    chats[j].isLoading = false
                }
                persistNow()    // ошибка (напр. кончились токены) — состояние шага сохранено для возобновления
                clearTask(chatID, gen: gen)
                return
            }
        }
        clearTask(chatID, gen: gen)
        if let i = chats.firstIndex(where: { $0.id == chatID }), pipelineGen[chatID] == gen {
            chats[i].isLoading = false
        }
    }

    /// Токены/стоимость прогона — общий учёт (как в send()).
    private func accumulateTokens(_ j: Int, _ result: SendResult, _ metrics: MessageMetrics) {
        chats[j].promptTokens += result.promptTokens
        chats[j].completionTokens += result.completionTokens
        chats[j].totalTokens += result.totalTokens
        chats[j].totalCost += metrics.totalCost ?? 0
    }

    /// Снять хэндл Task, только если поколение ещё актуально (иначе чужой прогон).
    private func clearTask(_ chatID: UUID, gen: Int) {
        if pipelineGen[chatID] == gen { pipelineTasks[chatID] = nil }
    }

    /// Немедленно и СИНХРОННО сохраняет всё состояние на диск (НЕ дожидаясь дебаунса 300мс) —
    /// явный аналог `repo.save(ctx)`. Вызывается после КАЖДОГО зафиксированного шага/перехода
    /// автомата, а также при паузе/ошибке. Гарантия: на диске всегда лежит последнее
    /// завершённое состояние (state/step/done/plan), даже при выключении питания, kill
    /// процесса или нехватке токенов. Возобновление читает именно это (см. resumePipeline).
    private func persistNow() {
        ChatStore.save(chats)
    }

    /// Пауза прогона: отменяем активный запрос. Статус зафиксирует pauseAt на том же этапе/шаге.
    func pausePipeline(chatID: UUID) {
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil
        if let i = chats.firstIndex(where: { $0.id == chatID }),
           chats[i].taskContext?.status == .running {
            chats[i].taskContext?.status = .paused
            chats[i].isLoading = false
            chats[i].isDeciding = false
            chats[i].liveSubAgents = []
            persistNow()
        }
    }

    /// Зафиксировать паузу (после отмены запроса). State/step НЕ трогаем — возобновление
    /// повторит незавершённый этап/шаг. Не трогает чужой прогон (gen устарел).
    private func pauseAt(_ chatID: UUID, gen: Int) {
        guard pipelineGen[chatID] == gen else { return }
        pipelineTasks[chatID] = nil
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        if chats[i].taskContext?.status == .running { chats[i].taskContext?.status = .paused }
        chats[i].isLoading = false
        chats[i].isDeciding = false
        chats[i].liveSubAgents = []
        persistNow()
    }

    /// Возобновить прогон с текущего этапа/шага (из paused/failed).
    func resumePipeline(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let status = chats[i].taskContext?.status,
              status == .paused || status == .failed else { return }
        chats[i].taskContext?.status = .running
        chats[i].taskContext?.errorText = nil
        chats[i].errorText = nil
        startPipeline(chatID: chatID)
    }

    /// Режим .plan: «Принять план» — переход к выполнению (легально по таблице).
    func approvePlan(chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let ctx = chats[i].taskContext, ctx.status == .awaitingPlan else { return }
        var c = ctx.transitioned(to: .execution)
        c.status = .running
        chats[i].taskContext = c
        startPipeline(chatID: chatID)
    }

    /// Режим .plan: «Перепланировать» (опц. с правками) — заново этап планирования.
    /// state остаётся .planning (из него не уходили) — просто перезапуск.
    func replan(chatID: UUID, feedback: String = "") {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              chats[i].taskContext?.status == .awaitingPlan else { return }
        let fb = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fb.isEmpty { chats[i].taskContext?.planFeedback = fb }
        chats[i].taskContext?.status = .running
        startPipeline(chatID: chatID)
    }

    /// Ручной шаг назад «Выполнение → Планирование» (легально по таблице).
    /// Доступен, когда автомат на этапе .execution.
    func requestReplan(chatID: UUID) {
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let ctx = chats[i].taskContext, ctx.state == .execution,
              ctx.planRetries < TaskContext.maxPlanRetries else { return }
        var c = ctx.transitioned(to: .planning)                 // execution → planning (страж пропустит)
        c.planRetries = ctx.planRetries + 1
        c.planFeedback = "Пользователь запросил перепланирование на этапе выполнения."
        c.status = .running
        chats[i].taskContext = c
        startPipeline(chatID: chatID)
    }

    /// Сбросить прогон (убрать полосу состояния). История в ленте остаётся.
    func cancelRun(chatID: UUID) {
        pipelineGen[chatID] = (pipelineGen[chatID] ?? 0) + 1   // обесценить хвост старого Task
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil
        if let i = chats.firstIndex(where: { $0.id == chatID }) {
            chats[i].taskContext = nil
            chats[i].isLoading = false
            chats[i].stateChangeError = nil
            chats[i].isDeciding = false
            chats[i].liveSubAgents = []
        }
    }

    // MARK: - Интерактивность: реплика пользователя → решение агента-диспетчера

    /// Реплика пользователя во время прогона. Агент-диспетчер (LLM, дешёвый вызов)
    /// решает, что делать: доработать текущую стадию (REDO_CURRENT) / вернуться на
    /// выполнение (BACK) / перепланировать (REPLAN) / начать заново (RESTART) / сменить
    /// стадию (GOTO) / отказать в невозможном переходе (REFUSE). Прежний in-flight запрос
    /// НЕМЕДЛЕННО прерывается (bump gen) — он не продолжится. Решение код перепроверяет по
    /// таблице TaskFSM (LLM её не обходит).
    func handleInterjection(chatID: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              let i = chats.firstIndex(where: { $0.id == chatID }),
              var ctx = chats[i].taskContext, ctx.status != .finished else { return }

        // Правки к плану на паузе «План» — однозначно перепланирование, без диспетчера.
        if ctx.status == .awaitingPlan {
            ctx.guidance.append(t)
            chats[i].taskContext = ctx
            persistNow()
            replan(chatID: chatID, feedback: t)
            return
        }

        // 1) НЕМЕДЛЕННО прервать текущий запрос: bump gen + cancel (не продолжится).
        let gen = (pipelineGen[chatID] ?? 0) + 1
        pipelineGen[chatID] = gen
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil

        // 2) Индикатор «Агент решает…».
        ctx.status = .running
        ctx.errorText = nil
        chats[i].taskContext = ctx
        chats[i].errorText = nil
        chats[i].stateChangeError = nil
        chats[i].isDeciding = true
        chats[i].isLoading = false
        chats[i].liveSubAgents = []
        persistNow()

        let state = ctx.state
        let task = ctx.task
        let settings = chats[i].settings
        let localClient = client

        // 3) Дешёвый вызов диспетчера под новым gen.
        pipelineTasks[chatID] = Task { [weak self] in
            let sys = PipelinePrompts.routerSystemPrompt(state: state)
            let user = PipelinePrompts.routerUserPrompt(task: task, state: state, userText: t)
            var decision: PipelinePrompts.RouterAction = .redoCurrent
            var explanation = ""
            var result: SendResult? = nil
            do {
                let r = try await localClient.runPhase(systemPrompt: sys, userMessage: user,
                                                       settings: settings, temperature: 0.1, maxTokens: 256)
                result = r
                explanation = PipelinePrompts.stripRouterMarker(r.text)
                decision = PipelinePrompts.parseRouterDecision(r.text) ?? .redoCurrent
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                decision = .redoCurrent   // сетевой сбой → безопасный дефолт: доработать текущую
            }
            guard let self else { return }
            // Прогон сменили (новая реплика/действие) — это решение устарело.
            guard self.pipelineGen[chatID] == gen else { return }
            self.applyRouterDecision(chatID: chatID, decision: decision, userText: t,
                                     explanation: explanation, result: result)
        }
    }

    /// Применяет решение диспетчера (MainActor). Любой реальный переход — через
    /// requestStateChange (он сам сверяется с таблицей и делает сбросы/рестарт).
    private func applyRouterDecision(chatID: UUID, decision: PipelinePrompts.RouterAction,
                                     userText: String, explanation: String, result: SendResult?) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              var ctx = chats[i].taskContext else { return }
        chats[i].isDeciding = false
        if let r = result {
            let price = pricing["\(chats[i].settings.provider.rawValue)|\(chats[i].settings.model)"]
            let m = MessageMetrics(promptTokens: r.promptTokens, completionTokens: r.completionTokens,
                                   totalTokens: r.totalTokens, duration: 0,
                                   promptCost: price.map { Double(r.promptTokens) * $0.promptPerToken },
                                   completionCost: price.map { Double(r.completionTokens) * $0.completionPerToken })
            accumulateTokens(i, r, m)   // биллинг вызова диспетчера
        }
        let from = ctx.state
        // Реплику всегда добавляем в guidance — её учтёт любая перезапущенная стадия.
        ctx.guidance.append(userText)
        chats[i].taskContext = ctx

        switch decision {
        case .redoCurrent:
            chats[i].taskContext?.status = .running
            persistNow()
            startPipeline(chatID: chatID)
        case .restart:
            if from == .planning {                       // уже на планировании — просто заново
                chats[i].taskContext?.status = .running
                persistNow()
                startPipeline(chatID: chatID)
            } else {
                requestStateChange(chatID: chatID, to: .planning)   // legal из execution/validation
            }
        case .back, .replan, .goto:
            guard let target = PipelinePrompts.routerTarget(decision, from: from) else { return }
            if from == target {
                chats[i].taskContext?.status = .running
                persistNow()
                startPipeline(chatID: chatID)
            } else if !TaskFSM.allows(from, to: target) {
                refusePath(chatID: chatID, from: from, explanation: explanation)            // недопустим по таблице
            } else if let reason = ctx.transitionBlockReason(to: target) {
                refusePath(chatID: chatID, from: from, explanation: explanation, reason: reason)  // этап ещё не выполнен
            } else {
                requestStateChange(chatID: chatID, to: target)      // сам проверит таблицу+готовность + сбросы
            }
        case .refuse:
            refusePath(chatID: chatID, from: from, explanation: explanation)
        }
    }

    /// Отказ в переходе: агент СООБЩАЕТ причину в ленте и ставит прогон на паузу.
    /// `reason != nil` — переход легален по таблице, но этап-источник ещё не выполнен
    /// (нельзя перепрыгнуть); `reason == nil` — переход недопустим таблицей.
    private func refusePath(chatID: UUID, from: TaskState, explanation: String, reason: String? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].isDeciding = false
        let expl = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if let reason {
            detail = "Сейчас так перейти нельзя: \(reason). Сначала заверши текущий этап."
            chats[i].stateChangeError = "Переход недоступен: \(reason)."
        } else {
            let allowed = TaskFSM.transitions[from, default: []].map { $0.label }
            let allowedText = allowed.isEmpty ? "нет — это терминальная стадия «Ответ»" : allowed.joined(separator: ", ")
            detail = "Из стадии «\(from.label)» доступные переходы: \(allowedText). Можно продолжить текущий прогон или выбрать стадию в меню «→ этап»."
            chats[i].stateChangeError = "Из «\(from.label)» доступные переходы: \(allowedText)."
        }
        let msg = (expl.isEmpty ? "Не могу выполнить такой переход прямо сейчас. " : expl + "\n\n") + detail
        addMessage(i, role: .assistant, content: msg, state: from)
        chats[i].taskContext?.status = .paused
        chats[i].isLoading = false
        pipelineTasks[chatID] = nil
        persistNow()
    }

    /// Ответ на уточняющий вопрос агента (status == .awaitingInput): «Вопрос/Ответ» →
    /// guidance, снять pendingQuestion, продолжить ТУ ЖЕ стадию (без перехода).
    func answerClarification(chatID: UUID, answer: String) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              var ctx = chats[i].taskContext else { return }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = ctx.pendingQuestion?.question ?? ""
        if !a.isEmpty { ctx.guidance.append(q.isEmpty ? a : "Вопрос: \(q)\nОтвет: \(a)") }
        ctx.pendingQuestion = nil
        ctx.status = .running
        chats[i].taskContext = ctx
        persistNow()
        startPipeline(chatID: chatID)
    }

    /// Запрос смены стадии (меню или текстом). Переход — ТОЛЬКО если разрешён таблицей
    /// TaskFSM; иначе баннер с доступными переходами (без обращения к модели).
    func requestStateChange(chatID: UUID, to target: TaskState) {
        // Обесценить хвост старого Task + отменить активный запрос (как cancelRun).
        pipelineGen[chatID] = (pipelineGen[chatID] ?? 0) + 1
        pipelineTasks[chatID]?.cancel()
        pipelineTasks[chatID] = nil
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let ctx = chats[i].taskContext else { return }
        chats[i].isDeciding = false
        chats[i].liveSubAgents = []
        let from = ctx.state

        // Та же стадия — просто перезапустить её (это НЕ переход, страж бы упал).
        if from == target {
            chats[i].stateChangeError = nil
            chats[i].taskContext?.status = .running
            chats[i].taskContext?.pendingQuestion = nil
            chats[i].isLoading = false
            startPipeline(chatID: chatID)
            return
        }

        guard TaskFSM.allows(from, to: target) else {
            let allowed = TaskFSM.transitions[from, default: []].map { $0.label }
            let allowedText = allowed.isEmpty ? "нет (это терминальная стадия)" : allowed.joined(separator: ", ")
            chats[i].stateChangeError = "Не могу перейти из «\(from.label)» в «\(target.label)». "
                + "Доступные переходы: \(allowedText)."
            chats[i].isLoading = false
            return
        }
        // Готовность: вперёд нельзя «перепрыгнуть» через невыполненный этап.
        if let reason = ctx.transitionBlockReason(to: target) {
            chats[i].stateChangeError = "Нельзя перейти в «\(target.label)»: \(reason)."
            chats[i].isLoading = false
            return
        }

        chats[i].stateChangeError = nil
        var c = ctx.transitioned(to: target)
        c.pendingQuestion = nil
        // Ручная смена стадии — явное намерение пользователя: даём свежий бюджет возвратов,
        // иначе прогон с исчерпанными счётчиками мог бы тут же оборваться (forced answer).
        c.executionRetries = 0; c.planRetries = 0
        c.invariantRetries = 0; c.invariantViolations = []
        switch target {                                          // сбросы полей по цели перехода
        case .planning:
            c.plan = []; c.done = []; c.step = 0; c.total = 0; c.current = ""
            c.waves = []; c.waveIndex = 0; c.stepResults = []; c.stepDeps = []
            c.planFeedback = "Пользователь вручную вернул на этап планирования."
        case .execution:
            c.done = []; c.step = 0; c.waveIndex = 0; c.stepResults = []
            c.current = c.plan.first ?? ""
        case .validation, .answer:
            break                                               // переоценить/ответить по текущему done
        }
        c.status = .running
        chats[i].taskContext = c
        chats[i].isLoading = false
        startPipeline(chatID: chatID)
    }

    func clearStateChangeError(chatID: UUID) {
        if let i = chats.firstIndex(where: { $0.id == chatID }) { chats[i].stateChangeError = nil }
    }

    // MARK: - Рой агентов: одна волна параллельного выполнения

    /// Выполняет ТЕКУЩУЮ волну (`waves[waveIndex]`): независимые шаги — параллельно
    /// подагентами (узкий контекст: только их зависимости), оркестратор агрегирует.
    /// Коммит волны — атомарно ПОСЛЕ успеха всех подагентов (краш/пауза → повтор волны).
    private func runWave(chatID: UUID, gen: Int, rag: String = "") async {
        // Инструменты MCP подключаем ДО снимка/группы (await вне мутаций состояния).
        guard let settingsSnap = chats.first(where: { $0.id == chatID })?.settings else { return }
        let toolDTOs = settingsSnap.mcpEnabled ? await mcpToolDTOs(for: settingsSnap) : []
        guard pipelineGen[chatID] == gen else { return }
        let mcpExec = mcpExecutor()

        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              let snap = chats[i].taskContext, snap.status == .running,
              snap.waveIndex < snap.waves.count else { return }

        // Снимок (value-типы) на MainActor — НИЧЕГО из self не захватываем в группу.
        let settings = chats[i].settings
        let profileText = profile(for: chats[i])?.systemDirective ?? ""
        let invs = effectiveInvariants(for: chats[i])
        let price = pricing["\(settings.provider.rawValue)|\(settings.model)"]
        let localClient = client                                // DeepSeekClient — struct без полей (Sendable)
        let task = snap.task
        let plan = snap.plan
        let stepDeps = snap.stepDeps
        let stepResults = snap.stepResults
        let guidance = snap.guidance
        let wave = snap.waves[snap.waveIndex]
        let cap = max(1, settings.maxParallelAgents)
        let sys = PipelinePrompts.subAgentSystemPrompt(invariants: invs)
        chats[i].isLoading = true
        chats[i].isDeciding = false
        // Засеять живые плитки подагентов волны (runtime; UI рисует ряд плиток как в Claude Code).
        chats[i].liveSubAgents = wave.sorted().map {
            LiveSubAgent(id: $0, title: $0 < plan.count ? plan[$0] : "Шаг \($0 + 1)", status: .running)
        }
        let start = Date()

        // Параллельный прогон волны, чанками по cap (захват только value-типов).
        var results: [Int: SendResult] = [:]
        var transcripts: [Int: [ToolCallRecord]] = [:]   // вызовы инструментов по подагенту (для ленты)
        do {
            for chunk in wave.chunked(into: cap) {
                let collected = try await withThrowingTaskGroup(of: (Int, SendResult, [ToolCallRecord]).self) { group -> [(Int, SendResult, [ToolCallRecord])] in
                    for idx in chunk {
                        let deps = idx < stepDeps.count ? Set(stepDeps[idx]) : []
                        let user = PipelinePrompts.subAgentPrompt(task: task, stepIndex: idx, plan: plan,
                                                                  deps: deps, stepResults: stepResults,
                                                                  profile: profileText, invariants: invs,
                                                                  guidance: guidance, rag: rag)
                        group.addTask {                       // ТОЛЬКО value-типы (+ actor mcp), НЕ self
                            if toolDTOs.isEmpty {
                                let r = try await localClient.runPhase(systemPrompt: sys, userMessage: user, settings: settings)
                                return (idx, r, [])
                            } else {
                                // Подагент тоже может вызывать инструменты MCP (узкий контекст + tools).
                                let loop = try await localClient.runPhaseWithTools(
                                    systemPrompt: sys, userMessage: user, settings: settings,
                                    tools: toolDTOs, execute: mcpExec)
                                return (idx, loop.sendResult, loop.transcript)
                            }
                        }
                    }
                    var acc: [(Int, SendResult, [ToolCallRecord])] = []
                    // Тело группы наследует изоляцию runWave (@MainActor) — обновляем плитку
                    // по мере готовности каждого подагента (живой прогресс, до коммита).
                    for try await triple in group {
                        acc.append(triple)
                        let (idx, r, _) = triple
                        if pipelineGen[chatID] == gen,
                           let k = chats.firstIndex(where: { $0.id == chatID }),
                           let t = chats[k].liveSubAgents.firstIndex(where: { $0.id == idx }) {
                            chats[k].liveSubAgents[t].status = .done
                            chats[k].liveSubAgents[t].output = PipelinePrompts.stripMarkers(r.text)
                            chats[k].liveSubAgents[t].tokens = r.totalTokens
                        }
                    }
                    return acc
                }
                for (idx, r, tr) in collected { results[idx] = r; transcripts[idx] = tr }
            }
        } catch {
            // Отмена (пауза) → тот же waveIndex, без коммита. Иначе — failed (возобновляемо).
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                pauseAt(chatID, gen: gen); return
            }
            guard pipelineGen[chatID] == gen else { return }
            if let j = chats.firstIndex(where: { $0.id == chatID }) {
                chats[j].taskContext?.status = .failed
                chats[j].taskContext?.errorText = error.localizedDescription
                chats[j].errorText = error.localizedDescription
                chats[j].isLoading = false
                chats[j].liveSubAgents = []
            }
            persistNow()
            clearTask(chatID, gen: gen)
            return
        }

        // Назад на MainActor: поколение/отмена ДО любых мутаций.
        guard pipelineGen[chatID] == gen else { return }
        if Task.isCancelled { pauseAt(chatID, gen: gen); return }
        guard let j = chats.firstIndex(where: { $0.id == chatID }),
              var c = chats[j].taskContext else { clearTask(chatID, gen: gen); return }

        let waveSorted = wave.sorted()
        let merged = waveSorted.compactMap { results[$0]?.text }.joined(separator: "\n\n")

        // КОНФЛИКТ инварианта (модель пометила) → обрыв конвейера, отказ как итог.
        if !invs.isEmpty, InvariantValidator.modelFlaggedConflict(merged) {
            let cleaned = PipelinePrompts.stripMarkers(merged)
            addMessage(j, role: .assistant, content: cleaned, metrics: waveMetrics(results, price: price, start: start), state: .answer)
            accumulateWaveTokens(j, results, price)
            c.answer = cleaned; c.status = .finished
            c.invariantRetries = 0; c.invariantViolations = []
            chats[j].invariantConflict = "Запрос нарушает инвариант — выполнение остановлено, предложена допустимая альтернатива (см. ответ)."
            chats[j].taskContext = c
            chats[j].liveSubAgents = []
            persistNow(); chats[j].isLoading = false
            clearTask(chatID, gen: gen); return
        }

        // Нарушение МОДЕЛИ (код-проверка по объединённому выводу) → retry всей волны в общем бюджете.
        let invMethod = settings.invariantValidation
        if !invs.isEmpty, invMethod != .off {
            let violations = (invMethod == .code || invMethod == .both)
                ? InvariantValidator.codeViolations(merged, invs) : []
            if !violations.isEmpty {
                if c.invariantRetries < TaskContext.maxInvariantRetries {
                    c.invariantRetries += 1
                    c.invariantViolations = violations.map { $0.description }
                    chats[j].taskContext = c
                    chats[j].liveSubAgents = []                   // следующий проход пересоберёт плитки
                    persistNow()
                    return                                       // та же волна заново (цикл продолжит)
                } else {
                    let msg = "Не удалось выполнить без нарушения инвариантов: "
                        + violations.map { $0.description }.joined(separator: "; ")
                        + ".\nВыполнение остановлено — уточни задачу или ослабь ограничения."
                    addMessage(j, role: .assistant, content: msg, metrics: waveMetrics(results, price: price, start: start), state: .answer)
                    accumulateWaveTokens(j, results, price)
                    c.answer = msg; c.status = .finished
                    c.invariantRetries = 0; c.invariantViolations = []
                    chats[j].invariantConflict = msg
                    chats[j].taskContext = c
                    chats[j].liveSubAgents = []
                    persistNow(); chats[j].isLoading = false
                    clearTask(chatID, gen: gen); return
                }
            } else {
                c.invariantViolations = []
            }
        }

        // REPLAN от подагента → шаг назад в планирование (если бюджет позволяет).
        if PipelinePrompts.wantsReplan(merged), c.planRetries < TaskContext.maxPlanRetries {
            c.planRetries += 1
            c.planFeedback = PipelinePrompts.stripMarkers(merged)
            c.done = []; c.step = 0; c.waveIndex = 0; c.stepResults = []
            c = c.transitioned(to: .planning)
            chats[j].taskContext = c
            chats[j].liveSubAgents = []
            persistNow()
            return
        }

        // Коммит волны (АТОМАРНО, один раз): результаты по индексам шага + в ленту плитками.
        let groupID = UUID()                                     // общая группа волны для UI-плиток
        let waveCount = waveSorted.count
        if c.stepResults.count < plan.count {
            c.stepResults += Array(repeating: "", count: plan.count - c.stepResults.count)
        }
        for idx in waveSorted {
            guard let r = results[idx] else { continue }
            let cleaned = PipelinePrompts.stripMarkers(r.text)   // в stepResults/done — ЧИСТЫЙ текст
            c.stepResults[idx] = cleaned
            c.done.append(cleaned)
            // В ленту — с блоком «что вызвал подагент» (если были вызовы инструментов).
            let toolBlock = Self.toolTranscriptBlock(transcripts[idx] ?? [])
            let display = toolBlock.isEmpty ? cleaned : toolBlock + "\n\n" + cleaned
            let m = MessageMetrics(
                promptTokens: r.promptTokens, completionTokens: r.completionTokens,
                totalTokens: r.totalTokens, duration: Date().timeIntervalSince(start),
                promptCost: price.map { Double(r.promptTokens) * $0.promptPerToken },
                completionCost: price.map { Double(r.completionTokens) * $0.completionPerToken })
            addMessage(j, role: .assistant, content: display, metrics: m, state: .execution, step: idx, total: c.total,
                       waveGroupID: groupID, waveSize: waveCount)
        }
        accumulateWaveTokens(j, results, price)
        c.step = c.done.count
        c.waveIndex += 1
        if c.waveIndex >= c.waves.count { c = c.transitioned(to: .validation) }   // все волны сделаны
        chats[j].taskContext = c
        chats[j].liveSubAgents = []                              // транзиентные плитки → история (плитки в ленте)
        persistNow()
    }

    /// Суммарные метрики волны (для сообщений-итогов: конфликт/исчерпание бюджета).
    private func waveMetrics(_ results: [Int: SendResult], price: ModelPricing?, start: Date) -> MessageMetrics {
        let p = results.values.reduce(0) { $0 + $1.promptTokens }
        let comp = results.values.reduce(0) { $0 + $1.completionTokens }
        let tot = results.values.reduce(0) { $0 + $1.totalTokens }
        return MessageMetrics(
            promptTokens: p, completionTokens: comp, totalTokens: tot,
            duration: Date().timeIntervalSince(start),
            promptCost: price.map { Double(p) * $0.promptPerToken },
            completionCost: price.map { Double(comp) * $0.completionPerToken })
    }

    /// Учёт токенов/стоимости всех подагентов волны в счётчиках чата.
    private func accumulateWaveTokens(_ j: Int, _ results: [Int: SendResult], _ price: ModelPricing?) {
        for r in results.values {
            chats[j].promptTokens += r.promptTokens
            chats[j].completionTokens += r.completionTokens
            chats[j].totalTokens += r.totalTokens
            if let price {
                chats[j].totalCost += Double(r.promptTokens) * price.promptPerToken
                    + Double(r.completionTokens) * price.completionPerToken
            }
        }
    }

    /// При старте приложения: «висящие» running прогоны (после краха/выключения) →
    /// paused (живых Task нет). State/step с диска НЕ трогаем — возобновление продолжит
    /// ровно с последнего сохранённого шага.
    private func normalizeTaskRuns() {
        var changed = false
        for i in chats.indices where chats[i].taskContext?.status == .running {
            chats[i].taskContext?.status = .paused
            chats[i].isLoading = false
            changed = true
        }
        if changed { persistNow() }
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

    /// RAG-ретрив для чата: полный пайплайн (rewrite → поиск → порог → реранк → блок,
    /// см. RagRetriever.retrieveBlock(client:...)). nil — RAG выключен / индекс не выбран /
    /// всё отфильтровано / ошибка (ретрив НИКОГДА не роняет отправку). history — последние
    /// реплики для query rewrite (FSM зовёт без истории: текст задачи самодостаточен).
    /// Бюджет — половина бюджета памяти, чтобы фрагменты не вытесняли остальную память.
    func ragRetrieval(settings: GenerationSettings, query: String, history: [ChatMessage] = []) async -> String? {
        guard settings.ragEnabled, settings.ragIndexID != nil else { return nil }
        return await RagRetriever.retrieveBlock(client: client, settings: settings,
                                                query: query, history: history,
                                                budgetTokens: max(200, settings.memoryTokenBudget / 2))
    }

    /// Склеивает блок памяти и блок RAG в один параметр `memory:` (пустое → nil).
    static func mergeMemory(_ parts: String?...) -> String? {
        let joined = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
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
    private func addMessage(_ ci: Int, role: ChatRole, content: String, metrics: MessageMetrics? = nil, state: TaskState? = nil, step: Int? = nil, total: Int? = nil, waveGroupID: UUID? = nil, waveSize: Int? = nil) {
        let node = MsgNode(id: UUID(), parentID: chats[ci].currentTipID, role: role, content: content, metrics: metrics, state: state, step: step, total: total, waveGroupID: waveGroupID, waveSize: waveSize)
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
            let copy = MsgNode(id: UUID(), parentID: parent, role: n.role, content: n.content, metrics: n.metrics, state: n.state, step: n.step, total: n.total, waveGroupID: n.waveGroupID, waveSize: n.waveSize)
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
