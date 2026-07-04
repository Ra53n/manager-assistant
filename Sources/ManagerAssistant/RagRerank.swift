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

    // MARK: Кодовая гарантия раздела «Источники» (grounded-режим)
    // citationDirective — только просьба; модель может «забыть». Здесь — проверка на
    // уровне КОДА: детектор раздела, парсер меток фрагментов и автофутер-фолбэк.
    // Вызывающие (send()/runStateMachine/сравнение) на их основе делают ретрай и/или
    // дописывают источники сами — ответ без источников становится невозможен.

    /// Есть ли в ответе раздел «Источники»/«Sources». Построчно: снимается markdown-обвязка
    /// (`##`, `>`, маркеры списка, `**`/`_`), затем строка должна БЫТЬ заголовком раздела —
    /// «источники» целиком или начинаться с «источники:»/«источники (» (в т.ч. автофутер).
    /// «эти источники мы не нашли» в середине фразы — НЕ срабатывает.
    static func hasSourcesSection(_ answer: String) -> Bool {
        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            // Markdown-обвязка заголовка: #, >, маркеры списка, жирный/курсив.
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#>*-—–_ \t"))
            for header in ["источники", "sources"] {
                if line == header { return true }
                if line.hasPrefix(header + ":") || line.hasPrefix(header + " (") { return true }
            }
        }
        return false
    }

    /// Метки фрагментов из строки ragBlock: строки вида «[#3 · doc.md · Раздел]» →
    /// «#3 · doc.md · Раздел». Формат пишет RagRetriever.buildBlock — однострочная метка,
    /// начинается с «[#», закрывается «]». Дедуп с сохранением порядка; для
    /// notFoundDirective/произвольного текста → пусто.
    static func parseChunkLabels(_ ragBlock: String) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for rawLine in ragBlock.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[#"), line.hasSuffix("]") else { continue }
            let inner = String(line.dropFirst().dropLast())
            guard !inner.isEmpty, !inner.contains("]") else { continue }   // только однострочная метка
            if seen.insert(inner).inserted { labels.append(inner) }
        }
        return labels
    }

    /// Есть ли с чего требовать источники: nil / пустой блок / notFoundDirective → false.
    static func hasCitationLabels(_ ragBlock: String?) -> Bool {
        guard let block = ragBlock else { return false }
        return !parseChunkLabels(block).isEmpty
    }

    /// Ответ — честное «не знаю» (citationDirective РАЗРЕШАЕТ его без источников).
    /// Эвристика; ошибается в сторону «не наказывать честный отказ» — это правильная сторона.
    static func answerAdmitsNotFound(_ answer: String) -> Bool {
        let lower = answer.lowercased()
        let markers = ["не знаю", "ответа нет", "нет ответа", "не нашёл", "не нашел",
                       "не найдено", "недостаточно фрагментов", "недостаточно информации",
                       "нет в базе знаний", "в базе знаний нет"]
        return markers.contains { lower.contains($0) }
    }

    /// Автофутер из меток найденных фрагментов. «Автоматически» — честность: цитат
    /// модель не давала, это список найденного, а не использованного. labels пуст → nil.
    static func citationFooter(labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        return "Источники (автоматически, по найденным фрагментам):\n"
            + labels.map { "— \($0)" }.joined(separator: "\n")
    }

    /// Терминальный фолбэк: раздел уже есть / ответ = «не знаю» / меток нет → ответ как
    /// есть; иначе дописывает автофутер. Идемпотентна (футер сам детектится как раздел).
    static func ensureSourcesSection(answer: String, ragBlock: String) -> String {
        guard !hasSourcesSection(answer), !answerAdmitsNotFound(answer),
              let footer = citationFooter(labels: parseChunkLabels(ragBlock)) else { return answer }
        return answer + "\n\n" + footer
    }

    /// Повторный запрос в ЧАТЕ (предыдущий ответ виден модели парой assistant/user).
    static let citationRetryReminder = """
    Твой предыдущий ответ нарушил обязательное требование: нет раздела «Источники:». \
    Выведи ТОТ ЖЕ ответ ЦЕЛИКОМ ещё раз, добавив в конец раздел «Источники:» — для каждого \
    использованного фрагмента базы знаний строку «— <источник> · <раздел> · #<номер>: \
    «короткая цитата»» (данные бери из меток фрагментов в квадратных скобках). Если \
    фрагментов недостаточно — честно скажи, что не знаешь. Больше ничего не меняй.
    """

    /// Повтор этапа «Ответ» в FSM (предыдущей попытки модель НЕ видит — этап генерится заново).
    static let citationStageReminder = """
    ВНИМАНИЕ: предыдущая попытка ответа не содержала обязательный раздел «Источники:». \
    Сформируй ответ заново и ОБЯЗАТЕЛЬНО заверши его разделом «Источники:» — для каждого \
    использованного фрагмента базы знаний строка «— <источник> · <раздел> · #<номер>: \
    «короткая цитата»» (данные — из меток фрагментов в квадратных скобках). Если \
    фрагментов недостаточно — честно скажи, что не знаешь.
    """
}

/// Гейт «нужен ли (пере)ретрив» для прогона FSM. Живёт локальной переменной
/// runStateMachine (НЕ персистентный: resume/interject перезапускают прогон, где гейт
/// свежий и первый же проход ретривит заново). Эмбеддер гоняется ТОЛЬКО когда снапшот
/// guidance.count изменился — на обычных проходах цикла это сравнение двух Int.
struct RagRetrievalGate {
    private(set) var lastGuidanceCount: Int? = nil

    /// Поисковый запрос прогона: задача + ПОСЛЕДНИЕ уточнения пользователя (усечённые).
    static func query(task: String, guidance: [String],
                      maxItems: Int = 3, maxItemChars: Int = 300) -> String {
        let recent = guidance.suffix(maxItems)
            .map { "- \(String($0.prefix(maxItemChars)))" }
        guard !recent.isEmpty else { return task }
        return task + "\n\nУточнения пользователя:\n" + recent.joined(separator: "\n")
    }

    /// nil — ретрив не нужен (guidance не менялся); иначе запрос + фиксация снапшота.
    mutating func queryIfNeeded(task: String, guidance: [String]) -> String? {
        guard guidance.count != lastGuidanceCount else { return nil }
        lastGuidanceCount = guidance.count
        return Self.query(task: task, guidance: guidance)
    }
}
