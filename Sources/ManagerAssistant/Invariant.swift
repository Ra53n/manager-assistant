// Invariant.swift — инварианты: валидируемые ограничения, которым ОБЯЗАН
// соответствовать ответ модели (разрешённый стек, архитектура, бюджет, макс.
// зависимостей, запрет технологий, принятые техрешения, бизнес-правила).
//
// Архитектура (как у пользователя): Profile + State Machine + Invariants →
// Prompt Builder → LLM → Validate → Pass/Fail/retry. Инварианты инжектятся в
// промпт (агент ОБЯЗАН их учитывать и ОТКАЗЫВАТЬ в нарушающих решениях) и
// проверяют ответ — кодом (вхождение запрещённых терминов) и/или доп. запросом
// к модели. Хранятся ОТДЕЛЬНО от диалога — в invariants.json (InvariantStore,
// см. MemoryStore.swift), со скоупами global/project/chat.

import Foundation

/// Тип инварианта (для UI/шаблонов/текста описания).
enum InvariantKind: String, Codable, CaseIterable, Identifiable {
    case stack          // разрешённый стек / ограничения по стеку
    case noBanned       // запрет технологий/библиотек
    case maxDeps        // максимум зависимостей
    case arch           // архитектура
    case budget         // бюджет
    case techDecision   // принятое техническое решение
    case businessRule   // бизнес-правило
    case custom         // произвольное правило

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InvariantKind(rawValue: raw) ?? .custom
    }

    var title: String {
        switch self {
        case .stack: return "Стек"
        case .noBanned: return "Запрет"
        case .maxDeps: return "Макс. зависимостей"
        case .arch: return "Архитектура"
        case .budget: return "Бюджет"
        case .techDecision: return "Техническое решение"
        case .businessRule: return "Бизнес-правило"
        case .custom: return "Правило"
        }
    }
}

/// Способ защиты конкретного инварианта.
enum InvariantEnforcement: String, Codable, CaseIterable, Identifiable {
    case prompt   // только в промпт (модель соблюдает и отказывает)
    case code     // только код-проверка (вхождение запрещённых терминов в ответе)
    case both     // двойная защита (промпт + код)

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InvariantEnforcement(rawValue: raw) ?? .both
    }

    var label: String {
        switch self {
        case .prompt: return "Промпт"
        case .code: return "Код"
        case .both: return "Двойная"
        }
    }
}

/// Область действия инварианта (привязка хранится в самом инварианте, НЕ в диалоге).
enum InvariantScope: String, Codable, CaseIterable, Identifiable {
    case global   // во всех чатах
    case project  // во всех чатах проекта (ownerID = projectID)
    case chat     // только в этом чате (ownerID = chatID)

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InvariantScope(rawValue: raw) ?? .global
    }

    var label: String {
        switch self {
        case .global: return "Глобально"
        case .project: return "Проект"
        case .chat: return "Этот чат"
        }
    }
}

/// Метод валидации ответа на соответствие инвариантам (per-chat, в GenerationSettings).
enum InvariantValidationMode: String, Codable, CaseIterable, Identifiable {
    case off    // не валидировать (инварианты только в промпте, если есть)
    case code   // код: вхождение запрещённых терминов + маркер-самопометка модели
    case llm    // доп. запрос к модели «соблюдены ли инварианты?»
    case both   // код + доп. запрос

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InvariantValidationMode(rawValue: raw) ?? .code
    }

    var label: String {
        switch self {
        case .off: return "Выкл"
        case .code: return "Код"
        case .llm: return "LLM"
        case .both: return "Оба"
        }
    }
}

/// Инвариант — одно ограничение. Codable (хранится в invariants.json).
struct Invariant: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: InvariantKind = .noBanned
    var name: String = ""            // короткое имя: "StackOnly", "NoRxJava", "Auth=JWT"
    var allowed: [String] = []       // .stack: разрешённые термины (для промпта)
    var banned: [String] = []        // запрещённые подстроки (код-проверка по вхождению)
    var maxDeps: Int = 5             // .maxDeps
    var note: String = ""            // arch/budget/techDecision/businessRule/custom: текст
    var enforcement: InvariantEnforcement = .both
    var scope: InvariantScope = .global
    var ownerID: UUID? = nil         // projectID (.project) / chatID (.chat); nil (.global)
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, kind, name, allowed, banned, maxDeps, note, enforcement, scope, ownerID, enabled
    }

    /// Человеко/модель-читаемое описание (для промпта и UI) — аналог Invariant.description.
    var description: String {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = nm.isEmpty ? "" : "\(nm) — "
        switch kind {
        case .stack:
            var s = "разрешённый стек: только \(allowed.joined(separator: ", "))"
            if !banned.isEmpty { s += "; запрещено: \(banned.joined(separator: ", "))" }
            return prefix + s
        case .noBanned:
            return prefix + "запрещено использовать: \(banned.joined(separator: ", "))"
        case .maxDeps:
            return prefix + "максимум зависимостей/библиотек: \(maxDeps)"
        case .arch:
            return prefix + "архитектура: \(note)"
        case .budget:
            return prefix + "бюджет: \(note)"
        case .techDecision:
            return prefix + "принятое техническое решение: \(note)"
        case .businessRule:
            return prefix + "бизнес-правило: \(note)"
        case .custom:
            return prefix + note
        }
    }

    var promptVisible: Bool { enabled && enforcement != .code }
    var codeChecked: Bool { enabled && enforcement != .prompt }

    /// Код-проверка по вхождению: true = инвариант НАРУШЕН (найдена запрещённая подстрока).
    func codeViolation(in text: String) -> Bool {
        guard codeChecked, !banned.isEmpty else { return false }
        let r = text.lowercased()
        return banned.contains { let t = $0.trimmingCharacters(in: .whitespaces).lowercased()
                                 return !t.isEmpty && r.contains(t) }
    }
}

