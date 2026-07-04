// MCPClient.swift — клиент MCP: запуск серверов (stdio) и вызов их инструментов.
//
// Один транспорт — stdio: приложение запускает команду сервера как ПОДПРОЦЕСС
// (`/usr/bin/env <command> <args…>`) и общается JSON-RPC по stdin/stdout
// (newline-delimited, как в @modelcontextprotocol/sdk). Этого достаточно и для
// локальных серверов (`node dist/index.js`), и для удалённых через мост
// `npx -y mcp-remote <url> --header "Authorization: Bearer …"` — конфиг как в Claude.
//
//   MCPServer        — конфиг сервера (command/args/env), как в mcpServers Claude;
//   MCPConnection    — actor: один процесс + handshake (initialize → tools/list) +
//                      вызовы tools/call. Кадрирование — построчный JSON.
//   MCPManager       — actor-агрегатор: соединения по серверам, карта
//                      qualifiedName → (server, tool), availableTools/call/test.
//
// Менеджер — actor (Sendable) → его замыкание-исполнитель легально захватывается
// в группу подагентов роя (как struct-клиент), не таща @MainActor-состояние.

import Foundation

// MARK: - Конфиг сервера

/// MCP-сервер в стиле конфига Claude Desktop: команда запуска + аргументы + env.
/// Хранится в mcp-servers.json (вне репозитория). Секреты (bearer-токен, API-ключ)
/// живут в args/env — как в Claude, — а не в коде.
struct MCPServer: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var command: String = "npx"
    var args: [String] = []
    var env: [String: String] = [:]
    var enabled: Bool = true
    /// Доп. каталоги PATH для поиска команды (на случай нестандартной установки node).
    var extraPATH: String = ""

    /// Безопасный слаг имени для префикса инструментов (a–z0–9_).
    var slug: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let mapped = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "mcp" : String(s.prefix(24))
    }
}

