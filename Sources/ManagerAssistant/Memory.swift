// Memory.swift — многоуровневая память ассистента (по ТЗ).
//
// В отличие от «стратегий контекста» (ContextStrategy в Models.swift), которые
// лишь решают, какой кусок истории ТЕКУЩЕГО чата переслать, память — это
// отдельный, типизированный, кросс-чатовый слой. Хранится локально (JSON) и
// подставляется в системный промпт каждого запроса — другого механизма у
// stateless OpenAI-совместимого API (DeepSeek/OpenRouter) нет: серверной
// памяти/threads/векторного хранилища они не предоставляют.
//
// Три уровня:
//  - краткосрочная — заметки на ТЕКУЩИЙ диалог (MemoryItem в Chat.memory);
//  - рабочая = ПРОЕКТ — человеко-создаваемый Project (бриф + полнотекстовые
//    секции ProjectEntry), дополняется агентами; доступен из любого чата через
//    Chat.projectID (projects.json);
//  - долговременная — профиль пользователя (MemoryItem в memory.json, во ВСЕ чаты).
//
// MemoryScope { shortTerm, working, longTerm } оставлен с тремя кейсами для
// СОВМЕСТИМОСТИ декода старых файлов («working»-сниппеты); в актуальной модели
// рабочее живёт в Project, а не в MemoryItem.working — поэтому working в пикерах
// скрыт.
//
// MemoryContext.assemble собирает блок памяти под токенный бюджет: долговременная
// (короткие записи) + ПРОЕКТ (бриф + оглавление + тела секций под бюджет) +
// краткосрочная. Закреплённые (pinned) не выкидываются. Инжектится через
// PromptBuilder.systemPrompt(... memory:). «Собрать» (DeepSeekClient.assembleProject)
// читает ПОЛНЫЕ тела секций — это отдельный поток, не инжект.

import Foundation

/// Уровень (область) памяти — по ТЗ три типа.
enum MemoryScope: String, Codable, CaseIterable, Identifiable {
    case shortTerm   // краткосрочная — текущий диалог
    case working     // рабочая — данные текущей задачи
    case longTerm    // долговременная — профиль и знания (глобально)

    var id: String { rawValue }

    /// Снисходительное декодирование (как ContextStrategy): неизвестное → .working.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryScope(rawValue: raw) ?? .working
    }

    var label: String {
        switch self {
        case .shortTerm: return "Краткосрочная"
        case .working: return "Рабочая"
        case .longTerm: return "Долговременная"
        }
    }

    var hint: String {
        switch self {
        case .shortTerm: return "Текущий диалог: заметки в рамках этого чата."
        case .working: return "Данные задачи. Задача может охватывать несколько чатов."
        case .longTerm: return "Профиль и знания — глобально, подставляются во все чаты."
        }
    }

    var icon: String {
        switch self {
        case .shortTerm: return "bubble.left"
        case .working: return "hammer"
        case .longTerm: return "brain"
        }
    }

    /// Заголовок секции в системном промпте.
    var promptTitle: String {
        switch self {
        case .shortTerm: return "Краткосрочная память — текущий диалог"
        case .working: return "Рабочая память — данные задачи"
        case .longTerm: return "Долговременная память — профиль и знания"
        }
    }
}

/// Категория записи памяти (для UI и подсказки модели, куда сохранять).
enum MemoryKind: String, Codable, CaseIterable, Identifiable {
    case profile      // профиль решения/пользователя
    case knowledge    // знание/факт о домене
    case taskData     // данные задачи
    case decision     // принятое решение
    case preference   // предпочтение
    case note         // произвольная заметка

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryKind(rawValue: raw) ?? .note
    }

    var label: String {
        switch self {
        case .profile: return "Профиль"
        case .knowledge: return "Знание"
        case .taskData: return "Данные задачи"
        case .decision: return "Решение"
        case .preference: return "Предпочтение"
        case .note: return "Заметка"
        }
    }

    /// Уровень по умолчанию, куда логично класть запись этого типа.
    var defaultScope: MemoryScope {
        switch self {
        case .profile, .knowledge, .preference: return .longTerm
        case .taskData, .decision: return .working
        case .note: return .shortTerm
        }
    }
}

