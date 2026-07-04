// GrowingTextView.swift — многострочное поле ввода с поведением чата:
// Enter ОТПРАВЛЯЕТ, Shift+Enter — перенос строки. На macOS 13 `.onKeyPress`
// недоступен (macOS 14+), а у SwiftUI `TextField(axis:.vertical)` Enter не
// отправляет (вставляет перенос) — поэтому оборачиваем NSTextView.
//
// Авто-высота: измеряем содержимое и публикуем в `measuredHeight` (вызывающий
// клэмпит min…max и даёт скролл дальше). Плейсхолдер — наложенный NSTextField.

import SwiftUI
import AppKit

struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Канонический фабричный метод: корректно настраивает scroll+textView (вёрстка, перенос).
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false          // высоту клэмпит SwiftUI снаружи
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .preferredFont(forTextStyle: .body)
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.installPlaceholder(on: tv, text: placeholder)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Синк ТОЛЬКО при расхождении — иначе каждый ре-рендер сбивает курсор/IME/вставку.
        if tv.string != text {
            tv.string = text
        }
        context.coordinator.placeholder?.stringValue = placeholder
        context.coordinator.updatePlaceholderVisibility(tv)
        context.coordinator.recomputeHeight(tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        weak var textView: NSTextView?
        var placeholder: NSTextField?

        init(_ parent: GrowingTextEditor) { self.parent = parent }

        // Enter vs Shift+Enter.
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Во время IME-композиции (марк-текст) Return завершает ввод — не отправляем.
                if tv.hasMarkedText() { return false }
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    tv.insertNewlineIgnoringFieldEditor(nil)   // реальный перенос строки
                    return true
                }
                parent.onSubmit()                              // обычный Enter — отправка
                return true                                    // глотаем перенос
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            updatePlaceholderVisibility(tv)
            recomputeHeight(tv)
        }

        func recomputeHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            // Мутировать @Binding в апдейте вью нельзя — откладываем.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if abs(self.parent.measuredHeight - h) > 0.5 { self.parent.measuredHeight = h }
            }
        }

        // MARK: Плейсхолдер (наложенный NSTextField, виден при пустой строке)
        func installPlaceholder(on tv: NSTextView, text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .placeholderTextColor
            label.translatesAutoresizingMaskIntoConstraints = false
            tv.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 5),
                label.topAnchor.constraint(equalTo: tv.topAnchor, constant: 2),
            ])
            placeholder = label
            updatePlaceholderVisibility(tv)
        }

        func updatePlaceholderVisibility(_ tv: NSTextView) {
            placeholder?.isHidden = !tv.string.isEmpty
        }
    }
}