extension MCPServer {
    enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, enabled, extraPATH
    }
    /// Снисходительное декодирование (новые поля не ломают старый mcp-servers.json).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MCPServer()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? d.command
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? d.args
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? d.env
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        extraPATH = try c.decodeIfPresent(String.self, forKey: .extraPATH) ?? d.extraPATH
    }

    /// Шаблон удалённого YouGile через mcp-remote (БЕЗ секрета — токен вставит юзер).
    static func youGileTemplate() -> MCPServer {
        var s = MCPServer()
        s.name = "yougile"
        s.command = "npx"
        s.args = ["-y", "mcp-remote", "https://<хост>/mcp",
                  "--header", "Authorization: Bearer <ВСТАВЬ_ТОКЕН>"]
        s.enabled = false
        return s
    }

    /// Разбор JSON-блока в стиле Claude: `{ "mcpServers": { "<имя>": { command,args,env } } }`
    /// (либо сразу карта серверов). Возвращает список серверов (enabled=true).
    static func parseClaudeConfig(_ text: String) -> [MCPServer] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        let map = root["mcpServers"]?.objectValue ?? root.objectValue ?? [:]
        var out: [MCPServer] = []
        for (name, v) in map {
            guard let o = v.objectValue else { continue }
            var s = MCPServer()
            s.name = name
            s.command = o["command"]?.stringValue ?? "npx"
            s.args = o["args"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            if let e = o["env"]?.objectValue {
                var env: [String: String] = [:]
                for (k, ev) in e { if let sv = ev.stringValue { env[k] = sv } }
                s.env = env
            }
            s.enabled = true
            out.append(s)
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - Окружение подпроцесса

/// Сборка окружения для запуска MCP-сервера. ГЛАВНОЕ: GUI-`.app` из Finder
/// получает минимальный PATH без nvm/homebrew → `npx`/`node` не находятся.
/// Дополняем PATH каталогами nvm (все версии), homebrew и /usr/local/bin.
enum MCPEnv {
    static func augmentedPATH(extra: String) -> String {
        var dirs: [String] = []
        if !extra.isEmpty { dirs += extra.split(separator: ":").map(String.init) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: >) { dirs.append("\(nvm)/\(v)/bin") }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
        if let current = ProcessInfo.processInfo.environment["PATH"] {
            dirs += current.split(separator: ":").map(String.init)
        }
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>(); var out: [String] = []
        for d in dirs where !d.isEmpty && !seen.contains(d) { seen.insert(d); out.append(d) }
        return out.joined(separator: ":")
    }

    static func childEnvironment(_ server: MCPServer) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in server.env { env[k] = v }
        env["PATH"] = augmentedPATH(extra: server.extraPATH)
        return env
    }
}

// MARK: - Соединение (один процесс)

/// Одно живое соединение с MCP-сервером: подпроцесс + JSON-RPC по stdio.
actor MCPConnection {
    let server: MCPServer
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()
    private var stderrText = ""
    private(set) var tools: [MCPToolSpec] = []
    private var running = false

    init(server: MCPServer) { self.server = server }

    var isRunning: Bool { running && (process?.isRunning ?? false) }
    var diagnostics: String { stderrText }

    /// Запускает процесс и читающий цикл (идемпотентно).
    private func start() throws {
        if isRunning { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [server.command] + server.args
        proc.environment = MCPEnv.childEnvironment(server)

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // stdout → построчный поток (порядок сохраняется через AsyncStream).
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        let cont = continuation!
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { cont.finish() } else { cont.yield(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendStderr(s) }
        }
        proc.terminationHandler = { _ in cont.finish() }

        try proc.run()
        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        running = true
        readTask = Task { [weak self] in await self?.consume(stream) }
    }

    private func appendStderr(_ s: String) {
        stderrText += s
        if stderrText.count > 8000 { stderrText = String(stderrText.suffix(8000)) }
    }

    private func consume(_ stream: AsyncStream<Data>) async {
        for await chunk in stream {
            buffer.append(chunk)
            drainLines()
        }
        // Поток закрылся — процесс завершился. Срываем все ожидания.
        running = false
        let err = MCPError.process(stderrText.isEmpty ? "процесс завершился" : String(stderrText.suffix(400)))
        for (_, c) in pending { c.resume(throwing: err) }
        pending.removeAll()
    }

    private func drainLines() {
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if !line.isEmpty { handle(Data(line)) }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(RPCIncoming.self, from: data) else { return }
        // method != nil → запрос/нотификация сервера (не ответ на наш запрос) → игнор.
        guard msg.method == nil, let id = msg.id?.intValue,
              let cont = pending.removeValue(forKey: id) else { return }
        if let e = msg.error { cont.resume(throwing: MCPError.rpc(e.code, e.message)) }
        else { cont.resume(returning: msg.result ?? .null) }
    }

    private func request(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
        guard running else { throw MCPError.notConnected }
        let id = nextID; nextID += 1
        let req = RPCRequest(id: id, method: method, params: params)
        let payload = try JSONEncoder().encode(req)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            pending[id] = cont
            do {
                var line = payload; line.append(0x0A)
                try stdinHandle?.write(contentsOf: line)
            } catch {
                pending[id] = nil
                cont.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, _ params: JSONValue?) throws {
        let n = RPCNotification(method: method, params: params)
        var payload = try JSONEncoder().encode(n); payload.append(0x0A)
        try stdinHandle?.write(contentsOf: payload)
    }

    /// initialize → notifications/initialized → tools/list (с пагинацией).
    func handshakeAndListTools() async throws -> [MCPToolSpec] {
        try start()
        let initParams: JSONValue = .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object(["tools": .object([:])]),
            "clientInfo": .object(["name": .string("ManagerAssistant"), "version": .string("1.0.0")]),
        ])
        _ = try await request("initialize", initParams)
        try notify("notifications/initialized", nil)

        var collected: [MCPToolSpec] = []
        var cursor: String? = nil
        repeat {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("tools/list", params)
            if let arr = result["tools"]?.arrayValue {
                for t in arr {
                    guard let name = t["name"]?.stringValue else { continue }
                    collected.append(MCPToolSpec(
                        name: name,
                        description: t["description"]?.stringValue ?? "",
                        inputSchema: t["inputSchema"] ?? .object([:])))
                }
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        tools = collected
        return collected
    }

    /// Вызов инструмента: возвращает склейку текстовых частей result.content.
    func callTool(_ name: String, arguments: JSONValue) async throws -> String {
        let params: JSONValue = .object(["name": .string(name), "arguments": arguments])
        let result = try await request("tools/call", params)
        var text = ""
        if let content = result["content"]?.arrayValue {
            for part in content {
                if let t = part["text"]?.stringValue { text += t }
            }
        }
        if text.isEmpty { text = result.jsonString }
        if result["isError"]?.boolValue == true { text = "ERROR: " + text }
        return text
    }

    func shutdown() {
        readTask?.cancel(); readTask = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        running = false
        for (_, c) in pending { c.resume(throwing: MCPError.notConnected) }
        pending.removeAll()
    }
}

// MARK: - Менеджер (агрегатор серверов)

/// Владеет соединениями, агрегирует инструменты, маршрутизирует вызовы по
/// qualifiedName. Actor → Sendable: замыкание-исполнитель безопасно уходит в рой.
actor MCPManager {
    private var connections: [UUID: MCPConnection] = [:]
    private var specsByServer: [UUID: [ToolSpec]] = [:]
    private var routeByQualified: [String: (serverID: UUID, tool: String)] = [:]
    private var lastStatus: [UUID: MCPServerStatus] = [:]
    private var connecting: Set<UUID> = []

    /// Подключает (идемпотентно) все enabled-серверы.
    func ensureConnected(_ servers: [MCPServer]) async {
        for s in servers where s.enabled { _ = await connect(s) }
    }

    @discardableResult
    private func connect(_ server: MCPServer) async -> MCPServerStatus {
        // Уже подключён с инструментами — ничего не делаем.
        if let conn = connections[server.id], await conn.isRunning, let specs = specsByServer[server.id] {
            return statusFor(server, specs: specs, error: nil)
        }
        // Параллельный повторный вход (реентранси actor) — не плодим процессы.
        if connecting.contains(server.id) {
            return lastStatus[server.id] ?? MCPServerStatus(serverID: server.id, connected: false, toolCount: 0, toolNames: [], error: nil)
        }
        connecting.insert(server.id)
        defer { connecting.remove(server.id) }

        if let old = connections[server.id] { await old.shutdown() }
        let conn = MCPConnection(server: server)
        connections[server.id] = conn
        do {
            let tools = try await withTimeout(90) { try await conn.handshakeAndListTools() }
            let specs = tools.map { t in
                ToolSpec(serverID: server.id, serverName: server.name, name: t.name,
                         qualifiedName: MCPManager.qualify(server: server, tool: t.name),
                         description: t.description, schema: t.inputSchema)
            }
            specsByServer[server.id] = specs
            for sp in specs { routeByQualified[sp.qualifiedName] = (server.id, sp.name) }
            return statusFor(server, specs: specs, error: nil)
        } catch {
            let diag = await conn.diagnostics
            await conn.shutdown()
            connections[server.id] = nil
            specsByServer[server.id] = nil
            let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let msg = diag.isEmpty ? base : base + " · " + String(diag.suffix(300))
            let st = MCPServerStatus(serverID: server.id, connected: false, toolCount: 0, toolNames: [], error: msg)
            lastStatus[server.id] = st
            return st
        }
    }

    private func statusFor(_ server: MCPServer, specs: [ToolSpec], error: String?) -> MCPServerStatus {
        let st = MCPServerStatus(serverID: server.id, connected: error == nil,
                                 toolCount: specs.count, toolNames: specs.map { $0.name }, error: error)
        lastStatus[server.id] = st
        return st
    }

    /// Имя функции для LLM: `<slug>__<tool>`, только [A-Za-z0-9_-], ≤64 симв.
    static func qualify(server: MCPServer, tool: String) -> String {
        let raw = "\(server.slug)__\(tool)"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(String(mapped).prefix(64))
    }

    func availableTools(serverIDs: Set<UUID>) -> [ToolSpec] {
        serverIDs.sorted { $0.uuidString < $1.uuidString }.flatMap { specsByServer[$0] ?? [] }
    }

    /// Выполнить инструмент по имени функции. Никогда не бросает — возвращает текст
    /// (ошибку с префиксом ERROR), чтобы LLM-цикл мог её увидеть и среагировать.
    func call(qualifiedName: String, argumentsJSON: String) async -> String {
        guard let route = routeByQualified[qualifiedName], let conn = connections[route.serverID] else {
            return "ERROR: \(MCPError.unknownTool(qualifiedName).errorDescription ?? qualifiedName)"
        }
        let args = JSONValue.parse(argumentsJSON) ?? .object([:])
        do {
            return try await withTimeout(120) { try await conn.callTool(route.tool, arguments: args) }
        } catch {
            return "ERROR: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func testConnection(_ server: MCPServer) async -> MCPServerStatus { await connect(server) }
    func status(for id: UUID) -> MCPServerStatus? { lastStatus[id] }

    func disconnectAll() async {
        for (_, c) in connections { await c.shutdown() }
        connections.removeAll(); specsByServer.removeAll(); routeByQualified.removeAll()
    }

    func disconnect(_ id: UUID) async {
        if let c = connections[id] { await c.shutdown() }
        connections[id] = nil; specsByServer[id] = nil
        routeByQualified = routeByQualified.filter { $0.value.serverID != id }
        lastStatus[id] = nil
    }
}
