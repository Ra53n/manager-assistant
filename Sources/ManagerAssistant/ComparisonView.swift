// ComparisonView.swift — режим параллельного сравнения моделей.
//
// 2–3 «дорожки», у каждой СВОЯ модель, СВОИ настройки генерации (включая
// компакцию контекста) и своя история. Общее поле ввода: вопрос уходит во все
// заполненные дорожки ПАРАЛЛЕЛЬНО (каждая со своим провайдером/ключом). Под
// ответом — метрики (время, токены, стоимость), сверху колонки — её итоги.
//
// RAG per-lane: у каждой дорожки свой тумблер/индекс/topK (settings.ragEnabled и
// друзья — те же поля GenerationSettings, что в обычном чате); ретрив мержится в
// memory поверх долговременной памяти. Так один вопрос даёт ответы «без RAG» и
// «с RAG» бок о бок (одна и та же модель в двух колонках — честное сравнение).
// Индикатор-лупа в шапке колонки показывает, где RAG включён и какой индекс.
//
// Компакция дорожки повторяет логику ChatViewModel.maybeCompact (тот же
// client.summarize), но на своей структуре Track.

import SwiftUI
import AppKit
import MarkdownUI

@MainActor
final class ComparisonViewModel: ObservableObject {
    struct Track: Identifiable {
        let id = UUID()
        var model: ModelOption?
        var settings = GenerationSettings()      // параметры генерации этой модели
        var messages: [ChatMessage] = []
        var facts = ""
        var isUpdatingFacts = false
        var isLoading = false
        var errorText: String?
        var totalTokens = 0
        var totalCost = 0.0
        var summaryTokens = 0      // вклад саммаризации (подмножество total)
        var summaryCost = 0.0
    }

    @Published var tracks: [Track] = [Track(), Track()]   // старт с двух
    @Published var input = ""

    static let maxTracks = 6

    private let client = DeepSeekClient()
    /// Поиск цены модели — пробрасывается из ChatViewModel.
    var priceLookup: (ModelOption) -> ModelPricing? = { _ in nil }
    /// Долговременная (глобальная) память — пробрасывается из ChatViewModel.
    /// В сравнении инжектится во все дорожки read-only (одинаковый профиль всем).
    var globalMemoryLookup: () -> [MemoryItem] = { [] }

    var canAddTrack: Bool { tracks.count < Self.maxTracks }
    var canRemoveTrack: Bool { tracks.count > 2 }

