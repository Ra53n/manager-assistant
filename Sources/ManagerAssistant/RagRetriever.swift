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

    /// Готовый блок для инъекции в контекст. nil — нечего подставить.
    static func retrieveBlock(indexID: UUID, query: String, topK: Int, budgetTokens: Int) async -> String? {
        let hits = await search(indexID: indexID, query: query, topK: topK)
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
