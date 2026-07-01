// RagPipeline.swift — оркестратор индексации: файлы → чанки → эмбеддинги → индекс.
//
// Пайплайн (по ТЗ): (1) разбиение на чанки → (2) генерация эмбеддингов → (3) сохранение
// индекса. Всё — в `RagIndexer.build`, НЕ на @MainActor (тяжёлая работа в фоне; прогресс
// отдаётся колбэком, который ViewModel маршалит на главный поток).
//
// Краш-устойчивость: meta.isReady возвращается true ТОЛЬКО после атомарной записи чанков
// и векторов. Отмена (Task.cancel) прерывает между батчами эмбеддинга → build бросает
// CancellationError, meta не коммитится, на диске остаётся «черновик» (isReady=false),
// который ретрив игнорирует, а панель предлагает переиндексировать.

import Foundation
import NaturalLanguage

/// Этап индексации (для прогресс-бара).
enum IndexPhase: Equatable, Sendable {
    case enumerating
    case chunking
    case embedding(done: Int, total: Int)
    case saving
    case done

    var title: String {
        switch self {
        case .enumerating: return "Поиск файлов"
        case .chunking:    return "Разбиение на чанки"
        case .embedding(let d, let t): return "Эмбеддинги \(d)/\(t)"
        case .saving:      return "Сохранение индекса"
        case .done:        return "Готово"
        }
    }
}

/// Снимок прогресса индексации.
struct IndexProgress: Equatable, Sendable {
    var phase: IndexPhase = .enumerating
    var currentFile: String = ""
    var fraction: Double = 0     // 0…1
}

/// Ошибки индексации (понятные для UI).
enum IndexingError: LocalizedError {
    case noFiles
    case noText
    case emptyEmbedding

    var errorDescription: String? {
        switch self {
        case .noFiles:        return "Не найдено файлов для индексации (проверьте расширения)."
        case .noText:         return "В выбранных файлах нет текста для индексации."
        case .emptyEmbedding: return "Эмбеддер вернул пустой результат."
        }
    }
}

enum RagIndexer {
    /// Размер батча эмбеддинга (для Ollama — один HTTP-запрос на батч).
    private static let embedBatch = 16

    /// Строит индекс по meta. Возвращает обновлённую meta (isReady=true, dimension,
    /// chunkCount, …). Бросает CancellationError при отмене и *Error при сбоях.
    static func build(meta input: RagIndexMeta,
                      progress: @escaping @Sendable (IndexProgress) -> Void) async throws -> RagIndexMeta {
        var meta = input
        let config = meta.config

        // 1. Перечисление файлов -------------------------------------------------
        progress(IndexProgress(phase: .enumerating, fraction: 0.02))
        let files = enumerateFiles(source: meta.source, extensions: config.fileExtensions)
        guard !files.isEmpty else { throw IndexingError.noFiles }

        // 2. Чтение + чанкинг -----------------------------------------------------
        let chunker = Chunkers.make(config)
        var chunks: [RagChunk] = []
        for (i, url) in files.enumerated() {
            try Task.checkCancellation()
            progress(IndexProgress(phase: .chunking, currentFile: url.lastPathComponent,
                                   fraction: 0.05 + 0.10 * Double(i) / Double(files.count)))
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var base = RagChunkMetadata()
            base.source = meta.name
            base.filePath = url.path
            base.title = documentTitle(text: text, url: url)
            chunks.append(contentsOf: chunker.chunk(text: text, baseMetadata: base))
        }
        guard !chunks.isEmpty else { throw IndexingError.noText }
        // Глобальный ordinal = позиция в индексе (связь с матрицей векторов).
        for i in chunks.indices { chunks[i].ordinal = i }

        // 3. Эмбеддинги (батчами, последовательно — без гонок Sendable) -----------
        let language = resolveLanguage(config: config, chunks: chunks)
        meta.embedLanguage = (config.embedder == .local) ? language.rawValue : ""
        let embedder = Embedders.make(config, language: language)

        var vectors: [[Float]] = []
        vectors.reserveCapacity(chunks.count)
        var done = 0
        while done < chunks.count {
            try Task.checkCancellation()
            let end = min(done + embedBatch, chunks.count)
            let batchTexts = chunks[done..<end].map { $0.text }
            let batchVectors = try await embedder.embed(batchTexts)
            guard batchVectors.count == batchTexts.count else { throw IndexingError.emptyEmbedding }
            vectors.append(contentsOf: batchVectors)
            done = end
            progress(IndexProgress(phase: .embedding(done: done, total: chunks.count),
                                   fraction: 0.15 + 0.75 * Double(done) / Double(chunks.count)))
        }
        let dimension = vectors.first?.count ?? 0
        guard dimension > 0 else { throw IndexingError.emptyEmbedding }

        // 4. Сохранение (атомарно) → коммит --------------------------------------
        try Task.checkCancellation()
        progress(IndexProgress(phase: .saving, fraction: 0.95))
        try RagStore.saveVectors(vectors, backend: config.backend, id: meta.id)
        RagStore.saveChunks(chunks, id: meta.id)

        meta.chunkCount = chunks.count
        meta.dimension = dimension
        meta.source.fileCount = files.count
        meta.updatedAt = Date()
        meta.isReady = true

        progress(IndexProgress(phase: .done, fraction: 1.0))
        return meta
    }

    // MARK: Вспомогательное

    /// Перечисляет файлы источника: папка → все подходящие по расширению (рекурсивно,
    /// без скрытых); файл → он сам. Сортировка — для детерминизма.
    static func enumerateFiles(source: RagSource, extensions: [String]) -> [URL] {
        let exts = Set(extensions.map { $0.lowercased() })
        let root = URL(fileURLWithPath: source.rootPath)
        guard source.isDirectory else {
            // Одиночный файл индексируем как есть (пользователь выбрал его явно, расширение не проверяем).
            return FileManager.default.fileExists(atPath: root.path) ? [root] : []
        }
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            if exts.isEmpty || exts.contains(url.pathExtension.lowercased()) { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Заголовок документа: первый Markdown-#H1, иначе имя файла без расширения.
    private static func documentTitle(text: String, url: URL) -> String {
        for line in text.components(separatedBy: "\n").prefix(20) {
            if let title = StructureChunker.headingTitle(line), !title.isEmpty { return title }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Язык для локального эмбеддера (Apple NL) — по образцу текста первых чанков.
    private static func resolveLanguage(config: RagIndexConfig, chunks: [RagChunk]) -> NLLanguage {
        guard config.embedder == .local else { return .english }
        let sample = chunks.prefix(5).map { $0.text }.joined(separator: " ")
        return RagLanguage.detect(sample)
    }
}
