// VPSAgentClient.swift — HTTP-клиент к сервису-агенту рутин на VPS.
//
// Аналог DeepSeekClient: struct (Sendable, без состояния). Base URL и токен —
// из KeyStore (bootstrap, ~/.config/manager-assistant/agent.url|agent.token).
// Базовый URL — КОРЕНЬ хоста (например https://vps.example); пути
// включают префикс /agent (как маршруты сервера).
//
// Тестируемость: построение URLRequest вынесено в ЧИСТЫЕ static-функции
// (makeURL/makeRequest) — их проверяют юнит-тесты без сети (в проекте нет
// сетевых моков, см. CLAUDE.md).

import Foundation

/// Ошибки клиента с понятными для пользователя текстами (рус.).
enum VPSAgentError: LocalizedError {
    case missingConfig
    case invalidURL
    case unauthorized
    case notFound
    case conflict
    case badStatus(code: Int, message: String)
    case upstream(message: String)
    case decoding
    case transport(message: String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Не настроено подключение к VPS. Укажи адрес и токен в разделе «Подключение к VPS»."
        case .invalidURL:
            return "Некорректный адрес VPS."
        case .unauthorized:
            return "Неверный токен доступа к агенту."
        case .notFound:
            return "Объект не найден на сервере."
        case .conflict:
            return "Рутина изменена в другом месте — данные обновлены. Повтори действие."
        case .badStatus(let code, let message):
            return "Ошибка сервера (\(code)): \(message)"
        case .upstream(let message):
            return "Ошибка внешнего сервиса: \(message)"
        case .decoding:
            return "Не удалось разобрать ответ сервера."
        case .transport(let message):
            return "Не удалось связаться с VPS: \(message)"
        }
    }
}

struct VPSAgentClient {

    var isConfigured: Bool { !KeyStore.agentURL.isEmpty && !KeyStore.agentToken.isEmpty }

    // MARK: - Чистые построители запроса (тестируемы без сети)

    /// Склеивает корневой base и путь (`/agent/...`), добавляет query.
    static func makeURL(base: String, path: String, query: [URLQueryItem] = []) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard var comps = URLComponents(string: b + path) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    static func makeRequest(base: String, token: String, method: String, path: String,
                            query: [URLQueryItem] = [], body: Data? = nil,
                            idempotencyKey: String? = nil) throws -> URLRequest {
        guard let url = makeURL(base: base, path: path, query: query) else {
            throw VPSAgentError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        if let idempotencyKey {
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        return req
    }

    // MARK: - Эндпоинты

    func health() async throws -> Bool {
        struct Health: Decodable { var status: String? }
        let h: Health = try await perform("GET", "/agent/health")
        return h.status == "ok"
    }

    func getSettings() async throws -> AgentSettings {
        try await perform("GET", "/agent/settings")
    }

    func putSettings(_ body: UpdateAgentSettingsRequest) async throws -> AgentSettings {
        try await perform("PUT", "/agent/settings", body: encode(body))
    }

    func listRoutines() async throws -> [Routine] {
        let list: RoutinesList = try await perform("GET", "/agent/routines")
        return list.items
    }

    func getRoutine(id: String) async throws -> Routine {
        try await perform("GET", "/agent/routines/\(esc(id))")
    }

    func createRoutine(_ body: CreateRoutineRequest) async throws -> Routine {
        try await perform("POST", "/agent/routines", body: encode(body))
    }

    func updateRoutine(id: String, _ body: UpdateRoutineRequest) async throws -> Routine {
        try await perform("PATCH", "/agent/routines/\(esc(id))", body: encode(body))
    }

    func deleteRoutine(id: String) async throws {
        _ = try await send("DELETE", "/agent/routines/\(esc(id))")
    }

    func setEnabled(id: String, _ enabled: Bool) async throws -> Routine {
        try await perform("POST", "/agent/routines/\(esc(id))/enable", body: encode(EnableRequest(enabled: enabled)))
    }

    func trigger(id: String, idempotencyKey: String? = nil) async throws -> RunRecord {
        try await perform("POST", "/agent/routines/\(esc(id))/trigger", idempotencyKey: idempotencyKey)
    }

    func listRuns(routineId: String, limit: Int = 20, cursor: String? = nil) async throws -> RunPage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await perform("GET", "/agent/routines/\(esc(routineId))/runs", query: q)
    }

    func getRun(runId: String) async throws -> RunRecord {
        try await perform("GET", "/agent/runs/\(esc(runId))")
    }

    func ask(_ body: AskRequest) async throws -> AgentChatReply {
        try await perform("POST", "/agent/chat/ask", body: encode(body))
    }

    // MARK: MCP-серверы (синк из приложения)

    func getMcpServers() async throws -> [McpServerStatusDTO] {
        let r: McpServersResponse = try await perform("GET", "/agent/mcp-servers")
        return r.items
    }

    @discardableResult
    func putMcpServers(_ servers: [MCPServerDTO]) async throws -> [McpServerStatusDTO] {
        let r: McpServersResponse = try await perform("PUT", "/agent/mcp-servers",
                                                      body: encode(McpServersRequest(servers: servers)))
        return r.items
    }

    // MARK: - Внутреннее

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw VPSAgentError.decoding }
    }

    private func config() throws -> (base: String, token: String) {
        let base = KeyStore.agentURL
        let token = KeyStore.agentToken
        guard !base.isEmpty, !token.isEmpty else { throw VPSAgentError.missingConfig }
        return (base, token)
    }

    private func perform<T: Decodable>(_ method: String, _ path: String,
                                       query: [URLQueryItem] = [], body: Data? = nil,
                                       idempotencyKey: String? = nil) async throws -> T {
        let data = try await send(method, path, query: query, body: body, idempotencyKey: idempotencyKey)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VPSAgentError.decoding
        }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: Data? = nil, idempotencyKey: String? = nil) async throws -> Data {
        let (base, token) = try config()
        let req = try Self.makeRequest(base: base, token: token, method: method, path: path,
                                       query: query, body: body, idempotencyKey: idempotencyKey)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw VPSAgentError.transport(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw VPSAgentError.transport(message: "нет HTTP-ответа")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = try? JSONDecoder().decode(AgentErrorResponse.self, from: data)
            let msg = parsed?.error.message ?? (String(data: data, encoding: .utf8) ?? "ошибка")
            switch http.statusCode {
            case 401: throw VPSAgentError.unauthorized
            case 404: throw VPSAgentError.notFound
            case 409: throw VPSAgentError.conflict
            case 502: throw VPSAgentError.upstream(message: msg)
            default: throw VPSAgentError.badStatus(code: http.statusCode, message: msg)
            }
        }
        return data
    }
}