    var canSend: Bool {
        let hasModel = tracks.contains { $0.model != nil }
        let anyLoading = tracks.contains { $0.isLoading }
        return hasModel && !anyLoading && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func addTrack() {
        guard canAddTrack else { return }
        tracks.append(Track())
    }

    func removeTrack(_ id: UUID) {
        guard canRemoveTrack else { return }
        tracks.removeAll { $0.id == id }
    }

    /// Настройки дорожки с проставленными provider/model выбранной модели.
    private func effectiveSettings(_ track: Track) -> GenerationSettings? {
        guard let model = track.model else { return nil }
        var s = track.settings
        s.provider = model.provider
        s.model = model.model
        return s
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""

        for index in tracks.indices {
            guard let settings = effectiveSettings(tracks[index]) else { continue }
            let model = tracks[index].model!
            tracks[index].messages.append(ChatMessage(role: .user, content: text))
            tracks[index].errorText = nil
            tracks[index].isLoading = true

            let trackID = tracks[index].id
            let payload = ContextManager.payload(messages: tracks[index].messages, settings: settings, facts: tracks[index].facts)
            let memoryText = MemoryContext.assembleLongTermOnly(longTerm: globalMemoryLookup(), settings: settings)
            let price = priceLookup(model)
            // История дорожки ДО только что добавленного вопроса — контекст для query rewrite.
            let ragHistory = Array(tracks[index].messages.dropLast().suffix(6))

            Task {
                let start = Date()
                do {
                    // RAG per-lane: полный пайплайн (rewrite → поиск → порог → реранк —
                    // настройки у каждой дорожки свои, что и даёт сравнение режимов
                    // «с фильтром / без» бок о бок). Ошибка ретрива невозможна
                    // (retrieveBlock возвращает nil) — send не ломается.
                    let ragBlock = await RagRetriever.retrieveBlock(
                        client: client, settings: settings, query: text, history: ragHistory,
                        budgetTokens: max(200, settings.memoryTokenBudget / 2))
                    let result = try await client.send(
                        messages: payload.tail,
                        settings: settings,
                        facts: payload.facts,
                        memory: ChatViewModel.mergeMemory(memoryText, ragBlock)
                    )
                    let duration = Date().timeIntervalSince(start)
                    // Гарантия «Источников» в сравнении — ТОЛЬКО автофутер, БЕЗ ретрая:
                    // скрытый второй LLM-вызов исказил бы честный замер токенов/стоимости
                    // дорожки. ensureSourcesSection — no-op, если раздел уже есть /
                    // ответ «не знаю» / меток нет (RAG выключен, notFoundDirective).
                    let answerText = settings.ragStrictMode
                        ? RagRerank.ensureSourcesSection(answer: result.text, ragBlock: ragBlock ?? "")
                        : result.text
                    let metrics = MessageMetrics(
                        promptTokens: result.promptTokens,
                        completionTokens: result.completionTokens,
                        totalTokens: result.totalTokens,
                        duration: duration,
                        promptCost: price.map { Double(result.promptTokens) * $0.promptPerToken },
                        completionCost: price.map { Double(result.completionTokens) * $0.completionPerToken }
                    )
                    if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                        tracks[j].messages.append(ChatMessage(role: .assistant, content: answerText, metrics: metrics))
                        tracks[j].totalTokens += result.totalTokens
                        tracks[j].totalCost += metrics.totalCost ?? 0
                        tracks[j].isLoading = false
                        maybeUpdateFactsTrack(trackID)
                    }
                } catch {
                    if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                        tracks[j].errorText = error.localizedDescription
                        tracks[j].isLoading = false
                    }
                }
            }
        }
    }

    /// Для стратегии .stickyFacts — обновляет факты дорожки по последней паре.
    private func maybeUpdateFactsTrack(_ trackID: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == trackID }),
              let settings = effectiveSettings(tracks[i]) else { return }
        let track = tracks[i]
        guard settings.contextStrategy == .stickyFacts, !track.isUpdatingFacts, !track.isLoading else { return }
        let recent = Array(track.messages.suffix(2))
        guard !recent.isEmpty else { return }
        let previousFacts = track.facts
        let price = priceLookup(track.model!)
        tracks[i].isUpdatingFacts = true

        Task {
            do {
                let result = try await client.updateFacts(previousFacts: previousFacts, recent: recent, settings: settings)
                if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[j].facts = result.text
                    tracks[j].totalTokens += result.totalTokens
                    tracks[j].summaryTokens += result.totalTokens
                    if let price {
                        let cost = Double(result.promptTokens) * price.promptPerToken
                                 + Double(result.completionTokens) * price.completionPerToken
                        tracks[j].totalCost += cost
                        tracks[j].summaryCost += cost
                    }
                    tracks[j].isUpdatingFacts = false
                }
            } catch {
                if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[j].isUpdatingFacts = false
                }
            }
        }
    }

    /// Очистить историю всех дорожек (модели и настройки оставить).
    func reset() {
        for i in tracks.indices {
            tracks[i].messages = []
            tracks[i].facts = ""
            tracks[i].errorText = nil
            tracks[i].totalTokens = 0
            tracks[i].totalCost = 0
            tracks[i].summaryTokens = 0
            tracks[i].summaryCost = 0
        }
    }
}

