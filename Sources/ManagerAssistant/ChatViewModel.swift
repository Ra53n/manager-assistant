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

        chats[idx].messages.append(ChatMessage(role: .user, content: text))
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
                    chats[i].messages.append(ChatMessage(role: .assistant, content: result.text, metrics: metrics))
                    chats[i].promptTokens += result.promptTokens
                    chats[i].completionTokens += result.completionTokens
                    chats[i].totalTokens += result.totalTokens
                    chats[i].totalCost += metrics.totalCost ?? 0
                    chats[i].isLoading = false
                    mirrorActiveBranch(i)
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
                    mirrorActiveBranch(j)
                    chats[j].isUpdatingFacts = false
                }
            } catch {
                if let j = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[j].isUpdatingFacts = false
                }
            }
        }
    }

    // MARK: - Ветвление (стратегия .branching)

    /// Чекпоинт + создание веток от сообщения messageID.
    /// Первый вызов делает 2 ветки от одной точки: «Ветка 1» = текущее продолжение,
    /// «Ветка 2» = копия истории до чекпоинта (для независимого продолжения).
    /// Последующие вызовы добавляют ещё одну ветку от чекпоинта активной ветки.
    func makeBranchFrom(chatID: UUID, messageID: UUID) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }),
              let mi = chats[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let prefix = Array(chats[ci].messages[0...mi])

        if chats[ci].branches.isEmpty {
            let current = ChatBranch(name: "Ветка 1", messages: chats[ci].messages, facts: chats[ci].facts)
            let fork = ChatBranch(name: "Ветка 2", messages: prefix, facts: chats[ci].facts)
            chats[ci].branches = [current, fork]
            chats[ci].activeBranchID = current.id   // остаёмся в текущем продолжении
        } else {
            mirrorActiveBranch(ci)
            let fork = ChatBranch(name: "Ветка \(chats[ci].branches.count + 1)", messages: prefix, facts: chats[ci].facts)
            chats[ci].branches.append(fork)
            chats[ci].activeBranchID = fork.id      // переключаемся на новую ветку
            chats[ci].messages = fork.messages
            chats[ci].facts = fork.facts
        }
    }

    /// Переключение между ветками: текущую сохраняем, целевую загружаем.
    func switchBranch(chatID: UUID, branchID: UUID) {
        guard let ci = chats.firstIndex(where: { $0.id == chatID }),
              chats[ci].activeBranchID != branchID,
              let ti = chats[ci].branches.firstIndex(where: { $0.id == branchID }) else { return }
        mirrorActiveBranch(ci)
        chats[ci].activeBranchID = branchID
        chats[ci].messages = chats[ci].branches[ti].messages
        chats[ci].facts = chats[ci].branches[ti].facts
    }

    /// Синхронизирует messages/facts активного чата в его ветку (инвариант зеркала).
    private func mirrorActiveBranch(_ chatIndex: Int) {
        guard let active = chats[chatIndex].activeBranchID,
              let bi = chats[chatIndex].branches.firstIndex(where: { $0.id == active }) else { return }
        chats[chatIndex].branches[bi].messages = chats[chatIndex].messages
        chats[chatIndex].branches[bi].facts = chats[chatIndex].facts
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
