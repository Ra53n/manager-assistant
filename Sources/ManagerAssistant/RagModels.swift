// RagModels.swift — доменные типы локального RAG (retrieval-augmented generation).
//
// RAG = «база знаний» из выбранных пользователем файлов/папок: их режут на чанки,
// считают эмбеддинги, кладут в векторный индекс, а при вопросе достают релевантные
// куски и подставляют в контекст запроса к LLM.
//
// Здесь только ДАННЫЕ (Codable-модели + перечисления). Логика — в соседних файлах:
//   RagChunking.swift   — стратегии нарезки на чанки (Fixed/Structure)
//   RagEmbedding.swift  — эмбеддеры (Ollama/Apple NL/Hashing) + векторная математика
//   RagVectorIndex.swift/RagSQLiteIndex.swift — форматы хранения индекса (JSON/flat/SQLite)
//   RagStore.swift      — персистентность реестра индексов и чанков на диск
//   RagPipeline.swift   — оркестратор индексации (enumerate→chunk→embed→save)
//   RagRetriever.swift  — ретрив: вопрос → top-K → блок под бюджет
//
// Как и остальные модели проекта, ВСЕ типы — с ручным init(from:) (decodeIfPresent +
// дефолты), а перечисления декодируются снисходительно (неизвестное значение → безопасный
// дефолт). Это защищает файлы индекса от падения при добавлении новых полей/значений
// (см. ловушку миграции в CLAUDE.md).

import Foundation

// MARK: - Перечисления (снисходительный декод: unknown → безопасный дефолт)

/// Стратегия нарезки документа на чанки (пользователь выбирает в редакторе индекса).
enum ChunkingKind: String, Codable, CaseIterable, Identifiable {
    /// По фиксированному размеру: окна по N символов с нахлёстом.
    case fixed
    /// По структуре: границы — Markdown-заголовки/разделы/файлы.
    case structure

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed:     return "По размеру"
        case .structure: return "По структуре"
        }
    }
    /// Неизвестная стратегия из будущей версии → .structure (осмысленный дефолт).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChunkingKind(rawValue: raw) ?? .structure
    }
}

/// Источник эмбеддингов.
enum EmbedderKind: String, Codable, CaseIterable, Identifiable {
    /// Локальный сервер Ollama (лучшее качество; нужен запущенный `ollama serve`).
    case ollama
    /// On-device Apple NaturalLanguage (офлайн, без сервера; качество ниже).
    case local
    /// Детерминированный bag-of-words хеш (без зависимостей; для тестов/последний фолбэк).
    case hashing
    /// Внешний OpenAI-совместимый /embeddings (шов; в приложении не реализован).
    case remote

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ollama:  return "Ollama (локальный сервер)"
        case .local:   return "Локально (Apple NL)"
        case .hashing: return "Хеш (детерминированный)"
        case .remote:  return "Внешний API (недоступно)"
        }
    }
    /// Неизвестный эмбеддер → .local (работает офлайн без сервера).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EmbedderKind(rawValue: raw) ?? .local
    }
}

/// Формат хранения векторного индекса на диске.
enum IndexBackend: String, Codable, CaseIterable, Identifiable {
    /// JSON — как остальные сторы приложения (chats.json/memory.json). Дефолт.
    case json
    /// Плоский бинарный индекс с семантикой FAISS IndexFlatL2 (без внешних зависимостей).
    case flat
    /// SQLite — векторы как Float32 BLOB (нативно, без SwiftPM-зависимости).
    case sqlite

    var id: String { rawValue }
    var title: String {
        switch self {
        case .json:   return "JSON"
        case .flat:   return "Flat (аналог FAISS IndexFlatL2)"
        case .sqlite: return "SQLite"
        }
    }
    /// Неизвестный бэкенд → .json (всегда доступен).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IndexBackend(rawValue: raw) ?? .json
    }
}

// MARK: - Метаданные чанка (ТЗ: source/title/file/section/chunkID + произвольное)

/// Метаданные одного чанка. Поля из ТЗ + свободный словарь `extra` для чего угодно.
struct RagChunkMetadata: Codable, Equatable {
    /// Логический источник (имя индекса / корневой путь).
    var source: String = ""
    /// Заголовок документа (первый #H1 или имя файла).
    var title: String = ""
    /// Абсолютный путь к исходному файлу.
    var filePath: String = ""
    /// Ближайший Markdown-заголовок (раздел), из которого взят чанк.
    var section: String = ""
    /// Произвольные дополнительные пары (страница, язык, тег, …).
    var extra: [String: String] = [:]

    enum CodingKeys: String, CodingKey { case source, title, filePath, section, extra }
}

extension RagChunkMetadata {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RagChunkMetadata()
        source   = try c.decodeIfPresent(String.self, forKey: .source)   ?? d.source
        title    = try c.decodeIfPresent(String.self, forKey: .title)    ?? d.title
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? d.filePath
        section  = try c.decodeIfPresent(String.self, forKey: .section)  ?? d.section
        extra    = try c.decodeIfPresent([String: String].self, forKey: .extra) ?? d.extra
    }
}

// MARK: - Чанк (вектор хранится ОТДЕЛЬНО, в VectorIndexStore, по совпадающему ordinal)

/// Один фрагмент источника. Сам вектор здесь НЕ хранится — он лежит в векторном
/// индексе (rag/<id>/vectors.*) по позиции `ordinal` (порядок = порядок чанков).
struct RagChunk: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Текст чанка (идёт в контекст LLM при ретриве).
    var text: String = ""
    /// Порядковый номер в индексе (0-based) — связь с вектором в матрице.
    var ordinal: Int = 0
    /// Смещения в исходном тексте документа (для отладки/трассировки).
    var startOffset: Int = 0
    var endOffset: Int = 0
    var metadata: RagChunkMetadata = RagChunkMetadata()

    enum CodingKeys: String, CodingKey { case id, text, ordinal, startOffset, endOffset, metadata }
}