struct ComparisonView: View {
    @ObservedObject var vm: ChatViewModel          // для списка моделей и цен
    /// RAG-индексы (для per-lane ретрива): секция в настройках дорожки + индикатор в шапке.
    @ObservedObject var ragVM: RagViewModel
    @StateObject private var comp = ComparisonViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var pickingTrack: IndexBox?
    @State private var settingsTrack: IndexBox?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Сравнение моделей")
                    .font(.headline)
                if !vm.memory.isEmpty {
                    Label("долговременная память: \(vm.memory.count)", systemImage: "brain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("Глобальная память подставляется во все дорожки одинаково")
                }
                Spacer()
                Button {
                    comp.addTrack()
                } label: {
                    Label("Добавить модель", systemImage: "plus")
                }
                .disabled(!comp.canAddTrack)
                Button("Очистить") { comp.reset() }
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // Колонки адаптивны: при 2–4 заполняют ширину, при 5–6 — горизонтальный скролл.
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: comp.tracks.count > 4) {
                    HStack(spacing: 0) {
                        ForEach(comp.tracks.indices, id: \.self) { i in
                            trackColumn(i, width: columnWidth(total: geo.size.width))
                            if i < comp.tracks.count - 1 { Divider() }
                        }
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Вопрос всем выбранным моделям…", text: $comp.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35)))
                    .onSubmit { comp.send() }
                Button(action: comp.send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!comp.canSend)
            }
            .padding()
        }
        .frame(width: 1180, height: 700)
        .onAppear {
            comp.priceLookup = { vm.price(for: $0) }
            comp.globalMemoryLookup = { vm.memory }
            vm.loadModels()
        }
        .sheet(item: $pickingTrack) { box in
            ModelPickerView(
                models: vm.availableModels,
                current: comp.tracks[safe: box.value]?.model ?? nil,
                onSelect: { model in
                    if box.value < comp.tracks.count { comp.tracks[box.value].model = model }
                }
            )
        }
        .sheet(item: $settingsTrack) { box in
            if box.value < comp.tracks.count {
                ChatSettingsView(
                    vm: vm,
                    settings: $comp.tracks[box.value].settings,
                    showModelSection: false,
                    allowBranching: false,
                    showMemorySection: false,
                    showProfileSection: false,
                    ragVM: ragVM        // per-lane RAG: тумблер/индекс/topK в секции «RAG»
                )
            }
        }
    }

    /// Имя RAG-индекса по id (для индикатора в шапке дорожки).
    private func ragIndexName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return ragVM.indexes.first(where: { $0.id == id })?.name
    }

    /// Ширина колонки: total/count, но не уже 300pt (тогда включается горизонтальный скролл).
    private func columnWidth(total: CGFloat) -> CGFloat {
        let count = max(1, comp.tracks.count)
        let available = total - CGFloat(count - 1)   // вычесть разделители
        return max(300, available / CGFloat(count))
    }

    // Одна колонка: выбор модели + настройки + история + итоги.
    private func trackColumn(_ i: Int, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Шапка: модель (пикер) + ⚙︎ + удалить.
            HStack(spacing: 4) {
                Button {
                    pickingTrack = IndexBox(value: i)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(comp.tracks[i].model?.model ?? "Выбрать модель")
                            .lineLimit(1)
                            .foregroundColor(comp.tracks[i].model == nil ? .secondary : .primary)
                        if let m = comp.tracks[i].model {
                            Text(m.provider.displayName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Индикатор RAG дорожки: вкл — accent + имя индекса (видно на скриншотах,
                // какая колонка «с RAG»). Тап открывает настройки дорожки (секция «RAG»).
                Button { settingsTrack = IndexBox(value: i) } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "text.magnifyingglass")
                        if comp.tracks[i].settings.ragEnabled {
                            Text(ragIndexName(comp.tracks[i].settings.ragIndexID) ?? "RAG")
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(maxWidth: 90)
                        }
                    }
                    .foregroundStyle(comp.tracks[i].settings.ragEnabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(comp.tracks[i].settings.ragEnabled
                      ? "RAG включён: \(ragIndexName(comp.tracks[i].settings.ragIndexID) ?? "индекс не выбран")"
                      : "RAG выключен — включить в настройках дорожки")

                Button { settingsTrack = IndexBox(value: i) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Настройки этой модели")

                if comp.canRemoveTrack {
                    Button { comp.removeTrack(comp.tracks[i].id) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать колонку")
                }
            }
            .padding(8)

            // Итоги по дорожке.
            if comp.tracks[i].totalTokens > 0 {
                HStack {
                    Text("\(comp.tracks[i].totalTokens.formatted()) ток.")
                    if comp.tracks[i].totalCost > 0 {
                        Text("· \(MessageBubble.formatCost(comp.tracks[i].totalCost))")
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if comp.tracks[i].isUpdatingFacts {
                        Label("обновляю факты…", systemImage: "key")
                            .font(.caption2).foregroundColor(.secondary)
                    } else if !comp.tracks[i].facts.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            Label("память фактов активна", systemImage: "key")
                            if comp.tracks[i].summaryTokens > 0 {
                                Text("на факты: \(comp.tracks[i].summaryTokens.formatted()) ток." +
                                     (comp.tracks[i].summaryCost > 0 ? " · \(MessageBubble.formatCost(comp.tracks[i].summaryCost))" : ""))
                            }
                        }
                        .font(.caption2).foregroundColor(.secondary)
                        .help(comp.tracks[i].facts)
                    }
                    ForEach(comp.tracks[i].messages) { msg in
                        // .equatable() — не пересоздавать Markdown при стриминге
                        // других дорожек, иначе слетает выделение текста.
                        ComparisonMessage(message: msg).equatable()
                    }
                    if comp.tracks[i].isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("думает…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let err = comp.tracks[i].errorText {
                        Text(err).font(.caption).foregroundColor(.orange)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width)
    }
}

/// Сообщение в колонке сравнения: вопрос — серым, ответ — Markdown + метрики.
/// Equatable (см. .equatable() в ленте) — чтобы выделение текста не сбрасывалось
/// при перерисовке колонки во время стриминга соседних дорожек.
private struct ComparisonMessage: View, Equatable {
    let message: ChatMessage

    static func == (a: ComparisonMessage, b: ComparisonMessage) -> Bool {
        a.message.id == b.message.id && a.message.content == b.message.content
    }

    var body: some View {
        if message.role == .user {
            Text(message.content)
                .font(.callout.weight(.medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(MarkdownText.attributed(message.content))
                    .tint(.accentColor)
                    .textSelection(.enabled)
                if let m = message.metrics {
                    Text(MessageBubble.metricsText(m))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Обёртка Int в Identifiable для .sheet(item:).
private struct IndexBox: Identifiable {
    let value: Int
    var id: Int { value }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
