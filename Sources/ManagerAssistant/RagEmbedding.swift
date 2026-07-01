// RagEmbedding.swift — эмбеддеры RAG и векторная математика.
//
// Эмбеддер превращает текст в вектор чисел; близость векторов ≈ смысловая близость
// текстов. Здесь три реализации одного протокола `Embedder` (источник выбирается на
// индекс в редакторе), плюс утилиты `Vector` (cosine/L2/normalize):
//
//   • OllamaEmbedder  — локальный сервер Ollama (http://localhost:11434). Лучшее
//                       качество; нужен запущенный `ollama serve` и стянутая модель
//                       (`ollama pull nomic-embed-text`). Полностью локально, без облака.
//   • NLLocalEmbedder — on-device Apple NaturalLanguage (усреднение word-векторов).
//                       Офлайн, без сервера; качество ниже трансформерных эмбеддингов.
//                       Если модель языка недоступна — прозрачный фолбэк на hashing.
//   • HashingEmbedder — детерминированный bag-of-words хеш. Без зависимостей и сети,
//                       воспроизводим → используется в юнит-тестах и как последний фолбэк.
//   • RemoteEmbedder  — шов под внешний OpenAI-совместимый /embeddings (НЕ реализован).
//
// Протокол `embed` — async (Ollama ходит по сети; локальные считают синхронно, но
// подходят под ту же сигнатуру). Размерность у Ollama заранее неизвестна (0) —
// реальную берём из первого ответа в пайплайне (см. RagPipeline).

import Foundation
import NaturalLanguage

// MARK: - Векторная математика

/// Утилиты над плотными векторами Float. Поиск top-K — brute-force (для локального
/// корпуса в сотни–тысячи чанков это миллисекунды; та же семантика, что FAISS Flat).
enum Vector {
    /// Скалярное произведение (длины должны совпадать; иначе по минимальной).
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        var i = 0
        while i < n { s += a[i] * b[i]; i += 1 }
        return s
    }

    /// Евклидова норма.
    static func norm(_ a: [Float]) -> Float { sqrt(dot(a, a)) }

    /// L2-нормализация (нулевой вектор остаётся нулевым).
    static func normalize(_ a: [Float]) -> [Float] {
        let n = norm(a)
        guard n > 0 else { return a }
        return a.map { $0 / n }
    }

    /// Косинусная близость в [-1, 1] (1 — сонаправлены, 0 — ортогональны).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let na = norm(a), nb = norm(b)
        guard na > 0, nb > 0 else { return 0 }
        return dot(a, b) / (na * nb)
    }

    /// Квадрат евклидова расстояния L2 (как FAISS IndexFlatL2; без sqrt — дешевле и
    /// порядок тот же).
    static func l2Squared(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var s: Float = 0
        var i = 0
        while i < n { let d = a[i] - b[i]; s += d * d; i += 1 }
        return s
    }

    /// top-K индексов матрицы, ближайших к запросу по косинусной близости (desc).
    static func topK(query: [Float], matrix: [[Float]], k: Int) -> [(index: Int, score: Float)] {
        guard k > 0, !matrix.isEmpty else { return [] }
        let scored = matrix.enumerated().map { (idx, v) in (index: idx, score: cosine(query, v)) }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }
}

// MARK: - Протокол эмбеддера

/// Ошибки эмбеддинга (понятные для UI).
enum EmbeddingError: LocalizedError {
    case ollamaUnavailable(String)
    case badResponse(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .ollamaUnavailable(let s): return "Ollama недоступна: \(s)"
        case .badResponse(let s):       return "Некорректный ответ эмбеддера: \(s)"
        case .empty:                    return "Пустой запрос на эмбеддинг"
        }
    }
}

/// Превращает пакет текстов в пакет векторов (порядок сохраняется).
protocol Embedder {
    /// Ожидаемая размерность вектора. 0 — неизвестна до первого вызова (Ollama):
    /// реальную размерность пайплайн берёт из фактических векторов.
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder {
    /// Удобный ретрив одного вектора.
    func embedOne(_ text: String) async throws -> [Float] {
        let v = try await embed([text])
        guard let first = v.first else { throw EmbeddingError.empty }
        return first
    }
}

/// Простая токенизация для bag-of-words: слова из букв/цифр, в нижнем регистре.
enum RagTokenizer {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - HashingEmbedder (детерминированный, без зависимостей)

/// Bag-of-words со знаковым хешированием (feature hashing). Каждый токен FNV-1a-хешем
/// раскладывается в бакет фиксированной размерности со знаком ±1, частоты суммируются,
/// вектор L2-нормализуется. Полностью детерминирован (одинаковый текст → одинаковый
/// вектор) — поэтому им покрыты юнит-тесты, и он же — последний офлайн-фолбэк.
struct HashingEmbedder: Embedder {
    let dimension: Int
    init(dimension: Int = 256) { self.dimension = max(8, dimension) }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vector(for: $0) }
    }

    func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for token in RagTokenizer.tokens(text) {
            let h = Self.fnv1a(token)
            let bucket = Int(h % UInt64(dimension))
            let sign: Float = (h & 1) == 0 ? 1 : -1   // знак из младшего бита — снижает смещение
            v[bucket] += sign
        }
        return Vector.normalize(v)
    }

    /// FNV-1a 64-bit — быстрый детерминированный хеш строки (без Hasher, у которого
    /// сид рандомизируется между запусками).
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: - NLLocalEmbedder (Apple NaturalLanguage, офлайн)

