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
    private var saveCancellable: AnyCancellable?

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

        // Автосохранение при любом изменении чатов. Дебаунс гасит шквал
        // обновлений (например, перетаскивание слайдеров в настройках).
        saveCancellable = $chats
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { chats in
                DispatchQueue.global(qos: .utility).async { ChatStore.save(chats) }
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
                guard let chats = self?.chats else { return }
                ChatStore.save(chats)
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

    /// Можно ли отправлять: есть выбранный чат, непустой текст и он сейчас не грузится.
    var canSend: Bool {
        guard let idx = selectedIndex else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !chats[idx].isLoading
    }

    // MARK: - Управление чатами

    func newChat() {
        let chat = Chat(title: Self.defaultTitle)
        chats.insert(chat, at: 0) // новые сверху
        selectedChatID = chat.id
        input = ""
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

        let chatID = chats[idx].id

        // Тайтл чата — из первого сообщения пользователя.
        if !chats[idx].messages.contains(where: { $0.role == .user }) {
            chats[idx].title = Self.makeTitle(from: text)
        }

        addMessage(idx, role: .user, content: text)
        chats[idx].errorText = nil
        chats[idx].isLoading = true
        input = ""

        // Что уходит модели — определяет выбранная стратегия контекста.
        let settings = chats[idx].settings
        let payload = ContextManager.payload(messages: chats[idx].messages, settings: settings, facts: chats[idx].facts)
        let price = pricing["\(settings.provider.rawValue)|\(settings.model)"]

        Task {
            let start = Date()
            do {
                let result = try await client.send(
                    messages: payload.tail,
                    settings: settings,
                    facts: payload.facts
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
                }
            } catch {
                if let i = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[i].errorText = error.localizedDescription
                    chats[i].isLoading = false
                }
            }
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

    // MARK: - Ветвление (стратегия .branching) — дерево узлов с общим префиксом

    /// Добавляет сообщение узлом под текущим tip (сохраняя дерево/ветки).
    private func addMessage(_ ci: Int, role: ChatRole, content: String, metrics: MessageMetrics? = nil) {
        let node = MsgNode(id: UUID(), parentID: chats[ci].currentTipID, role: role, content: content, metrics: metrics)
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
            let copy = MsgNode(id: UUID(), parentID: parent, role: n.role, content: n.content, metrics: n.metrics)
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
        let estimated = Self.estimateHistoryTokens(chat)
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
