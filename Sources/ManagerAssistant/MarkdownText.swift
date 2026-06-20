// MarkdownText.swift — рендер Markdown ОДНИМ Text для сплошного выделения.
//
// Зачем: MarkdownUI рисует каждый блок (заголовок, абзац, пункт списка)
// ОТДЕЛЬНЫМ Text-вью, поэтому выделение мышью не переходит между блоками —
// можно выделить только один абзац за раз. Сообщения пользователя выделяются
// целиком, потому что это один Text.
//
// Здесь мы парсим Markdown в ОДИН AttributedString с восстановленной блочной
// разметкой (переносы строк между блоками, маркеры списков, крупные/жирные
// заголовки, моноширинный код) и рендерим его одним Text — тогда выделение и
// копирование работают по всему ответу, как в обычном тексте.
//
// Инлайн-оформление (жирный/курсив/код/ссылки) Text применяет сам по
// inlinePresentationIntent; блочную структуру (которую Text не отображает)
// мы достраиваем вручную.

import SwiftUI

enum MarkdownText {
    /// Markdown → один styled AttributedString для сплошного выделения.
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }

        // Сгруппировать runs в блоки по идентичности presentationIntent.
        struct Block { var intent: PresentationIntent?; var text: AttributedString }
        var blocks: [Block] = []
        for run in parsed.runs {
            let intent = run.presentationIntent
            let piece = AttributedString(parsed[run.range])
            if !blocks.isEmpty, blocks[blocks.count - 1].intent == intent {
                blocks[blocks.count - 1].text.append(piece)
            } else {
                blocks.append(Block(intent: intent, text: piece))
            }
        }

        var out = AttributedString()
        var prevWasListItem = false
        for (i, block) in blocks.enumerated() {
            let kind = classify(block.intent)
            let isListItem = kind.isListItem
            if i > 0 {
                // Между пунктами одного списка — один перенос, иначе пустая строка.
                out.append(AttributedString(isListItem && prevWasListItem ? "\n" : "\n\n"))
            }
            out.append(render(block.text, kind: kind))
            prevWasListItem = isListItem
        }
        return out
    }

    // MARK: - Классификация блока

    private enum Kind {
        case heading(Int)
        case bullet(depth: Int)
        case ordered(depth: Int, number: Int)
        case code
        case quote
        case thematicBreak
        case paragraph

        var isListItem: Bool {
            switch self {
            case .bullet, .ordered: return true
            default: return false
            }
        }
    }

    private static func classify(_ intent: PresentationIntent?) -> Kind {
        guard let intent else { return .paragraph }
        var depth = 0
        var ordinal = 1
        var isOrdered = false
        var sawListItem = false
        var sawQuote = false
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .heading(level)
            case .codeBlock:
                return .code
            case .thematicBreak:
                return .thematicBreak
            case .listItem(let n):
                ordinal = n
                sawListItem = true
            case .orderedList:
                isOrdered = true
                depth += 1
            case .unorderedList:
                depth += 1
            case .blockQuote:
                sawQuote = true
            default:
                break
            }
        }
        if sawListItem { return isOrdered ? .ordered(depth: depth, number: ordinal) : .bullet(depth: depth) }
        if sawQuote { return .quote }
        return .paragraph
    }

    // MARK: - Оформление блока

    private static func render(_ text: AttributedString, kind: Kind) -> AttributedString {
        switch kind {
        case .heading(let level):
            var t = text
            let size: CGFloat = level <= 1 ? 21 : (level == 2 ? 17 : 15)
            t.font = .system(size: size, weight: .bold)
            return t
        case .code:
            var t = text
            t.font = .system(.callout, design: .monospaced)
            return t
        case .bullet(let depth):
            let indent = String(repeating: "    ", count: max(0, depth - 1))
            return AttributedString("\(indent)•  ") + text
        case .ordered(let depth, let number):
            let indent = String(repeating: "    ", count: max(0, depth - 1))
            return AttributedString("\(indent)\(number).  ") + text
        case .quote:
            var prefix = AttributedString("│  ")
            prefix.foregroundColor = .secondary
            return prefix + text
        case .thematicBreak:
            var rule = AttributedString("⎯⎯⎯⎯⎯⎯⎯⎯")
            rule.foregroundColor = .secondary
            return rule
        case .paragraph:
            return text
        }
    }
}
