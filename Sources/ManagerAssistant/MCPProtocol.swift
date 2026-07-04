// MCPProtocol.swift — типы протокола MCP (Model Context Protocol) и JSON-RPC 2.0.
//
// Здесь живёт ПРИМИТИВ JSONValue — произвольное JSON-значение, которое позволяет
// провести через конкретные Codable-DTO то, что заранее не типизировано:
//   - inputSchema инструмента (JSON Schema любой формы);
//   - arguments вызова инструмента и его результат.
//
// Плюс конверты JSON-RPC (запрос/нотификация/ответ) и доменные типы MCP
// (MCPToolSpec — как сервер описал инструмент; ToolSpec — то же, но с уникальным
// именем функции для LLM и привязкой к серверу). Сам транспорт/соединение — в
// MCPClient.swift, встраивание в LLM-цикл — в DeepSeekClient.runPhaseWithTools.

import Foundation

// MARK: - Произвольное JSON-значение

/// Произвольное значение JSON. Нужен, чтобы пронести нетипизированный JSON
/// (схемы инструментов, аргументы/результаты вызовов) через Codable-DTO.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // ВАЖЕН ПОРЯДОК: Int раньше Double, чтобы «1» не превратилось в «1.0».
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Неподдерживаемое JSON-значение")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    subscript(_ key: String) -> JSONValue? { objectValue?[key] }

    /// Разбирает JSON-строку (например, arguments вызова от модели) в JSONValue.
    static func parse(_ string: String) -> JSONValue? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Компактная JSON-строка значения (для записи в payload запроса).
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - JSON-RPC 2.0

/// Исходящий запрос (ждёт ответа по id).
struct RPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: JSONValue?
}

/// Исходящая нотификация (ответа НЕ ждёт).
struct RPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?
}

/// Входящее сообщение. Снисходительно: это может быть ответ (id + result/error),
/// нотификация (method без id) или запрос сервера (method + id). Запросы/нотификации
/// сервера мы игнорируем (наличие method отличает их от ответа — иначе id сервера
/// мог бы совпасть с нашим pending-id).
struct RPCIncoming: Decodable {
    let id: JSONValue?
    let method: String?
    let result: JSONValue?
    let error: RPCErrorBody?
}

struct RPCErrorBody: Decodable {
    let code: Int
    let message: String
}

// MARK: - Доменные типы MCP

/// Инструмент так, как его описал сервер в ответе tools/list.
struct MCPToolSpec: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

/// Инструмент, подготовленный для отдачи в LLM: уникальное имя функции
/// (`<server>__<tool>`, валидное для OpenAI) + привязка к серверу.
struct ToolSpec: Sendable, Equatable, Identifiable {
    let serverID: UUID
    let serverName: String
    let name: String           // исходное имя инструмента у сервера
    let qualifiedName: String  // имя функции, видимое модели
    let description: String
    let schema: JSONValue
    var id: String { qualifiedName }
}

/// Статус соединения с MCP-сервером (для UI).
struct MCPServerStatus: Sendable, Equatable {
    let serverID: UUID
    let connected: Bool
    let toolCount: Int
    let toolNames: [String]
    let error: String?
}

// MARK: - Ошибки

enum MCPError: LocalizedError {
    case timeout
    case notConnected
    case process(String)
    case rpc(Int, String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Таймаут ожидания ответа MCP-сервера."
        case .notConnected: return "MCP-сервер не подключён."
        case .process(let s): return "Сбой MCP-процесса: \(s)"
        case .rpc(let code, let msg): return "Ошибка MCP (\(code)): \(msg)"
        case .unknownTool(let name): return "Неизвестный инструмент: \(name)"
        }
    }
}

/// Гонка операции с таймаутом (для handshake/вызовов инструментов).
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPError.timeout
        }
        guard let result = try await group.next() else { throw MCPError.timeout }
        group.cancelAll()
        return result
    }
}