extension RagChunk {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RagChunk()
        id          = try c.decodeIfPresent(UUID.self, forKey: .id)          ?? d.id
        text        = try c.decodeIfPresent(String.self, forKey: .text)      ?? d.text
        ordinal     = try c.decodeIfPresent(Int.self, forKey: .ordinal)      ?? d.ordinal
        startOffset = try c.decodeIfPresent(Int.self, forKey: .startOffset)  ?? d.startOffset
        endOffset   = try c.decodeIfPresent(Int.self, forKey: .endOffset)    ?? d.endOffset
        metadata    = try c.decodeIfPresent(RagChunkMetadata.self, forKey: .metadata) ?? d.metadata
    }
}

// MARK: - Источник (что проиндексировали)

/// Что выбрал пользователь: файл или папка (тогда индексируются все файлы внутри).
struct RagSource: Codable, Equatable {
    var rootPath: String = ""
    var isDirectory: Bool = false
    /// Сколько файлов реально обработано (заполняется при индексации).
    var fileCount: Int = 0

    enum CodingKeys: String, CodingKey { case rootPath, isDirectory, fileCount }
}

extension RagSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RagSource()
        rootPath    = try c.decodeIfPresent(String.self, forKey: .rootPath) ?? d.rootPath
        isDirectory = try c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? d.isDirectory
        fileCount   = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? d.fileCount
    }
}

// MARK: - Конфиг индекса (стратегия + бэкенд + эмбеддер + параметры)

/// Параметры одного индекса, выбранные в редакторе. Хранятся вместе с метаданными,
/// чтобы ретрив использовал ТОТ ЖЕ эмбеддер (иначе размерности не сойдутся).
struct RagIndexConfig: Codable, Equatable {
    var chunking: ChunkingKind = .structure
    var backend: IndexBackend = .json
    var embedder: EmbedderKind = .ollama

    /// Размер чанка в символах (для .fixed; для .structure — потолок вторичной нарезки).
    var chunkSize: Int = 1200
    /// Нахлёст соседних чанков в символах (для .fixed).
    var chunkOverlap: Int = 200

    /// Параметры Ollama (эмбеддер .ollama).
    var ollamaBaseURL: String = "http://localhost:11434"
    var embedModel: String = "nomic-embed-text"

    /// Какие расширения файлов индексировать в папке (без точки).
    var fileExtensions: [String] = ["md", "markdown", "txt", "text"]

    /// Границы для UI.
    static let chunkSizeRange = 200...4000
    static let chunkOverlapRange = 0...1000

    enum CodingKeys: String, CodingKey {
        case chunking, backend, embedder, chunkSize, chunkOverlap
        case ollamaBaseURL, embedModel, fileExtensions
    }
}

extension RagIndexConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RagIndexConfig()
        chunking       = try c.decodeIfPresent(ChunkingKind.self, forKey: .chunking) ?? d.chunking
        backend        = try c.decodeIfPresent(IndexBackend.self, forKey: .backend) ?? d.backend
        embedder       = try c.decodeIfPresent(EmbedderKind.self, forKey: .embedder) ?? d.embedder
        chunkSize      = try c.decodeIfPresent(Int.self, forKey: .chunkSize) ?? d.chunkSize
        chunkOverlap   = try c.decodeIfPresent(Int.self, forKey: .chunkOverlap) ?? d.chunkOverlap
        ollamaBaseURL  = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? d.ollamaBaseURL
        embedModel     = try c.decodeIfPresent(String.self, forKey: .embedModel) ?? d.embedModel
        fileExtensions = try c.decodeIfPresent([String].self, forKey: .fileExtensions) ?? d.fileExtensions
    }
}

// MARK: - Метаданные индекса (реестр rag-indexes.json; БЕЗ векторов и чанков)

/// Запись реестра индексов. Сами чанки/векторы лежат в rag/<id>/ (см. RagStore).
struct RagIndexMeta: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var config: RagIndexConfig = RagIndexConfig()
    var source: RagSource = RagSource()

    /// Число чанков и размерность вектора — фиксируются на момент индексации.
    /// Ретрив сверяет размерность запроса с этой (иначе просит переиндексировать).
    var chunkCount: Int = 0
    var dimension: Int = 0
    /// Язык, выбранный для локального эмбеддера (Apple NL) на момент индексации —
    /// чтобы ретрив взял ту же модель и совпал по размерности. Пусто для не-.local.
    var embedLanguage: String = ""

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Индексация завершена и зафиксирована. Пока false — «черновик»: ретрив его НЕ
    /// использует (краш-устойчивость: флаг ставится только после атомарной записи).
    var isReady: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, config, source, chunkCount, dimension, embedLanguage
        case createdAt, updatedAt, isReady
    }
}

extension RagIndexMeta {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RagIndexMeta()
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name          = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        config        = try c.decodeIfPresent(RagIndexConfig.self, forKey: .config) ?? d.config
        source        = try c.decodeIfPresent(RagSource.self, forKey: .source) ?? d.source
        chunkCount    = try c.decodeIfPresent(Int.self, forKey: .chunkCount) ?? d.chunkCount
        dimension     = try c.decodeIfPresent(Int.self, forKey: .dimension) ?? d.dimension
        embedLanguage = try c.decodeIfPresent(String.self, forKey: .embedLanguage) ?? d.embedLanguage
        createdAt     = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
        updatedAt     = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? d.updatedAt
        isReady       = try c.decodeIfPresent(Bool.self, forKey: .isReady) ?? d.isReady
    }
}