extension Invariant {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Invariant()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        kind = try c.decodeIfPresent(InvariantKind.self, forKey: .kind) ?? d.kind
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        allowed = try c.decodeIfPresent([String].self, forKey: .allowed) ?? d.allowed
        banned = try c.decodeIfPresent([String].self, forKey: .banned) ?? d.banned
        maxDeps = try c.decodeIfPresent(Int.self, forKey: .maxDeps) ?? d.maxDeps
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? d.note
        enforcement = try c.decodeIfPresent(InvariantEnforcement.self, forKey: .enforcement) ?? d.enforcement
        scope = try c.decodeIfPresent(InvariantScope.self, forKey: .scope) ?? d.scope
        ownerID = try c.decodeIfPresent(UUID.self, forKey: .ownerID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }

    /// Шаблоны для быстрого добавления (в UI). НЕ загружаются автоматически.
    static func templates() -> [Invariant] {
        [
            Invariant(kind: .stack, name: "Стек", allowed: ["Kotlin", "Ktor"],
                      banned: ["Spring Boot", "Java", "React"], enforcement: .both),
            Invariant(kind: .noBanned, name: "NoRxJava", banned: ["RxJava"], enforcement: .both),
            Invariant(kind: .maxDeps, name: "Зависимости", maxDeps: 5, enforcement: .prompt),
            Invariant(kind: .arch, name: "Архитектура", note: "MVVM", enforcement: .prompt),
            Invariant(kind: .budget, name: "Бюджет", note: "только бесплатные API", enforcement: .prompt),
            Invariant(kind: .techDecision, name: "Авторизация", note: "только через JWT", enforcement: .prompt),
            Invariant(kind: .businessRule, name: "Правило", note: "", enforcement: .prompt),
        ]
    }
}

/// Найденное нарушение инварианта.
struct InvariantViolation: Equatable {
    var name: String
    var description: String
}

/// Валидация ответа на соответствие инвариантам (код-уровень) + сборка промпт-блока.
enum InvariantValidator {
    /// Маркер: модель сама сообщает, что инвариант нарушить вынуждает запрос юзера
    /// (конфликт). Код ловит его → показывает баннер, НЕ зацикливает retry.
    static let violationMarker = "НАРУШЕН ИНВАРИАНТ"

    /// Код-проверка: какие инварианты нарушены вхождением запрещённых терминов.
    static func codeViolations(_ text: String, _ invs: [Invariant]) -> [InvariantViolation] {
        invs.filter { $0.codeViolation(in: text) }
            .map { InvariantViolation(name: $0.name, description: $0.description) }
    }

    /// Модель сама пометила конфликт с запросом пользователя.
    static func modelFlaggedConflict(_ text: String) -> Bool {
        text.uppercased().contains(violationMarker.uppercased())
    }

    /// Блок `[INVARIANTS]` для промпта: перечень + ОБЯЗАТЕЛЬНОСТЬ учёта + жёсткий отказ.
    static func promptBlock(_ invs: [Invariant]) -> String {
        let visible = invs.filter { $0.promptVisible }
        guard !visible.isEmpty else { return "" }
        let list = visible.map { "- \($0.description)" }.joined(separator: "\n")
        return """
        [INVARIANTS]
        \(list)
        Эти инварианты ОБЯЗАТЕЛЬНЫ — в рассуждениях ЯВНО сверяйся с каждым. Нарушение \
        любого инварианта ЗАПРЕЩЕНО. КАТЕГОРИЧЕСКИ НЕ предлагай решения, которые их \
        нарушают. Если запрос пользователя требует нарушения — ОТКАЖИСЬ выполнять \
        нарушение: выведи строку «\(violationMarker): <название>», объясни конфликт и \
        предложи допустимую альтернативу в рамках разрешённого.
        """
    }
}
