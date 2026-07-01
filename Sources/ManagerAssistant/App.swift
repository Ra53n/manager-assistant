// App.swift — точка входа приложения.
//
// Архитектура приложения (поток данных):
//   ContentView (UI) → ChatViewModel (состояние) → DeepSeekClient (HTTP)
//        ↑                    ↓
//   MarkdownUI-рендер    ChatStore (персистентность на диск)
//
// Особенность запуска: приложение распространяется и как Swift Package
// (`swift run` — «голый» бинарник без .app-бандла), и как .app (run.sh /
// install.sh). У голого бинарника macOS не активирует окно и не показывает
// иконку в Dock — это чинит AppDelegate ниже.

import SwiftUI
import AppKit

/// Делегат гарантирует, что приложение становится обычным (regular) и выходит
/// на передний план с видимым окном — даже когда запущено «голым» бинарником
/// через `swift run` (без .app-бандла).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Self.loadAppIcon() {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Иконка для Dock. Нужна в первую очередь для запуска через `swift run`
    /// (у «голого» бинарника нет .app-обёртки, поэтому иконку ставим в рантайме).
    /// Для собранного .app иконку и так даёт CFBundleIconFile.
    private static func loadAppIcon() -> NSImage? {
        // Ресурс пакета (`swift run`).
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Ресурс внутри .app.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Глушим локальный Ollama, если поднимали его МЫ (ленивый запуск под RAG). Чужой/
    /// официальный сервер не трогаем — он не наш (см. OllamaLauncher.stopIfSpawned).
    func applicationWillTerminate(_ notification: Notification) {
        OllamaLauncher.shared.stopIfSpawned()
    }
}

@main
struct ManagerAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Manager assistant") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