/// Одна запись памяти. Codable + снисходительный init(from:) — новые поля можно
/// добавлять, не ломая старые memory.json/tasks.json/chats.json.
struct MemoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var scope: MemoryScope = .working
    var kind: MemoryKind = .note
    var text: String = ""
    var tags: [String] = []
    var createdAt: Date = Date()
    /// Из какого чата сохранено (для контекста/фильтра). nil — добавлено вручную.
    var sourceChatID: UUID? = nil
    /// Закреплено — всегда инжектится в промпт, не выкидывается бюджетом.
    var pinned: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, scope, kind, text, tags, createdAt, sourceChatID, pinned
    }
}

extension MemoryItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MemoryItem()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        scope = try c.decodeIfPresent(MemoryScope.self, forKey: .scope) ?? d.scope
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? d.kind
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? d.tags
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
        sourceChatID = try c.decodeIfPresent(UUID.self, forKey: .sourceChatID)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? d.pinned
    }
}

/// Секция проекта — ПОЛНОТЕКСТОВАЯ запись рабочей памяти (ответ агента, заметка).
/// В отличие от MemoryItem (короткий факт-сниппет), у секции есть заголовок И
/// полное тело — чтобы из секций можно было собрать связный итог, а не огрызки.
struct ProjectEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = ""           // короткий заголовок секции
    var body: String = ""            // ПОЛНЫЙ текст
    var kind: MemoryKind = .note      // переиспользуем категорию для иконки/UI
    var createdAt: Date = Date()
    var sourceChatID: UUID? = nil     // из какого чата добавлено
    var pinned: Bool = false          // всегда включать при инжекте/сборке

    enum CodingKeys: String, CodingKey { case id, title, body, kind, createdAt, sourceChatID, pinned }

    /// Заголовок из первой строки тела (когда явного нет). ~50 символов.
    static func deriveTitle(from body: String) -> String {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Секция" }
        if trimmed.count <= 50 { return trimmed }
        return String(trimmed.prefix(50)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension ProjectEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectEntry()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? d.title
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? d.body
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? d.kind
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
        sourceChatID = try c.decodeIfPresent(UUID.self, forKey: .sourceChatID)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? d.pinned
    }
}

/// Проект — человеко-создаваемый контейнер рабочей памяти: цель (бриф) +
/// полнотекстовые секции, которые дополняют агенты. Доступен из любого чата
/// (чат ссылается на проект через Chat.projectID); проект может охватывать
/// несколько чатов.
/// ВАЖНО: имя Project, не Task — иначе конфликт со Swift Concurrency `Task {}`.
struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Новый проект"
    var brief: String = ""            // цель/постановка проекта (пишет человек)
    var entries: [ProjectEntry] = []  // рабочая память — полные секции
    var createdAt: Date = Date()
    var archived: Bool = false

    enum CodingKeys: String, CodingKey { case id, title, brief, entries, createdAt, archived }
    /// Старый ключ WorkTask — массив коротких записей (миграция в секции).
    enum LegacyKeys: String, CodingKey { case items }
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Project()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? d.title
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? d.brief
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? d.archived
        if let entries = try c.decodeIfPresent([ProjectEntry].self, forKey: .entries) {
            self.entries = entries
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let items = try? legacy.decodeIfPresent([MemoryItem].self, forKey: .items) {
            // Миграция старого WorkTask.items (короткие записи) → секции проекта.
            self.entries = items.map {
                ProjectEntry(title: ProjectEntry.deriveTitle(from: $0.text),
                             body: $0.text, kind: $0.kind,
                             createdAt: $0.createdAt, sourceChatID: $0.sourceChatID,
                             pinned: $0.pinned)
            }
        }
    }
}

