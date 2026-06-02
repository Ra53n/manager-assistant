import SwiftUI
import AppKit

/// Делегат гарантирует, что приложение становится обычным (regular) и выходит
/// на передний план с видимым окном — даже когда запущено «голым» бинарником
/// через `swift run` (без .app-бандла).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
