// ComparisonView.swift — режим параллельного сравнения моделей.
//
// 2–3 «дорожки», у каждой СВОЯ модель, СВОИ настройки генерации (включая
// компакцию контекста) и своя история. Общее поле ввода: вопрос уходит во все
// заполненные дорожки ПАРАЛЛЕЛЬНО (каждая со своим провайдером/ключом). Под
// ответом — метрики (время, токены, стоимость), сверху колонки — её итоги.
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
        var summary = ""
        var summarizedUpTo = 0
        var isSummarizing = false
        var isLoading = false
        var errorText: String?
        var totalTokens = 0
        var totalCost = 0.0
    }

    @Published var tracks: [Track] = [Track(), Track()]   // старт с двух
    @Published var input = ""

    static let maxTracks = 3

    private let client = DeepSeekClient()
    /// Поиск цены модели — пробрасывается из ChatViewModel.
    var priceLookup: (ModelOption) -> ModelPricing? = { _ in nil }

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
            // Компакция: шлём хвост после summarizedUpTo + саммари.
            let upTo = settings.compactionEnabled ? min(tracks[index].summarizedUpTo, tracks[index].messages.count) : 0
            let history = Array(tracks[index].messages[upTo...])
            let summary = settings.compactionEnabled ? tracks[index].summary : ""
            let price = priceLookup(model)

            Task {
                let start = Date()
                do {
                    let result = try await client.send(
                        messages: history,
                        settings: settings,
                        summary: summary.isEmpty ? nil : summary
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
                    if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                        tracks[j].messages.append(ChatMessage(role: .assistant, content: result.text, metrics: metrics))
                        tracks[j].totalTokens += result.totalTokens
                        tracks[j].totalCost += metrics.totalCost ?? 0
                        tracks[j].isLoading = false
                        maybeCompactTrack(trackID)
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

    /// Свернуть старые сообщения дорожки в саммари (аналог ChatViewModel.maybeCompact).
    private func maybeCompactTrack(_ trackID: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == trackID }),
              let settings = effectiveSettings(tracks[i]) else { return }
        let track = tracks[i]
        guard settings.compactionEnabled, !track.isSummarizing, !track.isLoading else { return }

        let window = max(2, settings.historyWindow)
        let overflow = track.messages.count - track.summarizedUpTo - window
        guard overflow >= window else { return }

        let block = Array(track.messages[track.summarizedUpTo ..< (track.summarizedUpTo + overflow)])
        let previousSummary = track.summary
        let price = priceLookup(track.model!)
        tracks[i].isSummarizing = true

        Task {
            do {
                let result = try await client.summarize(previousSummary: previousSummary, block: block, settings: settings)
                if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[j].summary = result.text
                    tracks[j].summarizedUpTo += block.count
                    tracks[j].totalTokens += result.totalTokens
                    if let price {
                        tracks[j].totalCost += Double(result.promptTokens) * price.promptPerToken
                                             + Double(result.completionTokens) * price.completionPerToken
                    }
                    tracks[j].isSummarizing = false
                }
            } catch {
                if let j = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[j].isSummarizing = false
                }
            }
        }
    }

    /// Очистить историю всех дорожек (модели и настройки оставить).
    func reset() {
        for i in tracks.indices {
            tracks[i].messages = []
            tracks[i].summary = ""
            tracks[i].summarizedUpTo = 0
            tracks[i].errorText = nil
            tracks[i].totalTokens = 0
            tracks[i].totalCost = 0
        }
    }
}

struct ComparisonView: View {
    @ObservedObject var vm: ChatViewModel          // для списка моделей и цен
    @StateObject private var comp = ComparisonViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var pickingTrack: IndexBox?
    @State private var settingsTrack: IndexBox?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Сравнение моделей")
                    .font(.headline)
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

            HStack(spacing: 0) {
                ForEach(comp.tracks.indices, id: \.self) { i in
                    trackColumn(i)
                    if i < comp.tracks.count - 1 { Divider() }
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
        .frame(width: 1040, height: 680)
        .onAppear {
            comp.priceLookup = { vm.price(for: $0) }
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
                    showModelSection: false
                )
            }
        }
    }

    // Одна колонка: выбор модели + настройки + история + итоги.
    private func trackColumn(_ i: Int) -> some View {
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
                    if comp.tracks[i].isSummarizing {
                        Label("сжимаю историю…", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2).foregroundColor(.secondary)
                    } else if comp.tracks[i].summarizedUpTo > 0 {
                        Label("\(comp.tracks[i].summarizedUpTo) сообщ. сжаты в саммари", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2).foregroundColor(.secondary)
                            .help(comp.tracks[i].summary)
                    }
                    ForEach(comp.tracks[i].messages) { msg in
                        ComparisonMessage(message: msg)
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
        .frame(maxWidth: .infinity)
    }
}

/// Сообщение в колонке сравнения: вопрос — серым, ответ — Markdown + метрики.
private struct ComparisonMessage: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            Text(message.content)
                .font(.callout.weight(.medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Markdown(message.content)
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
