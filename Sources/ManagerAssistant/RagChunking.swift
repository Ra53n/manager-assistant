// RagChunking.swift — стратегии нарезки документа на чанки.
//
// Чанк — единица индексации и ретрива: слишком большой кусок «размывает» смысл
// эмбеддинга, слишком мелкий теряет контекст. Пользователь выбирает стратегию на
// индекс (ТЗ требует ≥2 с возможностью выбора):
//
//   • FixedSizeChunker — окна по N символов с нахлёстом (overlap). Простая и
//                        предсказуемая; хороша для «плоского» текста без структуры.
//   • StructureChunker — границы по структуре: Markdown-заголовки/разделы (а на
//                        уровне пайплайна — ещё и по файлам). Метаданные чанка несут
//                        `section` = текст ближайшего заголовка. Длинные разделы
//                        дорезаются фиксированным чанкером (вторичная нарезка).
//
// Всё — ЧИСТЫЕ детерминированные функции (легко тестировать). Глобальный `ordinal`
// в пределах всего индекса присваивает пайплайн (RagPipeline) при склейке чанков из
// разных файлов; здесь ordinal — локальный, 0-based в пределах документа.

import Foundation

/// Стратегия нарезки одного документа на чанки.
protocol ChunkingStrategy {
    /// baseMetadata — общие поля (source/title/filePath); стратегия дополняет `section`.
    func chunk(text: String, baseMetadata: RagChunkMetadata) -> [RagChunk]
}

// MARK: - Фиксированный размер

/// Режет текст на окна по `size` символов с нахлёстом `overlap` (0 ≤ overlap < size).
/// Нахлёст сохраняет контекст на стыках. Пустые/пробельные окна отбрасываются.
struct FixedSizeChunker: ChunkingStrategy {
    let size: Int
    let overlap: Int

    init(size: Int, overlap: Int) {
        self.size = max(1, size)
        // overlap строго меньше size, иначе шаг был бы нулевым (бесконечный цикл).
        self.overlap = max(0, min(overlap, max(0, self.size - 1)))
    }

    func chunk(text: String, baseMetadata: RagChunkMetadata) -> [RagChunk] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let step = max(1, size - overlap)
        var chunks: [RagChunk] = []
        var start = 0
        while start < chars.count {
            let end = min(start + size, chars.count)
            let piece = String(chars[start..<end])
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(RagChunk(text: piece,
                                       ordinal: chunks.count,
                                       startOffset: start,
                                       endOffset: end,
                                       metadata: baseMetadata))
            }
            if end == chars.count { break }   // достигли конца — дальше только пустое
            start += step
        }
        return chunks
    }
}

// MARK: - По структуре (Markdown-заголовки/разделы)

/// Режет текст по Markdown-заголовкам (`#`…`######`). Каждый раздел (заголовок + тело
/// до следующего заголовка) → чанк, `metadata.section` = текст заголовка. Преамбула до
/// первого заголовка — раздел с пустым `section`. Нет заголовков → один чанк на весь
/// текст. Слишком длинный раздел (> maxSectionChars) дорезается FixedSizeChunker.
struct StructureChunker: ChunkingStrategy {
    /// Потолок длины раздела в символах; nil — не дорезать. Обычно = config.chunkSize.
    let maxSectionChars: Int?

    init(maxSectionChars: Int? = nil) { self.maxSectionChars = maxSectionChars }

    private struct Section { var title: String; var startOffset: Int; var lines: [String] }

    func chunk(text: String, baseMetadata: RagChunkMetadata) -> [RagChunk] {
        let lines = text.components(separatedBy: "\n")
        var sections: [Section] = []
        var current = Section(title: "", startOffset: 0, lines: [])
        var started = false
        var offset = 0

        for line in lines {
            if let title = Self.headingTitle(line) {
                // Закрываем предыдущий раздел (кроме пустой начальной преамбулы).
                if started || !current.lines.isEmpty { sections.append(current) }
                current = Section(title: title, startOffset: offset, lines: [line])
                started = true
            } else {
                current.lines.append(line)
            }
            offset += line.count + 1   // +1 — символ перевода строки, срезанный split'ом
        }
        sections.append(current)

        var chunks: [RagChunk] = []
        for sec in sections {
            let body = sec.lines.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var meta = baseMetadata
            meta.section = sec.title

            if let maxLen = maxSectionChars, body.count > maxLen {
                // Вторичная нарезка длинного раздела — с сохранением section в метаданных.
                let sub = FixedSizeChunker(size: maxLen, overlap: min(200, max(0, maxLen / 5)))
                    .chunk(text: body, baseMetadata: meta)
                for var piece in sub {
                    piece.ordinal = chunks.count
                    piece.startOffset += sec.startOffset
                    piece.endOffset += sec.startOffset
                    chunks.append(piece)
                }
            } else {
                chunks.append(RagChunk(text: body,
                                       ordinal: chunks.count,
                                       startOffset: sec.startOffset,
                                       endOffset: sec.startOffset + body.count,
                                       metadata: meta))
            }
        }
        return chunks
    }

    /// Текст ATX-заголовка Markdown (`## Заголовок` → «Заголовок»); иначе nil.
    /// Требуется пробел после решёток (CommonMark). Допускаются пустые заголовки.
    static func headingTitle(_ line: String) -> String? {
        let t = line.drop(while: { $0 == " " })
        guard t.first == "#" else { return nil }
        var hashes = 0
        var idx = t.startIndex
        while idx < t.endIndex, t[idx] == "#" { hashes += 1; idx = t.index(after: idx) }
        guard (1...6).contains(hashes), idx < t.endIndex, t[idx] == " " else { return nil }
        return String(t[idx...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Фабрика

enum Chunkers {
    static func make(_ config: RagIndexConfig) -> ChunkingStrategy {
        switch config.chunking {
        case .fixed:
            return FixedSizeChunker(size: config.chunkSize, overlap: config.chunkOverlap)
        case .structure:
            return StructureChunker(maxSectionChars: config.chunkSize)
        }
    }
}
