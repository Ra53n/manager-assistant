// MemoryStore.swift — персистентность памяти (по образцу ChatStore).
//
// Два отдельных файла рядом с chats.json (ТЗ: разные типы памяти хранятся
// отдельно):
//   ~/Library/Application Support/ManagerAssistant/memory.json    — долговременная
//                                                                    (глобальная)
//   ~/Library/Application Support/ManagerAssistant/projects.json  — проекты
//   (рабочая память; миграция из старого tasks.json при первом запуске)
//
// Краткосрочная память отдельного файла не имеет — она живёт внутри Chat.memory
// и сохраняется вместе с chats.json через ChatStore.
//
// Поведение при повреждении файла повторяет ChatStore: битый файл откладывается
// в *.corrupt.json, приложение стартует с пустым хранилищем (не падает).

import Foundation

private func appSupportFile(_ name: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ManagerAssistant", isDirectory: true)
        .appendingPathComponent(name)
}

private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        return nil
    }
}

private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: .atomic)
}

/// Долговременная (глобальная) память — общий профиль и знания.
enum MemoryStore {
    static var fileURL: URL { appSupportFile("memory.json") }
    static func load() -> [MemoryItem] { loadJSON([MemoryItem].self, from: fileURL) ?? [] }
    static func save(_ items: [MemoryItem]) { saveJSON(items, to: fileURL) }
}

/// Профили ответа (именованные пресеты стиля/формата/ограничений) — profiles.json.
/// Отсутствует файл → стартовый набор (ResponseProfile.seeded()).
enum ProfileStore {
    static var fileURL: URL { appSupportFile("profiles.json") }
    static func load() -> [ResponseProfile] {
        if let p = loadJSON([ResponseProfile].self, from: fileURL) { return p }
        return ResponseProfile.seeded()
    }
    static func save(_ profiles: [ResponseProfile]) { saveJSON(profiles, to: fileURL) }
}

/// Инварианты (ограничения: стек/арх/бюджет/зависимости/запреты/техрешения/правила) —
/// invariants.json. ОТДЕЛЬНО от диалога (chats.json). Скоупы внутри самих инвариантов.
enum InvariantStore {
    static var fileURL: URL { appSupportFile("invariants.json") }
    static func load() -> [Invariant] { loadJSON([Invariant].self, from: fileURL) ?? [] }
    static func save(_ invariants: [Invariant]) { saveJSON(invariants, to: fileURL) }
}

/// Проекты (контейнеры рабочей памяти: бриф + полнотекстовые секции).
enum ProjectStore {
    static var fileURL: URL { appSupportFile("projects.json") }
    /// Старый файл рабочих задач — однократная миграция при первом запуске.
    static var legacyURL: URL { appSupportFile("tasks.json") }

    static func load() -> [Project] {
        if let projects = loadJSON([Project].self, from: fileURL) { return projects }
        // projects.json нет → мигрируем старый tasks.json ([WorkTask] декодится
        // как [Project] снисходительным init(from:)). tasks.json не удаляем (бэкап).
        if let migrated = loadJSON([Project].self, from: legacyURL), !migrated.isEmpty {
            return migrated
        }
        return []
    }

    static func save(_ projects: [Project]) { saveJSON(projects, to: fileURL) }
}
