// RagTests — юнит-тесты чистой логики локального RAG: стратегии чанкинга, векторная
// математика/детерминированный эмбеддер, поиск top-K, round-trip каждого бэкенда индекса
// (JSON/flat/SQLite) и миграционная устойчивость Codable-моделей. Всё офлайн и
// детерминировано (эмбеддер — HashingEmbedder; сеть/Ollama/NaturalLanguage не трогаем).

import XCTest
@testable import ManagerAssistant

final class RagTests: XCTestCase {

    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    // MARK: - FixedSizeChunker

    func testFixedShortTextSingleChunk() {
        let chunks = FixedSizeChunker(size: 100, overlap: 20).chunk(text: "короткий текст", baseMetadata: .init())
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.text, "короткий текст")
        XCTAssertEqual(chunks.first?.ordinal, 0)
    }

    func testFixedOverlapAndOrdinals() {
        let text = String("abcdefghijklmnopqrstuvwxy")   // 25 символов
        let size = 10, overlap = 3
        let chunks = FixedSizeChunker(size: size, overlap: overlap).chunk(text: text, baseMetadata: .init())
        XCTAssertGreaterThan(chunks.count, 1)
        // Каждый чанк не длиннее size; ordinal последователен с нуля.
        for (i, c) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(c.text.count, size)
            XCTAssertEqual(c.ordinal, i)
        }
        // Шаг = size - overlap, соседние окна перекрываются на overlap.
        XCTAssertEqual(chunks[1].startOffset, chunks[0].startOffset + (size - overlap))
        XCTAssertEqual(chunks[0].endOffset - chunks[1].startOffset, overlap)
    }

    func testFixedPropagatesMetadata() {
        var base = RagChunkMetadata(); base.source = "S"; base.filePath = "/f.md"; base.title = "T"
        let chunks = FixedSizeChunker(size: 5, overlap: 0).chunk(text: "abcdefghij", baseMetadata: base)
        XCTAssertTrue(chunks.allSatisfy { $0.metadata.source == "S" && $0.metadata.filePath == "/f.md" && $0.metadata.title == "T" })
    }

    func testFixedOverlapClampedBelowSize() {
        // overlap >= size не должен зациклить (шаг ≥ 1); просто отдаём чанки.
        let chunks = FixedSizeChunker(size: 5, overlap: 999).chunk(text: "abcdefghijkl", baseMetadata: .init())
        XCTAssertFalse(chunks.isEmpty)
    }

    // MARK: - StructureChunker

    func testStructureSplitsByHeadings() {
        let text = "# Заголовок A\nтекст а\n\n## Заголовок B\nтекст б"
        let chunks = StructureChunker().chunk(text: text, baseMetadata: .init())
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].metadata.section, "Заголовок A")
        XCTAssertEqual(chunks[1].metadata.section, "Заголовок B")
        XCTAssertTrue(chunks[0].text.contains("текст а"))
        XCTAssertTrue(chunks[1].text.contains("текст б"))
    }

    func testStructureNoHeadingsSingleChunk() {
        let chunks = StructureChunker().chunk(text: "просто текст без заголовков", baseMetadata: .init())
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].metadata.section, "")
    }

    func testStructurePreambleBeforeFirstHeading() {
        let text = "вводный абзац\n# Раздел\nтело"
        let chunks = StructureChunker().chunk(text: text, baseMetadata: .init())
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].metadata.section, "")           // преамбула
        XCTAssertEqual(chunks[1].metadata.section, "Раздел")
    }

    func testStructureSecondarySplitOfLongSection() {
        let body = String(repeating: "слово ", count: 400)     // ~2400 символов
        let text = "# Большой\n" + body
        let chunks = StructureChunker(maxSectionChars: 300).chunk(text: text, baseMetadata: .init())
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.metadata.section == "Большой" })
        XCTAssertEqual(chunks.map { $0.ordinal }, Array(0..<chunks.count))
    }

    func testHeadingDetection() {
        XCTAssertEqual(StructureChunker.headingTitle("## Раздел"), "Раздел")
        XCTAssertNil(StructureChunker.headingTitle("нет заголовка"))
        XCTAssertNil(StructureChunker.headingTitle("#безпробела"))
    }

    // MARK: - Vector / HashingEmbedder

    func testCosine() {
        XCTAssertEqual(Vector.cosine([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-5)
        XCTAssertEqual(Vector.cosine([1, 0, 0], [0, 1, 0]), 0, accuracy: 1e-5)
    }

    func testNormalizeUnitLength() {
        let n = Vector.norm(Vector.normalize([3, 4]))
        XCTAssertEqual(n, 1, accuracy: 1e-5)
        XCTAssertEqual(Vector.normalize([0, 0]), [0, 0])   // нулевой остаётся нулевым
    }

    func testHashingDeterministicAndNormalized() async throws {
        let emb = HashingEmbedder(dimension: 64)
        let a = try await emb.embedOne("детерминированный текст")
        let b = try await emb.embedOne("детерминированный текст")
        XCTAssertEqual(a, b)                                    // одинаковый текст → одинаковый вектор
        XCTAssertEqual(emb.dimension, 64)
        XCTAssertEqual(Vector.norm(a), 1, accuracy: 1e-4)      // L2-нормализован
        let c = try await emb.embedOne("совершенно другой набор слов")
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Поиск top-K

    func testTopKPicksRelevantDocument() async throws {
        let emb = HashingEmbedder(dimension: 256)
        let docs = ["кошки любят молоко рыбу мурлыкать",
                    "автомобили едут по дороге двигатель колёса"]
        let vectors = try await emb.embed(docs)
        let query = try await emb.embedOne("что любят кошки")
        let hits = Vector.topK(query: query, matrix: vectors, k: 1)
        XCTAssertEqual(hits.first?.index, 0)                   // релевантнее «кошачий» документ
    }

    func testTopKRespectsK() async throws {
        let emb = HashingEmbedder(dimension: 32)
        let vectors = try await emb.embed(["a b", "c d", "e f", "g h"])
        let q = try await emb.embedOne("a")
        XCTAssertEqual(Vector.topK(query: q, matrix: vectors, k: 2).count, 2)
        XCTAssertEqual(Vector.topK(query: q, matrix: vectors, k: 10).count, 4)  // не больше, чем есть
    }

    // MARK: - Бэкенды индекса (round-trip в temp-каталоге)

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rag-test-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func roundTrip(_ store: VectorIndexStore) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vectors: [[Float]] = [[0.1, 0.2, 0.3, 0.4], [-1, 0, 1, 2], [5, 5, 5, 5]]
        try store.save(vectors, to: dir)
        let back = try store.load(from: dir)
        XCTAssertEqual(back.count, vectors.count)
        for (a, b) in zip(back, vectors) {
            XCTAssertEqual(a.count, b.count)
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-6) }
        }
    }

    func testJSONBackendRoundTrip() throws { try roundTrip(JSONVectorIndex()) }
    func testFlatBackendRoundTrip() throws { try roundTrip(FlatVectorIndex()) }
    func testSQLiteBackendRoundTrip() throws { try roundTrip(SQLiteVectorIndex()) }

    func testFlatBinaryHeaderMagic() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FlatVectorIndex().save([[1, 2], [3, 4]], to: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("vectors.flat"))
        XCTAssertEqual(Array(data.prefix(4)), Array("RAGF".utf8))   // сигнатура формата
    }

    func testVectorIndexesFactory() {
        XCTAssertEqual(VectorIndexes.make(.json).backend, .json)
        XCTAssertEqual(VectorIndexes.make(.flat).backend, .flat)
        XCTAssertEqual(VectorIndexes.make(.sqlite).backend, .sqlite)
    }

    // MARK: - Миграция Codable (новые поля + старый JSON + неизвестные enum)

    func testRagIndexMetaRoundTrip() throws {
        var meta = RagIndexMeta()
        meta.name = "База"
        meta.config.chunking = .fixed
        meta.config.backend = .sqlite
        meta.config.embedder = .ollama
        meta.chunkCount = 42
        meta.dimension = 768
        meta.isReady = true
        let back = try dec.decode(RagIndexMeta.self, from: enc.encode(meta))
        XCTAssertEqual(back.name, "База")
        XCTAssertEqual(back.config.chunking, .fixed)
        XCTAssertEqual(back.config.backend, .sqlite)
        XCTAssertEqual(back.chunkCount, 42)
        XCTAssertEqual(back.dimension, 768)
        XCTAssertTrue(back.isReady)
    }

    func testRagIndexMetaOldJSONGetsDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"старый индекс"}"#
        let meta = try dec.decode(RagIndexMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.name, "старый индекс")
        XCTAssertEqual(meta.config.backend, .json)          // дефолт конфига
        XCTAssertEqual(meta.config.chunking, .structure)
        XCTAssertEqual(meta.chunkCount, 0)
        XCTAssertFalse(meta.isReady)
    }

    func testRagChunkOldJSONGetsDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","text":"кусок"}"#
        let chunk = try dec.decode(RagChunk.self, from: Data(json.utf8))
        XCTAssertEqual(chunk.text, "кусок")
        XCTAssertEqual(chunk.ordinal, 0)
        XCTAssertEqual(chunk.metadata.section, "")
    }

    func testEnumsDecodeLeniently() throws {
        XCTAssertEqual(try dec.decode(ChunkingKind.self, from: Data("\"weird\"".utf8)), .structure)
        XCTAssertEqual(try dec.decode(IndexBackend.self, from: Data("\"weird\"".utf8)), .json)
        XCTAssertEqual(try dec.decode(EmbedderKind.self, from: Data("\"weird\"".utf8)), .local)
    }

    // MARK: - GenerationSettings: поля RAG

    func testGenerationSettingsRagRoundTrip() throws {
        var s = GenerationSettings()
        s.ragEnabled = true
        let id = UUID()
        s.ragIndexID = id
        s.ragTopK = 8
        s.ragCandidateK = 30
        s.ragMinScore = 0.45
        s.ragRerankEnabled = true
        s.ragQueryRewrite = false
        let back = try dec.decode(GenerationSettings.self, from: enc.encode(s))
        XCTAssertTrue(back.ragEnabled)
        XCTAssertEqual(back.ragIndexID, id)
        XCTAssertEqual(back.ragTopK, 8)
        XCTAssertEqual(back.ragCandidateK, 30)
        XCTAssertEqual(back.ragMinScore, 0.45, accuracy: 1e-9)
        XCTAssertTrue(back.ragRerankEnabled)
        XCTAssertFalse(back.ragQueryRewrite)
    }

    func testGenerationSettingsOldJSONRagDefaults() throws {
        // Старые настройки без RAG-полей → дефолты (выкл, индекс не выбран, top-K = 4;
        // 2-й этап: 20 кандидатов, порог выкл, реранк выкл, rewrite ВКЛ).
        let json = #"{"provider":"deepseek","model":"deepseek-chat"}"#
        let s = try dec.decode(GenerationSettings.self, from: Data(json.utf8))
        XCTAssertFalse(s.ragEnabled)
        XCTAssertNil(s.ragIndexID)
        XCTAssertEqual(s.ragTopK, 4)
        XCTAssertEqual(s.ragCandidateK, 20)
        XCTAssertEqual(s.ragMinScore, 0)
        XCTAssertFalse(s.ragRerankEnabled)
        XCTAssertTrue(s.ragQueryRewrite)
    }

    // MARK: - Второй этап: порог релевантности / LLM-реранк / query rewrite (RagRerank)

    private func hit(_ text: String, _ score: Float) -> RagRetrievalHit {
        RagRetrievalHit(chunk: RagChunk(text: text), score: score)
    }

    func testThresholdFilterDropsBelowAndKeepsOrder() {
        let hits = [hit("a", 0.9), hit("b", 0.5), hit("c", 0.39), hit("d", 0.7)]
        let out = RagRerank.thresholdFilter(hits, minScore: 0.4)
        XCTAssertEqual(out.map(\.chunk.text), ["a", "b", "d"])
    }

    func testThresholdFilterZeroIsOff() {
        let hits = [hit("a", -0.2), hit("b", 0.1)]
        XCTAssertEqual(RagRerank.thresholdFilter(hits, minScore: 0), hits)
    }

    func testThresholdFilterCanDropAll() {
        let hits = [hit("a", 0.1), hit("b", 0.2)]
        XCTAssertTrue(RagRerank.thresholdFilter(hits, minScore: 0.5).isEmpty)
    }

    func testRerankParserValidCSV() {
        XCTAssertEqual(RagRerank.parseRerankIndices("3,1,5", candidateCount: 5), [2, 0, 4])
    }

    func testRerankParserToleratesGarbage() {
        // Мусор вокруг чисел, дубликаты, out-of-range → дедуп + отброс лишнего.
        let out = RagRerank.parseRerankIndices("Подходят фрагменты: 2, 2 и 99, ещё 1.", candidateCount: 3)
        XCTAssertEqual(out, [1, 0])
    }

    func testRerankParserExplicitZeroMeansNone() {
        XCTAssertEqual(RagRerank.parseRerankIndices("0", candidateCount: 4), [])
    }

    func testRerankParserUnparsableIsNil() {
        XCTAssertNil(RagRerank.parseRerankIndices("не могу определить", candidateCount: 4))
        XCTAssertNil(RagRerank.parseRerankIndices("", candidateCount: 4))
    }

    func testApplyRerank() {
        let hits = [hit("a", 0.9), hit("b", 0.8), hit("c", 0.7)]
        // Явный порядок реранка + обрезка до topK.
        XCTAssertEqual(RagRerank.applyRerank(hits: hits, indices: [2, 0, 1], topK: 2).map(\.chunk.text), ["c", "a"])
        // nil (мусор от модели) → фолбэк: порядок по score.
        XCTAssertEqual(RagRerank.applyRerank(hits: hits, indices: nil, topK: 2).map(\.chunk.text), ["a", "b"])
        // [] («ничего не релевантно») → пусто.
        XCTAssertTrue(RagRerank.applyRerank(hits: hits, indices: [], topK: 2).isEmpty)
    }

    func testRerankPromptNumbersAndTruncates() {
        let long = String(repeating: "х", count: 700)
        let prompt = RagRerank.rerankUserPrompt(query: "вопрос", candidates: ["первый", long], maxChunkChars: 600)
        XCTAssertTrue(prompt.contains("ЗАПРОС: вопрос"))
        XCTAssertTrue(prompt.contains("1) первый"))
        XCTAssertTrue(prompt.contains("2) "))
        XCTAssertFalse(prompt.contains(long))               // усечён
        XCTAssertTrue(prompt.contains(String(long.prefix(600))))
    }

    func testRewriteParserStripsQuotesFirstLine() {
        XCTAssertEqual(RagRerank.parseRewrittenQuery("«бюджет проекта Х»\nпояснение", fallback: "f"),
                       "бюджет проекта Х")
        XCTAssertEqual(RagRerank.parseRewrittenQuery("Запрос: \"лимиты API\"", fallback: "f"), "лимиты API")
    }

    func testRewriteParserEmptyOrOverlongFallsBack() {
        XCTAssertEqual(RagRerank.parseRewrittenQuery("   \n  ", fallback: "исходный"), "исходный")
        let overlong = String(repeating: "a", count: 600)
        XCTAssertEqual(RagRerank.parseRewrittenQuery(overlong, fallback: "исходный"), "исходный")
    }

    func testRewritePromptResolvesHistoryFormat() {
        let history = [ChatMessage(role: .user, content: "расскажи про проект Атлас"),
                       ChatMessage(role: .assistant, content: "Атлас — это…")]
        let prompt = RagRerank.rewriteUserPrompt(question: "а какой у него бюджет?", history: history)
        XCTAssertTrue(prompt.contains("Пользователь: расскажи про проект Атлас"))
        XCTAssertTrue(prompt.contains("Ассистент: Атлас"))
        XCTAssertTrue(prompt.hasSuffix("Вопрос: а какой у него бюджет?"))
        // Без истории — только вопрос.
        XCTAssertEqual(RagRerank.rewriteUserPrompt(question: "q", history: []), "Вопрос: q")
    }

    // MARK: - Grounded-режим: метки источников и директивы

    func testBuildBlockLabelsContainSourceAndChunkID() {
        var chunk = RagChunk(text: "текст фрагмента")
        chunk.ordinal = 12
        chunk.metadata = RagChunkMetadata(title: "Список машин", section: "Lada Niva Sport")
        let block = RagRetriever.buildBlock(hits: [RagRetrievalHit(chunk: chunk, score: 0.8)], budgetTokens: 500)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("[#12 · Список машин · Lada Niva Sport]"))

        // Без раздела и заголовка — метка только с номером чанка, без висячих «·».
        let bare = RagChunk(text: "голый текст")
        let block2 = RagRetriever.buildBlock(hits: [RagRetrievalHit(chunk: bare, score: 0.5)], budgetTokens: 500)
        XCTAssertTrue(block2!.contains("[#0]\nголый текст"))
        XCTAssertFalse(block2!.contains("· ]"))
    }

    func testCitationDirectiveMentionsSourcesFormat() {
        XCTAssertTrue(RagRerank.citationDirective.contains("Источники"))
        XCTAssertTrue(RagRerank.citationDirective.contains("цитата"))
        XCTAssertTrue(RagRerank.citationDirective.contains("ТОЛЬКО на основе фрагментов"))
    }

    func testNotFoundDirectiveDemandsIDontKnow() {
        XCTAssertTrue(RagRerank.notFoundDirective.contains("не знаю"))
        XCTAssertTrue(RagRerank.notFoundDirective.contains("уточняющий вопрос"))
        XCTAssertTrue(RagRerank.notFoundDirective.contains("НЕ отвечать из общих знаний"))
    }

    func testGenerationSettingsStrictModeMigration() throws {
        // Round-trip нового поля + старый JSON без него → строгий режим ВКЛ по умолчанию.
        var s = GenerationSettings()
        s.ragStrictMode = false
        let back = try dec.decode(GenerationSettings.self, from: enc.encode(s))
        XCTAssertFalse(back.ragStrictMode)
        let old = try dec.decode(GenerationSettings.self,
                                 from: Data(#"{"provider":"deepseek"}"#.utf8))
        XCTAssertTrue(old.ragStrictMode)
    }

    func testBuildBlockAfterThreshold() {
        let filtered = RagRerank.thresholdFilter([hit("выживший факт", 0.8), hit("шум", 0.1)], minScore: 0.5)
        let block = RagRetriever.buildBlock(hits: filtered, budgetTokens: 500)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("выживший факт"))
        XCTAssertFalse(block!.contains("шум"))
        XCTAssertNil(RagRetriever.buildBlock(hits: [], budgetTokens: 500))
    }

    // MARK: - Инъекция RAG в промпты FSM

    func testBuildPromptInjectsRagBlock() {
        var ctx = TaskContext(task: "задача", state: .execution)
        ctx.plan = ["шаг 1"]
        let block = "База знаний RAG (используй как контекст):\n[Раздел]\nполезный факт"
        let withRag = PipelinePrompts.buildPrompt(query: "задача", ctx: ctx, profile: "", invariants: [], rag: block)
        XCTAssertTrue(withRag.contains("База знаний RAG"))
        XCTAssertTrue(withRag.contains("полезный факт"))
        let without = PipelinePrompts.buildPrompt(query: "задача", ctx: ctx, profile: "", invariants: [], rag: "")
        XCTAssertFalse(without.contains("База знаний RAG"))
    }

    func testSubAgentPromptInjectsRagBlock() {
        let block = "База знаний RAG: релевантный фрагмент"
        let withRag = PipelinePrompts.subAgentPrompt(task: "T", stepIndex: 0, plan: ["a"],
                                                     deps: [], stepResults: [], profile: "", rag: block)
        XCTAssertTrue(withRag.contains("База знаний RAG"))
        let without = PipelinePrompts.subAgentPrompt(task: "T", stepIndex: 0, plan: ["a"],
                                                     deps: [], stepResults: [], profile: "")
        XCTAssertFalse(without.contains("База знаний RAG"))
    }

    // MARK: - OllamaLauncher (чистые помощники; спавн процесса не трогаем)

    func testOllamaLauncherIsLocal() {
        XCTAssertTrue(OllamaLauncher.isLocal("http://localhost:11434"))
        XCTAssertTrue(OllamaLauncher.isLocal("http://127.0.0.1:11434"))
        XCTAssertFalse(OllamaLauncher.isLocal("http://ollama.mysever.com:11434"))
        XCTAssertFalse(OllamaLauncher.isLocal("http://192.168.1.50:11434"))
    }

    func testOllamaLauncherHostPort() {
        XCTAssertEqual(OllamaLauncher.hostPort("http://localhost:11434"), "localhost:11434")
        XCTAssertEqual(OllamaLauncher.hostPort("http://127.0.0.1:11500"), "127.0.0.1:11500")
        // Без порта — дефолт 11434.
        XCTAssertEqual(OllamaLauncher.hostPort("http://127.0.0.1"), "127.0.0.1:11434")
    }

    // MARK: - End-to-end пайплайн (реальный RagIndexer.build → чтение обратно)

    /// Прогоняет весь пайплайн офлайн (эмбеддер .hashing): временная папка с двумя .md →
    /// enumerate → chunk → embed → save → загрузка чанков/векторов → поиск top-K. Пишет
    /// в rag/<uuid>/ и сам за собой убирает (реестр rag-indexes.json НЕ трогает).
    func testEndToEndPipelineHashing() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Кошки\nКошки любят молоко рыбу и мурлыкать дома."
            .write(to: dir.appendingPathComponent("cats.md"), atomically: true, encoding: .utf8)
        try "# Машины\nМашины ездят по дороге, у них двигатель и колёса."
            .write(to: dir.appendingPathComponent("cars.md"), atomically: true, encoding: .utf8)

        var meta = RagIndexMeta()
        meta.name = "e2e"
        meta.source = RagSource(rootPath: dir.path, isDirectory: true, fileCount: 0)
        meta.config.embedder = .hashing          // офлайн, детерминированно
        meta.config.backend = .json
        meta.config.chunking = .structure

        let built = try await RagIndexer.build(meta: meta) { _ in }
        defer { RagStore.deleteIndex(built.id) }

        XCTAssertTrue(built.isReady)
        XCTAssertGreaterThan(built.chunkCount, 0)
        XCTAssertGreaterThan(built.dimension, 0)
        XCTAssertEqual(built.source.fileCount, 2)

        // Читаем сохранённое обратно и проверяем поиск.
        let chunks = RagStore.loadChunks(built.id)
        let vectors = try RagStore.loadVectors(backend: .json, id: built.id)
        XCTAssertEqual(chunks.count, built.chunkCount)
        XCTAssertEqual(vectors.count, built.chunkCount)

        let emb = HashingEmbedder()
        let q = try await emb.embedOne("что любят кошки")
        let hits = Vector.topK(query: q, matrix: vectors, k: 1)
        let top = try XCTUnwrap(hits.first)
        // Лучший чанк — из «кошачьего» файла.
        XCTAssertTrue(chunks[top.index].metadata.filePath.hasSuffix("cats.md"))
    }
}
