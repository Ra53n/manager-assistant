// Profile.swift — «Профиль ответа»: именованный пресет поведения ассистента.
//
// Это НЕ «профиль» из долговременной памяти (там авто-факты о пользователе) и НЕ
// параметры генерации (температура/токены — отдельно в GenerationSettings).
// Профиль ответа — набор ТЕКСТОВЫХ директив (стиль/тон, формат, длина и
// ограничения, язык + свободные доп. инструкции), которые подставляются в
// системный промпт. Создаётся/настраивается/переключается на каждый чат через
// Chat.profileID. Глобальный список — в profiles.json (ProfileStore).

import Foundation

struct ResponseProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "Новый профиль"
    var style: String = ""        // стиль / тон
    var format: String = ""       // формат ответа (списки/таблицы/JSON/…)
    var constraints: String = ""  // длина и ограничения (свободный текст, БЕЗ токенов)
    var language: String = ""     // язык ответа
    var extra: String = ""        // доп. инструкции — расширяемость
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, style, format, constraints, language, extra, createdAt
    }

    /// Директивы профиля для системного промпта; nil — все поля пустые.
    var systemDirective: String? {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append("\(label): \(t)") }
        }
        add("Стиль и тон", style)
        add("Формат", format)
        add("Длина и ограничения", constraints)
        add("Язык ответа", language)
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { lines.append(e) }
        guard !lines.isEmpty else { return nil }
        return "«\(name)»\n" + lines.joined(separator: "\n")
    }
}

extension ResponseProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ResponseProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? d.style
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? d.format
        constraints = try c.decodeIfPresent(String.self, forKey: .constraints) ?? d.constraints
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        extra = try c.decodeIfPresent(String.self, forKey: .extra) ?? d.extra
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
    }

    /// Готовые профили при первом запуске (чтобы фича работала из коробки).
    static func seeded() -> [ResponseProfile] {
        [
            ResponseProfile(name: "Кратко по делу",
                            style: "Лаконичный, по существу, без воды",
                            format: "Маркированные пункты",
                            constraints: "Коротко — до 3–5 пунктов"),
            ResponseProfile(name: "Подробно",
                            style: "Развёрнутый, поясняющий",
                            format: "Заголовки и списки",
                            constraints: "Полно, с примерами и обоснованием"),
            ResponseProfile(name: "Технический",
                            style: "Точные термины, минимум лишней вежливости",
                            format: "Код-блоки где уместно, списки",
                            constraints: "Конкретика, без общих слов"),
        ]
    }
}
