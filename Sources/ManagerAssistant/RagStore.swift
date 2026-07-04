// RagStore.swift — персистентность RAG на диск (по образцу ChatStore/MemoryStore).
//
// Хранилище ОТДЕЛЬНОЕ от chats.json и НЕ участвует в дебаунс-автосохранении $chats:
// векторы тяжёлые и коммитятся атомарно после долгой индексации, а не через дебаунс.
//
//   ~/Library/Application Support/ManagerAssistant/rag/
//     ├── rag-indexes.json        — реестр индексов (метаданные+конфиг; БЕЗ векторов)
//     └── <indexID>/
//         ├── chunks.json         — тексты чанков + метаданные (порядок = ordinal)
//         └── vectors.json|flat|sqlite — векторный индекс по выбранному бэкенду
//
// Повреждение файла → *.corrupt.json и пустой результат (как ChatStore) — приложение
// не падает. Флаг RagIndexMeta.isReady ставится ТОЛЬКО после атомарной записи чанков и
// векторов → недостроенный индекс переживает краш как «черновик» и ретривом не берётся.

import Foundation

// MARK: Файловые помощники (file-private, как в MemoryStore)

private func ragAppSupportRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ManagerAssistant", isDirectory: true)
        .appendingPathComponent("rag", isDirectory: true)
}

private func ragLoadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        return nil
    }
}

private func ragSaveJSON<T: Encodable>(_ value: T, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: .atomic)
}

// MARK: - Фабрика бэкендов индекса

enum VectorIndexes {
    static func make(_ backend: IndexBackend) -> VectorIndexStore {
        switch backend {
        case .json:   return JSONVectorIndex()
        case .flat:   return FlatVectorIndex()
        case .sqlite: return SQLiteVectorIndex()
        }
    }
}

// MARK: - Хранилище

enum RagStore {
    static var rootDir: URL { ragAppSupportRoot() }
    static var registryURL: URL { rootDir.appendingPathComponent("rag-indexes.json") }
    static func indexDir(_ id: UUID) -> URL { rootDir.appendingPathComponent(id.uuidString, isDirectory: true) }

    // Реестр индексов (весь список целиком — как ChatStore.load/save).
    static func loadMeta() -> [RagIndexMeta] { ragLoadJSON([RagIndexMeta].self, from: registryURL) ?? [] }
    static func saveMeta(_ metas: [RagIndexMeta]) { ragSaveJSON(metas, to: registryURL) }

    // Чанки одного индекса.
    static func chunksURL(_ id: UUID) -> URL { indexDir(id).appendingPathComponent("chunks.json") }
    static func loadChunks(_ id: UUID) -> [RagChunk] { ragLoadJSON([RagChunk].self, from: chunksURL(id)) ?? [] }
    static func saveChunks(_ chunks: [RagChunk], id: UUID) { ragSaveJSON(chunks, to: chunksURL(id)) }

    // Векторы одного индекса (роутинг по бэкенду).
    static func saveVectors(_ vectors: [[Float]], backend: IndexBackend, id: UUID) throws {
        let dir = indexDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try VectorIndexes.make(backend).save(vectors, to: dir)
    }
    static func loadVectors(backend: IndexBackend, id: UUID) throws -> [[Float]] {
        try VectorIndexes.make(backend).load(from: indexDir(id))
    }

    /// Удаляет весь каталог индекса (чанки + векторы). Реестр правит вызывающий (ViewModel).
    static func deleteIndex(_ id: UUID) {
        try? FileManager.default.removeItem(at: indexDir(id))
    }
}