/// Локальный офлайн-эмбеддер: усредняет word-векторы `NLEmbedding` по словам текста.
/// Размерность фиксируется языком модели (поэтому язык выбирается ОДИН на индекс —
/// см. RagLanguage.detect — и сохраняется в meta, чтобы ретрив взял ту же модель).
/// Если модель языка недоступна — целиком делегирует hashing-фолбэку.
struct NLLocalEmbedder: Embedder {
    private let embedding: NLEmbedding?
    private let fallback: HashingEmbedder

    /// language — язык, под который грузим word-модель (обычно результат RagLanguage.detect).
    init(language: NLLanguage, fallbackDimension: Int = 256) {
        self.embedding = NLEmbedding.wordEmbedding(for: language)
        self.fallback = HashingEmbedder(dimension: fallbackDimension)
    }

    var dimension: Int { embedding?.dimension ?? fallback.dimension }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let embedding else { return try await fallback.embed(texts) }
        return texts.map { vector(for: $0, embedding: embedding) }
    }

    private func vector(for text: String, embedding: NLEmbedding) -> [Float] {
        var acc = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        for token in RagTokenizer.tokens(text) {
            guard let vec = embedding.vector(for: token) else { continue }
            for i in 0..<min(acc.count, vec.count) { acc[i] += vec[i] }
            count += 1
        }
        guard count > 0 else { return [Float](repeating: 0, count: embedding.dimension) }
        let avg = acc.map { Float($0 / Double(count)) }
        return Vector.normalize(avg)
    }
}

/// Определение языка выборки текста для локального эмбеддера.
enum RagLanguage {
    /// Доминирующий язык образца; при неудаче — английский (у него точно есть модель).
    static func detect(_ sample: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage ?? .english
    }
}

// MARK: - OllamaEmbedder (локальный сервер)

/// Эмбеддер поверх локального Ollama. Батч через POST /api/embed; при отсутствии
/// (старые сборки) — фолбэк на пошаговый /api/embeddings. Health — GET /api/tags.
struct OllamaEmbedder: Embedder {
    let baseURL: URL
    let model: String
    /// Размерность неизвестна до первого ответа сервера.
    let dimension: Int = 0

    init(baseURL: String, model: String) {
        // Нормализуем адрес: убираем хвостовой слэш.
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
            ?? URL(string: "http://localhost:11434")!
        self.model = model
    }

    // Запрос/ответ /api/embed (батч).
    private struct EmbedRequest: Encodable { let model: String; let input: [String] }
    private struct EmbedResponse: Decodable { let embeddings: [[Double]]? }
    // Запрос/ответ /api/embeddings (single, legacy).
    private struct LegacyRequest: Encodable { let model: String; let prompt: String }
    private struct LegacyResponse: Decodable { let embedding: [Double]? }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        // 1) Пытаемся батчевый /api/embed.
        if let batched = try await embedBatch(texts) { return batched }
        // 2) Фолбэк: пошагово /api/embeddings.
        var out: [[Float]] = []
        for t in texts { out.append(try await embedLegacy(t)) }
        return out
    }

    /// Возвращает nil, если эндпоинт недоступен (404/400) — тогда идём в legacy.
    private func embedBatch(_ texts: [String]) async throws -> [[Float]]? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(EmbedRequest(model: model, input: texts))
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw EmbeddingError.ollamaUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.badResponse("нет HTTP-ответа")
        }
        if http.statusCode == 404 || http.statusCode == 400 { return nil }  // старый Ollama → legacy
        guard (200...299).contains(http.statusCode) else {
            throw EmbeddingError.badResponse("HTTP \(http.statusCode): \(Self.message(data))")
        }
        guard let decoded = try? JSONDecoder().decode(EmbedResponse.self, from: data),
              let embeddings = decoded.embeddings else {
            return nil
        }
        return embeddings.map { $0.map(Float.init) }
    }

    private func embedLegacy(_ text: String) async throws -> [Float] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/embeddings"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LegacyRequest(model: model, prompt: text))
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw EmbeddingError.ollamaUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EmbeddingError.badResponse("HTTP \(code): \(Self.message(data))")
        }
        guard let decoded = try? JSONDecoder().decode(LegacyResponse.self, from: data),
              let embedding = decoded.embedding else {
            throw EmbeddingError.badResponse("нет поля embedding")
        }
        return embedding.map(Float.init)
    }

    private static func message(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.prefix(200).description ?? "неизвестная ошибка"
    }

    /// Доступен ли сервер Ollama по этому адресу (GET /api/tags вернул 200).
    static func isAvailable(baseURL: String) async -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }
}

// MARK: - RemoteEmbedder (шов, НЕ реализован)

/// Задел под внешний OpenAI-совместимый /embeddings. Ни DeepSeek, ни OpenRouter его
/// не предоставляют — потребуется отдельный провайдер/ключ, поэтому в приложении не
/// реализовано (см. компромиссы в плане). Метод бросает понятную ошибку.
struct RemoteEmbedder: Embedder {
    let dimension: Int = 0
    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw EmbeddingError.badResponse("Внешний эмбеддер не настроен (используйте Ollama или локальный)")
    }
}

// MARK: - Фабрика эмбеддеров

enum Embedders {
    /// Создаёт эмбеддер по конфигу индекса. `language` — язык для .local (обычно из
    /// meta.embedLanguage при ретриве или RagLanguage.detect при индексации).
    static func make(_ config: RagIndexConfig, language: NLLanguage? = nil) -> Embedder {
        switch config.embedder {
        case .ollama:
            return OllamaEmbedder(baseURL: config.ollamaBaseURL, model: config.embedModel)
        case .local:
            return NLLocalEmbedder(language: language ?? .english)
        case .hashing:
            return HashingEmbedder()
        case .remote:
            return RemoteEmbedder()
        }
    }
}