/// Сборка блока памяти для системного промпта из трёх источников под токенный
/// бюджет. Закреплённые (pinned) записи включаются всегда; остальные — пока
/// хватает бюджета. Возвращает nil, если инжектить нечего/выключено.
enum MemoryContext {
    /// Грубая оценка токенов (как ChatViewModel.estimateTokens, но без привязки
    /// к @MainActor — assemble зовётся из разных мест): ~3 символа на токен.
    private static func tokens(_ text: String) -> Int { max(1, text.count / 3) }

    static func assemble(longTerm: [MemoryItem],
                         project: Project?,
                         shortTerm: [MemoryItem],
                         settings: GenerationSettings) -> String? {
        guard settings.injectLongTermMemory || settings.injectChatMemory else { return nil }
        let budget = max(0, settings.memoryTokenBudget)
        var used = 0
        var out: [String] = []

        // 1. Долговременная (глобальный профиль) — короткие записи.
        if settings.injectLongTermMemory {
            if let block = itemsBlock(MemoryScope.longTerm.promptTitle, ordered(longTerm), budget: budget, used: &used) {
                out.append(block)
            }
        }

        // 2. Рабочая = проект: бриф + оглавление секций + тела под бюджет.
        if settings.injectChatMemory, let project, !project.entries.isEmpty || !project.brief.isEmpty {
            out.append(projectBlock(project, budget: budget, used: &used))
        }

        // 3. Краткосрочная (заметки этого чата) — короткие записи.
        if settings.injectChatMemory {
            if let block = itemsBlock(MemoryScope.shortTerm.promptTitle, ordered(shortTerm), budget: budget, used: &used) {
                out.append(block)
            }
        }

        return out.isEmpty ? nil : out.joined(separator: "\n\n")
    }

    /// Только долговременная (глобальная) память — для режима сравнения, где у
    /// дорожек нет своей кратко-/рабочей памяти, но честно дать всем общий профиль.
    static func assembleLongTermOnly(longTerm: [MemoryItem], settings: GenerationSettings) -> String? {
        assemble(longTerm: longTerm, project: nil, shortTerm: [], settings: settings)
    }

    /// Блок коротких записей (долговременная/краткосрочная) под общий бюджет.
    private static func itemsBlock(_ title: String, _ items: [MemoryItem], budget: Int, used: inout Int) -> String? {
        var lines: [String] = []
        for item in items where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cost = tokens(item.text) + 2
            if item.pinned { lines.append("- \(item.text)"); used += cost }
            else if used + cost <= budget { lines.append("- \(item.text)"); used += cost }
        }
        return lines.isEmpty ? nil : "[\(title)]\n" + lines.joined(separator: "\n")
    }

    /// Компактный блок проекта: бриф + оглавление секций + тела newest-first под
    /// бюджет (pinned-секции включаются всегда). Не вываливает все тела сразу.
    private static func projectBlock(_ project: Project, budget: Int, used: inout Int) -> String {
        var parts: [String] = ["[Рабочая память — проект: \(project.title)]"]
        if !project.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Инструкции проекта: \(project.brief)")
            used += tokens(project.brief)
        }
        let entries = orderedEntries(project.entries)
        if !entries.isEmpty {
            // Оглавление — дёшево, всегда целиком.
            parts.append("Секции: " + entries.map { $0.title.isEmpty ? "(без названия)" : $0.title }.joined(separator: " · "))
            // Тела — пока хватает бюджета; pinned всегда.
            for e in entries where !e.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cost = tokens(e.body) + tokens(e.title) + 4
                if e.pinned {
                    parts.append("## \(e.title)\n\(e.body)"); used += cost
                } else if used + cost <= budget {
                    parts.append("## \(e.title)\n\(e.body)"); used += cost
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Закреплённые сверху, затем новые раньше старых.
    private static func orderedEntries(_ entries: [ProjectEntry]) -> [ProjectEntry] {
        entries.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
    }

    /// Закреплённые сверху, затем новые раньше старых.
    private static func ordered(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
    }
}
