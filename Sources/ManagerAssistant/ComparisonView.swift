// ComparisonView.swift — режим параллельного сравнения моделей.
//
// До 3 «дорожек», в каждой своя модель и своя история. Общее поле ввода:
// при отправке один и тот же вопрос уходит во все заполненные дорожки
// ПАРАЛЛЕЛЬНО (каждая со своими провайдером/ключом). Под ответом — метрики
// (время, токены, стоимость), что и нужно для сравнения скорости/цены/качества.
//
// Компакция здесь намеренно выключена — сравниваем модели на чистой истории.

import SwiftUI
import AppKit
import MarkdownUI

@MainActor
final class ComparisonViewModel: ObservableObject {
    struct Track: Identifiable {
        let id = UUID()
        var model: ModelOption?
        var messages: [ChatMessage] = []
        var isLoading = false
        var errorText: String?
        var totalTokens = 0
        var totalCost = 0.0
    }

    @Published var tracks: [Track] = [Track(), Track(), Track()]
    @Published var input = ""

    private let client = DeepSeekClient()
    /// Поиск цены модели — пробрасывается из ChatViewModel.
    var priceLookup: (ModelOption) -> ModelPricing? = { _ in nil }

    var canSend: Bool {
        let hasModel = tracks.contains { $0.model != nil }
        let anyLoading = tracks.contains { $0.isLoading }
        return hasModel && !anyLoading && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""

        for index in tracks.indices {
            guard let model = tracks[index].model else { continue }
            tracks[index].messages.append(ChatMessage(role: .user, content: text))
            tracks[index].errorText = nil
            tracks[index].isLoading = true

            let trackID = tracks[index].id
            let history = tracks[index].messages
            let price = priceLookup(model)
            var built = GenerationSettings()
            built.provider = model.provider
            built.model = model.model
            built.compactionEnabled = false
            let settings = built

            Task {
                let start = Date()
                do {
                    let result = try await client.send(messages: history, settings: settings)
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

    /// Очистить историю всех дорожек (модели оставить).
    func reset() {
        for i in tracks.indices {
            tracks[i].messages = []
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

    /// Какой дорожке сейчас выбираем модель (для листа ModelPickerView).
    @State private var pickingTrack: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Сравнение моделей")
                    .font(.headline)
                Spacer()
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
        .sheet(item: Binding(
            get: { pickingTrack.map { IndexBox(value: $0) } },
            set: { pickingTrack = $0?.value }
        )) { box in
            ModelPickerView(
                models: vm.availableModels,
                current: comp.tracks[box.value].model,
                onSelect: { comp.tracks[box.value].model = $0 }
            )
        }
    }

    // Одна колонка: выбор модели + история + итоги.
    private func trackColumn(_ i: Int) -> some View {
        VStack(spacing: 0) {
            // Заголовок — выбор модели.
            Button {
                pickingTrack = i
            } label: {
                HStack {
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
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .padding(8)
            }
            .buttonStyle(.plain)

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
