// MCPTests — ЧИСТАЯ логика MCP-слоя: примитив JSONValue, конверты JSON-RPC,
// разбор ответа модели с tool_calls, кодирование запроса с tools (и без), парс
// конфига Claude, именование инструментов. Сеть/подпроцесс — только ручная проверка.

import XCTest
@testable import ManagerAssistant

final class MCPTests: XCTestCase {

    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    // MARK: JSONValue

    func testJSONValueIntVsDouble() throws {
        // «1» должно остаться int, «1.5» — double (порядок проб в init важен).
        let one = try dec.decode(JSONValue.self, from: Data("1".utf8))
        XCTAssertEqual(one, .int(1))
        let half = try dec.decode(JSONValue.self, from: Data("1.5".utf8))
        XCTAssertEqual(half, .double(1.5))
        let flag = try dec.decode(JSONValue.self, from: Data("true".utf8))
        XCTAssertEqual(flag, .bool(true))
        let nul = try dec.decode(JSONValue.self, from: Data("null".utf8))
        XCTAssertEqual(nul, .null)
    }

    func testJSONValueRoundTripSchema() throws {
        // Реальная JSON Schema инструмента проходит туда-обратно без потерь.
        let json = """
        {"type":"object","properties":{"title":{"type":"string"},"count":{"type":"integer"}},"required":["title"]}
        """
        let v = try dec.decode(JSONValue.self, from: Data(json.utf8))
        let back = try dec.decode(JSONValue.self, from: enc.encode(v))
        XCTAssertEqual(v, back)
        // Навигация по значению.
        XCTAssertEqual(v["type"]?.stringValue, "object")
        XCTAssertEqual(v["properties"]?["count"]?["type"]?.stringValue, "integer")
        XCTAssertEqual(v["required"]?.arrayValue?.first?.stringValue, "title")
    }

