// RagViewModel.swift — состояние UI для RAG. Тонкий клиент над RagStore + асинхронная
// индексация с прогрессом и отменой. По образцу RoutinesViewModel (@MainActor,
// ObservableObject). НЕ участвует в дебаунс-автосохранении $chats — у RAG свой стор
// (rag/), который пишется атомарно после индексации.
//
// Один экземпляр на приложение (создаётся в ContentView) — список индексов общий для
// всех чатов; ретрив в чате читает индекс лениво с диска (RagRetriever), не через этот VM.

import Foundation
import SwiftUI

@MainActor
final class RagViewModel: ObservableObject {
    /// Реестр индексов (источник истины — диск, здесь in-memory кэш).
    @Published var indexes: [RagIndexMeta] = []

    /// Идёт ли сейчас индексация и какого индекса.
    @Published var isIndexing = false
    @Published var indexingID: UUID? = nil
    @Published var progress: IndexProgress? = nil
    @Published var errorText: String? = nil

    /// Доступность Ollama по последней проверке (nil — ещё не проверяли).
    @Published var ollamaAvailable: Bool? = nil

    private var indexTask: Task<Void, Never>? = nil

    init() { indexes = RagStore.loadMeta() }

    /// Перечитать реестр с диска (напр. после внешнего изменения).
    func reload() { indexes = RagStore.loadMeta() }

    // MARK: Мутации реестра

    /// Создаёт «черновик» индекса (isReady=false) и сразу сохраняет реестр.
    @discardableResult
    func addIndex(name: String, source: RagSource, config: RagIndexConfig) -> RagIndexMeta {
        var meta = RagIndexMeta()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.name = trimmed.isEmpty ? URL(fileURLWithPath: source.rootPath).lastPathComponent : trimmed
        meta.source = source
        meta.config = config
        indexes.insert(meta, at: 0)
        persist()
        return meta
    }

    /// Обновляет конфиг/имя существующего индекса (без переиндексации).
    func updateIndex(_ meta: RagIndexMeta) {
        replace(meta)
        persist()
    }

    func deleteIndex(_ id: UUID) {
        if indexingID == id { cancelIndexing() }
        RagStore.deleteIndex(id)
        indexes.removeAll { $0.id == id }
        persist()
    }

    // MARK: Индексация

    /// Запускает (пере)индексацию. Прогресс — в `progress`, ошибка — в `errorText`.
    func startIndexing(_ id: UUID) {
        guard !isIndexing, let meta = indexes.first(where: { $0.id == id }) else { return }
        isIndexing = true
        indexingID = id
        errorText = nil
        progress = IndexProgress()
        // На время перестройки индекс не готов — ретрив его не берёт.
        mutate(id) { $0.isReady = false }
        persist()

        indexTask = Task { [weak self] in
            // Колбэк прогресса маршалим на главный поток.
            let onProgress: @Sendable (IndexProgress) -> Void = { p in
                Task { @MainActor in self?.progress = p }
            }
            do {
                let built = try await RagIndexer.build(meta: meta, progress: onProgress)
                await MainActor.run {
                    guard let self else { return }
                    self.replace(built)
                    self.persist()
                    self.finish()
                }
            } catch is CancellationError {
                // Отмена — не ошибка: индекс остаётся «черновиком» (isReady=false).
                await MainActor.run { self?.finish() }
            } catch {
                await MainActor.run {
                    self?.errorText = Self.describe(error)
                    self?.finish()
                }
            }
        }
    }

    /// Отменяет текущую индексацию (индекс останется «черновиком»).
    func cancelIndexing() { indexTask?.cancel() }

    // MARK: Ollama / тестовый поиск

    /// Проверяет доступность Ollama по адресу из конфига (для бейджа в редакторе).
    func checkOllama(baseURL: String) {
        Task { [weak self] in
            let ok = await OllamaEmbedder.isAvailable(baseURL: baseURL)
            await MainActor.run { self?.ollamaAvailable = ok }
        }
    }

    /// Тестовый поиск по индексу (для панели): top-K попаданий со score.
    func testSearch(indexID: UUID, query: String, topK: Int) async -> [RagRetrievalHit] {
        await RagRetriever.search(indexID: indexID, query: query, topK: topK)
    }

    // MARK: Внутреннее

    private func finish() {
        isIndexing = false
        indexingID = nil
        progress = nil
        indexTask = nil
    }

    private func replace(_ meta: RagIndexMeta) {
        if let i = indexes.firstIndex(where: { $0.id == meta.id }) { indexes[i] = meta }
        else { indexes.insert(meta, at: 0) }
    }

    private func mutate(_ id: UUID, _ body: (inout RagIndexMeta) -> Void) {
        if let i = indexes.firstIndex(where: { $0.id == id }) { body(&indexes[i]) }
    }

    private func persist() { RagStore.saveMeta(indexes) }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
