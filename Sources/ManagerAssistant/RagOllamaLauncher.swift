// RagOllamaLauncher.swift — ленивый запуск локального Ollama по требованию RAG.
//
// Идея: НЕ держать сервер запущенным постоянно. Он поднимается только когда реально
// нужен — при индексации или ретриве с эмбеддером `.ollama` (см. RagIndexer/RagRetriever),
// и глушится при выходе из приложения (AppDelegate.applicationWillTerminate) — но ТОЛЬКО
// тот процесс, который запустили МЫ. Уже работающий сервер (например, официальный
// Ollama.app) не трогаем и второй не плодим.
//
// Тяжёлая часть (модель) и так живёт по требованию: Ollama грузит её на первый запрос и
// выгружает после простоя (OLLAMA_KEEP_ALIVE). Этот лончер убирает и лёгкий демон из
// фонового «всегда включено»: до первого RAG-действия не запущено ничего.

import Foundation

/// Синглтон, гарантирующий доступность локального Ollama по требованию. Потокобезопасен
/// (NSLock вокруг ссылки на процесс и флага запуска); опрос доступности идёт без удержания замка.
final class OllamaLauncher {
    static let shared = OllamaLauncher()
    private init() {}

    private let lock = NSLock()
    /// Процесс сервера, запущенный ИМЕННО нами (nil — не запускали / уже остановлен).
    private var spawned: Process?
    /// Идёт ли сейчас попытка запуска (чтобы параллельные вызовы не спавнили дубль).
    private var launchInFlight = false

    /// Гарантирует, что Ollama отвечает на `baseURL`. Возвращает true, если сервер доступен
    /// (уже был поднят, либо мы успешно его подняли). Для нелокального адреса запускать
    /// нечего — просто проверяем доступность.
    @discardableResult
    func ensureRunning(baseURL: String) async -> Bool {
        // 1) Уже отвечает — ничего не делаем.
        if await OllamaEmbedder.isAvailable(baseURL: baseURL) { return true }
        // 2) Поднимать имеет смысл только локальный сервер.
        guard Self.isLocal(baseURL) else { return false }

        // 3) Один запуск одновременно: если кто-то уже спавнит — просто ждём готовности.
        //    Скоупный withLock — async-безопасен (замок не удерживается через await).
        let iAmLauncher = lock.withLock { () -> Bool in
            if launchInFlight { return false }
            launchInFlight = true
            return true
        }

        if !iAmLauncher {
            return await waitHealthy(baseURL: baseURL)
        }
        defer { lock.withLock { launchInFlight = false } }

        // Мог подняться, пока мы брали замок (гонка) — перепроверяем перед спавном.
        if await OllamaEmbedder.isAvailable(baseURL: baseURL) { return true }

        guard let bin = Self.findBinary() else { return false }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = Self.hostPort(baseURL)   // куда биндиться (host:port из baseURL)
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice   // не копим вывод сервера
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return false
        }
        lock.withLock { spawned = proc }
        return await waitHealthy(baseURL: baseURL)
    }

    /// Останавливает сервер, который запустили МЫ (чужой/официальный не трогаем).
    /// Вызывается при выходе из приложения.
    func stopIfSpawned() {
        let proc = lock.withLock { () -> Process? in
            let p = spawned; spawned = nil; return p
        }
        proc?.terminate()
    }

    // MARK: Вспомогательное

    /// Ждёт, пока сервер начнёт отвечать (до ~15 с; сам serve биндит порт за 1–2 с,
    /// модель грузится уже на первом запросе эмбеддинга).
    private func waitHealthy(baseURL: String) async -> Bool {
        for _ in 0..<30 {
            if await OllamaEmbedder.isAvailable(baseURL: baseURL) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await OllamaEmbedder.isAvailable(baseURL: baseURL)
    }

    /// Локальный ли адрес (только такой имеет смысл запускать у себя).
    static func isLocal(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// «host:port» из baseURL для OLLAMA_HOST (дефолт 127.0.0.1:11434).
    static func hostPort(_ baseURL: String) -> String {
        guard let u = URL(string: baseURL) else { return "127.0.0.1:11434" }
        return "\(u.host ?? "127.0.0.1"):\(u.port ?? 11434)"
    }

    /// Ищет исполняемый `ollama` в типовых местах установки (наш headless-бинарник,
    /// официальный Ollama.app, Homebrew). nil — не найден (тогда индексация даст понятную
    /// ошибку «сервер не запущен и не найден»).
    static func findBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("ollama-dist/ollama"),
            URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
            URL(fileURLWithPath: "/usr/local/bin/ollama"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