    func testJSONValueParseHelper() {
        let v = JSONValue.parse(#"{"a":1,"b":["x"]}"#)
        XCTAssertEqual(v?["a"]?.intValue, 1)
        XCTAssertEqual(v?["b"]?.arrayValue?.first?.stringValue, "x")
        XCTAssertNil(JSONValue.parse(""))
        XCTAssertEqual(JSONValue.parse("not json"), nil)
    }

    // MARK: JSON-RPC конверты

    func testRPCRequestEncodes() throws {
        let req = RPCRequest(id: 7, method: "tools/list", params: .object(["cursor": .string("c1")]))
        let obj = try JSONSerialization.jsonObject(with: enc.encode(req)) as? [String: Any]
        XCTAssertEqual(obj?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj?["id"] as? Int, 7)
        XCTAssertEqual(obj?["method"] as? String, "tools/list")
        XCTAssertEqual((obj?["params"] as? [String: Any])?["cursor"] as? String, "c1")
    }

    func testRPCIncomingResultVsError() throws {
        let okJSON = #"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#
        let ok = try dec.decode(RPCIncoming.self, from: Data(okJSON.utf8))
        XCTAssertEqual(ok.id?.intValue, 3)
        XCTAssertNil(ok.method)
        XCTAssertNil(ok.error)
        XCTAssertNotNil(ok.result?["tools"])

        let errJSON = #"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}"#
        let err = try dec.decode(RPCIncoming.self, from: Data(errJSON.utf8))
        XCTAssertEqual(err.error?.code, -32601)
        XCTAssertEqual(err.error?.message, "Method not found")

        // Нотификация сервера: есть method → НЕ ответ (мы такие игнорируем).
        let notif = #"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#
        let n = try dec.decode(RPCIncoming.self, from: Data(notif.utf8))
        XCTAssertEqual(n.method, "notifications/message")
        XCTAssertNil(n.id?.intValue)
    }

    // MARK: ChatResponse с tool_calls

    func testChatResponseToolCallsDecode() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":null,
        "tool_calls":[{"id":"call_1","type":"function",
        "function":{"name":"yougile__list_projects","arguments":"{}"}}]}}],
        "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
        """
        let resp = try dec.decode(ChatResponse.self, from: Data(json.utf8))
        let msg = try XCTUnwrap(resp.choices.first?.message)
        XCTAssertNil(msg.content)
        XCTAssertEqual(msg.tool_calls?.count, 1)
        XCTAssertEqual(msg.tool_calls?.first?.id, "call_1")
        XCTAssertEqual(msg.tool_calls?.first?.function.name, "yougile__list_projects")
        XCTAssertEqual(resp.usage?.total_tokens, 15)
    }

    func testChatResponsePlainTextDecode() throws {
        // Обычный ответ без tool_calls продолжает декодироваться.
        let json = #"{"choices":[{"message":{"role":"assistant","content":"привет"}}]}"#
        let resp = try dec.decode(ChatResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.choices.first?.message.content, "привет")
        XCTAssertNil(resp.choices.first?.message.tool_calls)
    }

    // MARK: ChatRequest с tools (и обратная совместимость без них)

    func testChatRequestOmitsToolsWhenNil() throws {
        let req = ChatRequest(model: "m", messages: [.init(role: "user", content: "hi")],
                              stream: false, temperature: 1, top_p: 1, max_tokens: 10, stop: nil)
        let obj = try JSONSerialization.jsonObject(with: enc.encode(req)) as? [String: Any]
        XCTAssertNil(obj?["tools"], "без инструментов ключ tools не должен отправляться")
        XCTAssertNil(obj?["tool_choice"])
        XCTAssertNil(obj?["stop"])
    }

    func testChatRequestEncodesTools() throws {
        let spec = ToolSpec(serverID: UUID(), serverName: "yougile", name: "create_task",
                            qualifiedName: "yougile__create_task", description: "Создать задачу",
                            schema: .object(["type": .string("object"),
                                             "properties": .object(["title": .object(["type": .string("string")])])]))
        let tool = ChatRequest.Tool(spec: spec)
        let req = ChatRequest(model: "m", messages: [.init(role: "user", content: "hi")],
                              stream: false, temperature: 1, top_p: 1, max_tokens: 10, stop: nil,
                              tools: [tool], tool_choice: "auto")
        let obj = try JSONSerialization.jsonObject(with: enc.encode(req)) as? [String: Any]
        let tools = try XCTUnwrap(obj?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let fn = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "yougile__create_task")
        XCTAssertEqual(fn["description"] as? String, "Создать задачу")
        XCTAssertNotNil(fn["parameters"])
        XCTAssertEqual(obj?["tool_choice"] as? String, "auto")
    }

    func testToolRoleMessageEncodes() throws {
        // Сообщение результата инструмента: role=tool + tool_call_id + content.
        let msg = ChatRequest.RequestMessage(role: ChatRole.tool.rawValue, content: "результат",
                                             tool_calls: nil, tool_call_id: "call_1")
        let obj = try JSONSerialization.jsonObject(with: enc.encode(msg)) as? [String: Any]
        XCTAssertEqual(obj?["role"] as? String, "tool")
        XCTAssertEqual(obj?["content"] as? String, "результат")
        XCTAssertEqual(obj?["tool_call_id"] as? String, "call_1")
        XCTAssertNil(obj?["tool_calls"])
    }

    // MARK: Парс конфига Claude

    func testParseClaudeConfig() {
        let json = """
        {
          "mcpServers": {
            "yougile": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "https://host/mcp", "--header", "Authorization: Bearer T"]
            },
            "local": { "command": "node", "args": ["dist/index.js"], "env": { "YOUGILE_API_KEY": "k" } }
          }
        }
        """
        let servers = MCPServer.parseClaudeConfig(json)
        XCTAssertEqual(servers.count, 2)
        let yg = try? XCTUnwrap(servers.first { $0.name == "yougile" })
        XCTAssertEqual(yg?.command, "npx")
        XCTAssertEqual(yg?.args.first, "-y")
        XCTAssertTrue(yg?.enabled ?? false)
        let local = servers.first { $0.name == "local" }
        XCTAssertEqual(local?.env["YOUGILE_API_KEY"], "k")
    }

    func testParseClaudeConfigEmpty() {
        XCTAssertTrue(MCPServer.parseClaudeConfig("{}").isEmpty)
        XCTAssertTrue(MCPServer.parseClaudeConfig("мусор").isEmpty)
    }

    // MARK: Именование инструментов (qualifiedName)

    func testQualifyNameIsSafeAndPrefixed() {
        var srv = MCPServer(); srv.name = "You Gile!"   // пробел/символы → '_'
        let q = MCPManager.qualify(server: srv, tool: "list_projects")
        XCTAssertEqual(q, "you_gile__list_projects")
        // Только [A-Za-z0-9_-], ≤64.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        XCTAssertTrue(q.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertLessThanOrEqual(q.count, 64)
    }

    func testSlugFallback() {
        var srv = MCPServer(); srv.name = ""
        XCTAssertEqual(srv.slug, "mcp")
    }
}
