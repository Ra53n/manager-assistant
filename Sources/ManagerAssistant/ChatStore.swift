import Foundation

/// Сохранение истории чатов на диск:
/// ~/Library/Application Support/ManagerAssistant/chats.json
///
/// Формат — компактный JSON (без pretty-print) через Codable.
/// Runtime-поля (isLoading, errorText) не сохраняются — см. Chat.CodingKeys.
enum ChatStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ManagerAssistant", isDirectory: true)
            .appendingPathComponent("chats.json")
    }

    /// Загружает чаты; при отсутствии или повреждении файла возвращает пустой
    /// список (повреждённый файл откладывается в сторону, а не роняет приложение).
    static func load() -> [Chat] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([Chat].self, from: data)
        } catch {
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return []
        }
    }

    /// Атомарно записывает все чаты на диск.
    static func save(_ chats: [Chat]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(chats) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
