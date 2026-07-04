// RagRetriever.swift — ретрив: вопрос → релевантные чанки → блок под токенный бюджет.
//
// Используется двояко:
//   • в чате (ChatViewModel.send) — retrieveBlock даёт готовый текстовый блок, который
//     дописывается к «памяти» и уходит в системный промпт (модель видит его как контекст);
//   • в панели RAG — search даёт список попаданий со score для «тестового поиска».
//
// Устойчивость: любая ошибка (индекс не готов, размерность не совпала, Ollama недоступна,
// битый файл) → пустой результат / nil, а НЕ исключение. Это гарантирует, что включённый
// RAG никогда не ломает отправку сообщения — в худшем случае просто ничего не подставит.
//
// Бюджет: блок ограничен budgetTokens (оценка ~3 символа/токен, как MemoryContext), чтобы
// ретрив не вытеснял остальную память из контекста. Хотя бы один (лучший) чанк включается
// всегда.

import Foundation
import NaturalLanguage

/// Одно попадание ретрива: чанк + его близость к запросу.
struct RagRetrievalHit: Equatable {
    let chunk: RagChunk
    let score: Float
}

enum RagRetriever {
    /// Метаданные индекса по id (nil — нет такого).
    static func meta(for id: UUID) -> RagIndexMeta? { RagStore.loadMeta().first { $0.id == id } }

    /// top-K чанков, ближайших к запросу. Пустой массив при любой проблеме.
    static func search(indexID: UUID, query: String, topK: Int) async -> [RagRetrievalHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let meta = meta(for: indexID), meta.isReady, meta.chunkCount > 0 else { return [] }
        do {
            // Ленивый запуск Ollama по требованию (как при индексации). Не поднялась → пусто.
            if meta.config.embedder == .ollama {
                guard await OllamaLauncher.shared.ensureRunning(baseURL: meta.config.ollamaBaseURL) else { return [] }
            }
            let language: NLLanguage? = meta.embedLanguage.isEmpty ? nil : NLLanguage(meta.embedLanguage)
            let embedder = Embedders.make(meta.config, language: language)
            let queryVec = try await embedder.embedOne(q)
            guard !queryVec.isEmpty else { return [] }
            // Размерность запроса должна совпасть с индексом (иначе эмбеддер сменили → переиндексировать).
            if meta.dimension > 0, queryVec.count != meta.dimension { return [] }

            let vectors = try RagStore.loadVectors(backend: meta.config.backend, id: meta.id)
            let chunks = RagStore.loadChunks(meta.id)
            let hits = Vector.topK(query: queryVec, matrix: vectors, k: max(1, topK))
            return hits.compactMap { hit in
                guard hit.index >= 0, hit.index < chunks.count else { return nil }
                return RagRetrievalHit(chunk: chunks[hit.index], score: hit.score)
            }
        } catch {
            return []
        }
    }

    /// Готовый блок для инъекции в контекст (простой путь БЕЗ фильтрации/реранка —
    /// используется тестами и как базис; чат/FSM/сравнение идут через пайплайн ниже).
    /// nil — нечего подставить.
    static func retrieveBlock(indexID: UUID, query: String, topK: Int, budgetTokens: Int) async -> String? {
        let hits = await search(indexID: indexID, query: query, topK: topK)
        return buildBlock(hits: hits, budgetTokens: budgetTokens)
    }

    /// ПОЛНЫЙ пайплайн ретрива со вторым этапом (по ТЗ «День 23»):
    ///   (query rewrite LLM) → поиск top-candidateK → порог similarity → (LLM-реранк) →
    ///   top-K лучших → блок.
    /// Каждый шаг при ошибке ДЕГРАДИРУЕТ к предыдущему результату (rewrite не удался →
    /// ищем по исходному вопросу; реранк вернул мусор → порядок по score) — ретрив
    /// НИКОГДА не бросает и не роняет отправку. Порог/реранк могут осознанно отсеять
    /// всех кандидатов → nil (нерелевантное не подставляем — это фича).
    static func retrieveBlock(client: DeepSeekClient,
                              settings: GenerationSettings,
                              query: String,
                              history: [ChatMessage],
                              budgetTokens: Int) async -> String? {
        guard settings.ragEnabled, let indexID = settings.ragIndexID else { return nil }

        // 1. Query rewrite: вопрос → самодостаточный поисковый запрос (местоимения
        //    раскрываются по последним репликам). Ошибка/мусор → исходный вопрос.
        var searchQuery = query
        if settings.ragQueryRewrite {
            if let raw = try? await client.rewriteRagQuery(question: query, history: history, settings: settings) {
                searchQuery = RagRerank.parseRewrittenQuery(raw.text, fallback: query)
            }
        }

        // 2. Кандидаты: широкий top-candidateK (до фильтрации), не уже финального top-K.
        let candidateK = max(settings.ragCandidateK, settings.ragTopK)
        var hits = await search(indexID: indexID, query: searchQuery, topK: candidateK)
        guard !hits.isEmpty else { return nil }

        // 3. Порог релевантности (бесплатная эвристика). Отсёк всех → блока нет.
        hits = RagRerank.thresholdFilter(hits, minScore: settings.ragMinScore)
        guard !hits.isEmpty else { return nil }

        // 4. LLM-реранк (аналог cross-encoder). Зовём только когда есть что резать.
        if settings.ragRerankEnabled, hits.count > settings.ragTopK {
            let raw = try? await client.rerankChunks(query: searchQuery,
                                                     candidates: hits.map { $0.chunk.text },
                                                     settings: settings)
            let indices = raw.flatMap { RagRerank.parseRerankIndices($0.text, candidateCount: hits.count) }
            hits = RagRerank.applyRerank(hits: hits, indices: indices, topK: settings.ragTopK)
        } else {
            hits = Array(hits.prefix(settings.ragTopK))
        }

        return buildBlock(hits: hits, budgetTokens: budgetTokens)
    }

    /// Сборка текстового блока из попаданий под токенный бюджет (~3 симв./токен).
    /// Хотя бы первый (лучший) чанк включается всегда. nil — попаданий нет / всё пустое.
    static func buildBlock(hits: [RagRetrievalHit], budgetTokens: Int) -> String? {
        guard !hits.isEmpty else { return nil }

        var lines: [String] = []
        var used = 0
        for hit in hits {
            let text = hit.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Метка фрагмента: раздел (если есть) или заголовок документа.
            let label = hit.chunk.metadata.section.isEmpty ? hit.chunk.metadata.title : hit.chunk.metadata.section
            let entry = label.isEmpty ? text : "[\(label)]\n\(text)"
            let cost = max(1, entry.count / 3)
            // Хотя бы первый (лучший) чанк включаем всегда; далее — пока хватает бюджета.
            if used + cost > max(0, budgetTokens), !lines.isEmpty { break }
            lines.append(entry)
            used += cost
        }
        guard !lines.isEmpty else { return nil }
        return "База знаний RAG (используй как контекст для ответа, не упоминай источник):\n"
            + lines.joined(separator: "\n\n")
    }
}
