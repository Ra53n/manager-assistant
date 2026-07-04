// RagRerank.swift — чистая логика ВТОРОГО этапа ретрива (после векторного поиска):
// порог релевантности, промпты и парсеры query rewrite / LLM-реранка.
//
// Схема (см. RagRetriever.retrieveBlock(client:...)):
//   вопрос → [rewrite LLM] → поиск top-candidateK → [порог similarity] → [LLM-реранк] →
//   top-K лучших → блок в контекст.
//
// Здесь НЕТ I/O и LLM — только чистые функции (тестируются офлайн в RagTests, как
// парсеры PipelinePrompts). Сами LLM-вызовы — DeepSeekClient.rewriteRagQuery/rerankChunks;
// парсинг их ответов намеренно вынесен сюда.
//
// Устойчивость — парсеры терпят ЛЮБОЙ мусор: непарсибельный ответ реранкера → nil
// (вызывающий падает обратно на порядок по score), кривой rewrite → исходный вопрос.

import Foundation

enum RagRerank {
    // MARK: Порог релевантности (фильтр-эвристика, бесплатный)

    /// Отбрасывает кандидатов с косинусной близостью ниже порога (порядок сохраняется).
    /// minScore <= 0 — фильтр выключен (старое поведение). Может отбросить ВСЕХ —
    /// тогда в контекст ничего не подставляется (это осознанная фича, не баг).
    static func thresholdFilter(_ hits: [RagRetrievalHit], minScore: Double) -> [RagRetrievalHit] {
        guard minScore > 0 else { return hits }
        return hits.filter { Double($0.score) >= minScore }
    }

    // MARK: Query rewrite (переформулировка вопроса в поисковый запрос)

    static let rewriteSystemPrompt = """
    Ты переформулируешь вопрос пользователя в самодостаточный поисковый запрос к базе \
    знаний. Раскрой местоимения и отсылки («он», «эта функция», «там») по недавнему \
    диалогу, сохрани все ключевые термины, имена и числа. Верни ТОЛЬКО текст запроса \
    одной строкой, без кавычек и пояснений.
    """

    /// user-сообщение для rewrite: последние реплики диалога (усечённые) + сам вопрос.
    /// history может быть пустой (FSM) — тогда просто «Вопрос: …».
    static func rewriteUserPrompt(question: String, history: [ChatMessage],
                                  maxTurns: Int = 6, maxTurnChars: Int = 400) -> String {
        var lines: [String] = []
        for msg in history.suffix(maxTurns) {
            let role = msg.role == .user ? "Пользователь" : "Ассистент"
            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(role): \(String(text.prefix(maxTurnChars)))")
        }
        let dialog = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
        return dialog + "Вопрос: \(question)"
    }

    /// Одна строка переписанного запроса. Срезает кавычки/маркдаун/служебные префиксы;
    /// пусто или неправдоподобно длинно → fallback (исходный вопрос). Никогда не бросает.
    static func parseRewrittenQuery(_ text: String, fallback: String, maxChars: Int = 500) -> String {
        guard let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return fallback }
        var q = firstLine
        // Служебный префикс («Запрос: …») — модель иногда добавляет вопреки промпту.
        for prefix in ["Запрос:", "Поисковый запрос:", "Query:"] {
            if q.lowercased().hasPrefix(prefix.lowercased()) {
                q = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Обрамляющие кавычки/бэктики.
        let quotes = CharacterSet(charactersIn: "\"'«»`“”")
        q = q.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count <= maxChars else { return fallback }
        return q
    }

    // MARK: LLM-реранк (аналог cross-encoder: запрос + кандидаты в одном вызове)

    static let rerankSystemPrompt = """
    Ты оцениваешь релевантность фрагментов базы знаний поисковому запросу. Дан ЗАПРОС \
    и пронумерованные ФРАГМЕНТЫ. Выведи номера фрагментов, которые реально помогают \
    ответить на запрос, через запятую в порядке убывания релевантности (например: 3,1,5). \
    Нерелевантные не включай. Если не подходит ни один — выведи ровно 0. Без пояснений.
    """

    /// user-сообщение для реранка: запрос + нумерованные кандидаты 1…N (каждый усечён,
    /// чтобы ограничить токены: 20 кандидатов × 600 симв. ≈ 4k токенов).
    static func rerankUserPrompt(query: String, candidates: [String], maxChunkChars: Int = 600) -> String {
        var out = "ЗАПРОС: \(query)\n\nФРАГМЕНТЫ:\n"
        for (i, text) in candidates.enumerated() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\(i + 1)) \(String(t.prefix(maxChunkChars)))\n"
        }
        return out
    }

    /// Разбор ответа реранкера. Возвращает:
    ///   • nil — ответ не распарсился (мусор) → вызывающий откатывается на порядок по score;
    ///   • []  — модель явно ответила «0» (ни один фрагмент не релевантен → блока не будет);
    ///   • иначе — 0-based индексы по убыванию релевантности: дедуп с сохранением порядка,
    ///     номера вне 1…candidateCount отброшены.
    static func parseRerankIndices(_ text: String, candidateCount: Int) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "0" { return [] }
        var seen = Set<Int>()
        var result: [Int] = []
        for token in trimmed.split(whereSeparator: { !$0.isNumber }) {
            guard let n = Int(token), n >= 1, n <= candidateCount else { continue }
            let idx = n - 1
            if seen.insert(idx).inserted { result.append(idx) }
        }
        return result.isEmpty ? nil : result
    }

    /// Применяет порядок реранка: indices == nil → топ-K по score (фолбэк);
    /// иначе — переупорядочить по indices и взять первые topK (пустые indices → пусто).
    static func applyRerank(hits: [RagRetrievalHit], indices: [Int]?, topK: Int) -> [RagRetrievalHit] {
        guard let indices else { return Array(hits.prefix(max(0, topK))) }
        let picked = indices.compactMap { $0 >= 0 && $0 < hits.count ? hits[$0] : nil }
        return Array(picked.prefix(max(0, topK)))
    }

    // MARK: Grounded-режим (строгое цитирование + честное «не знаю»)

    /// Дописывается ПОСЛЕ фрагментов при settings.ragStrictMode: ответ только по базе,
    /// обязательный раздел «Источники» (метки фрагментов — см. RagRetriever.buildBlock).
    static let citationDirective = """
    Отвечай ТОЛЬКО на основе фрагментов базы знаний выше — не добавляй факты из общих \
    знаний. В конце ответа ОБЯЗАТЕЛЬНО выведи раздел «Источники:» — для КАЖДОГО \
    использованного фрагмента строку вида:
    — <источник> · <раздел> · #<номер>: «короткая точная цитата из фрагмента (1–2 предложения)»
    (источник/раздел/номер бери из метки фрагмента в квадратных скобках). Если фрагментов \
    недостаточно для ответа — честно скажи, что не знаешь, и задай уточняющий вопрос.
    """

    /// Блок ВМЕСТО фрагментов, когда поиск не дал ничего выше порога (строгий режим):
    /// модель обязана признаться и уточнить, а не отвечать из общих знаний.
    static let notFoundDirective = """
    Поиск по базе знаний НЕ нашёл фрагментов выше порога релевантности по вопросу \
    пользователя. Ты ОБЯЗАН честно ответить, что в базе знаний ответа нет («не знаю»), \
    НЕ отвечать из общих знаний и НЕ строить предположений. Затем задай один уточняющий \
    вопрос, который помог бы переформулировать запрос и найти нужное в базе.
    """
}
