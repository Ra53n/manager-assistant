// RoutinesTests.swift — чистые тесты DTO агента рутин и построителей запроса
// VPSAgentClient (без сети). После рефактора: синки упрощены до vps_local, привязок
// к YouGile нет, добавлены DTO синхронизации MCP-серверов.

import XCTest
@testable import ManagerAssistant

final class RoutinesTests: XCTestCase {
    private let dec = JSONDecoder()
    private let enc = JSONEncoder()

    // MARK: - Декод серверного JSON

    func testRoutineDecodesServerJSON() throws {
        let json = """
        {"id":"r1","name":"Сводка","prompt":"собери","cron":"0 9 * * *","timezone":"Europe/Moscow",
         "enabled":true,"catchUpOnStart":false,"model":"","maxIterations":6,"maxTokensBudget":20000,
         "sinks":[{"kind":"vps_local"}],
         "lastRunAt":null,"nextRunAt":"2026-06-27T06:00:00.000Z","cronHuman":"каждый день в 09:00",
         "createdAt":"2026-06-27T00:00:00.000Z","updatedAt":"2026-06-27T00:00:00.000Z","rev":3}
        """
        let r = try dec.decode(Routine.self, from: Data(json.utf8))
        XCTAssertEqual(r.id, "r1")
        XCTAssertEqual(r.cronHuman, "каждый день в 09:00")
        XCTAssertEqual(r.rev, 3)
        XCTAssertEqual(r.sinks.first?.kind, .vpsLocal)
    }

    func testRoutineOldJSONGetsDefaults() throws {
        let json = #"{"id":"x","name":"старая"}"#
        let r = try dec.decode(Routine.self, from: Data(json.utf8))
        XCTAssertEqual(r.name, "старая")
        XCTAssertEqual(r.timezone, "Europe/Moscow")
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.maxIterations, 6)
        XCTAssertEqual(r.rev, 1)
    }

    func testOldYouGileSinkDecodesLeniently() throws {
        // Старый sink с YouGile-полями НЕ должен ронять декод (привязки убраны).
        let json = #"{"id":"x","name":"n","sinks":[{"kind":"yougile","mode":"create_task","columnId":"c1"}]}"#
        let r = try dec.decode(Routine.self, from: Data(json.utf8))
        XCTAssertEqual(r.sinks.first?.kind, .unknown) // неизвестный вид → unknown, без краша
    }

    func testUnknownEnumValuesFallBack() throws {
        let json = """
        {"id":"run","routineId":"r","trigger":"future_trigger","status":"weird_future",
         "startedAt":"2026-06-27T09:00:00.000Z",
         "sinkResults":[{"kind":"future_sink","status":"ok"}]}
        """
        let run = try dec.decode(RunRecord.self, from: Data(json.utf8))
        XCTAssertEqual(run.status, .unknown)
        XCTAssertEqual(run.trigger, .unknown)
        XCTAssertEqual(run.sinkResults.first?.kind, .unknown)
    }

    func testRunRecordListOmitsHeavyFields() throws {
        let json = """
        {"id":"run","routineId":"r","trigger":"schedule","status":"ok",
         "startedAt":"2026-06-27T09:00:00.000Z","finishedAt":"2026-06-27T09:01:00.000Z",
         "usage":{"promptTokens":10,"completionTokens":5,"totalTokens":15,"costUsd":null}}
        """
        let run = try dec.decode(RunRecord.self, from: Data(json.utf8))
        XCTAssertEqual(run.status, .ok)
        XCTAssertEqual(run.outputMarkdown, "")
        XCTAssertTrue(run.toolTranscript.isEmpty)
        XCTAssertEqual(run.usage.totalTokens, 15)
    }

    func testAgentSettingsDecodesMaskedWithoutSecret() throws {
        let json = """
        {"provider":"deepseek","defaultModel":"deepseek-chat","defaultTimezone":"Europe/Moscow",
         "hasLlmKey":true,"llmKeyHint":"…ab12","updatedAt":"2026-06-27T00:00:00.000Z"}
        """
        let s = try dec.decode(AgentSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.provider, .deepseek)
        XCTAssertTrue(s.hasLlmKey)
        XCTAssertEqual(s.llmKeyHint, "…ab12")
    }

    func testRoutineRoundTrip() throws {
        var r = Routine()
        r.id = "r9"; r.name = "Имя"; r.prompt = "p"; r.cron = "0 9 * * *"; r.rev = 2
        r.sinks = [RoutineSinkConfig(kind: .vpsLocal)]
        let back = try dec.decode(Routine.self, from: enc.encode(r))
        XCTAssertEqual(back.id, "r9")
        XCTAssertEqual(back.rev, 2)
        XCTAssertEqual(back.sinks.first?.kind, .vpsLocal)
    }

    // MARK: - MCP-серверы (синхронизация из приложения)

    func testMCPServerDTOEncodesConfig() throws {
        var s = MCPServer()
        s.name = "yougile"; s.command = "npx"
        s.args = ["-y", "mcp-remote", "https://x/mcp"]
        s.env = ["TOKEN": "v"]; s.enabled = true

        struct Decoded: Decodable {
            var id: String; var name: String; var command: String
            var args: [String]; var env: [String: String]; var enabled: Bool
        }
        let d = try dec.decode(Decoded.self, from: enc.encode(MCPServerDTO(s)))
        XCTAssertEqual(d.name, "yougile")
        XCTAssertEqual(d.command, "npx")
        XCTAssertEqual(d.args, ["-y", "mcp-remote", "https://x/mcp"])
        XCTAssertEqual(d.env["TOKEN"], "v")
        XCTAssertTrue(d.enabled)
        XCTAssertFalse(d.id.isEmpty) // UUID-строка
    }

    func testMcpServerStatusDecodes() throws {
        let json = #"{"items":[{"id":"s1","name":"yougile","command":"npx","enabled":true,"connected":true,"toolCount":7,"error":null}]}"#
        let resp = try dec.decode(McpServersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.items.count, 1)
        XCTAssertEqual(resp.items[0].toolCount, 7)
        XCTAssertTrue(resp.items[0].connected)
        XCTAssertNil(resp.items[0].error)
    }

    // MARK: - Кодирование запросов (nil-поля опускаются)

    func testCreateRequestOmitsNilFields() throws {
        let req = CreateRoutineRequest(name: "N", prompt: "P", cron: "0 9 * * *")
        let s = String(data: try enc.encode(req), encoding: .utf8)!
        XCTAssertTrue(s.contains("\"name\""))
        XCTAssertTrue(s.contains("\"cron\""))
        XCTAssertFalse(s.contains("\"timezone\""))
        XCTAssertFalse(s.contains("\"sinks\""))
    }

    func testUpdateAgentSettingsOmitsNilSecret() throws {
        let req = UpdateAgentSettingsRequest(provider: "deepseek", defaultModel: "deepseek-chat")
        let s = String(data: try enc.encode(req), encoding: .utf8)!
        XCTAssertTrue(s.contains("\"provider\""))
        XCTAssertTrue(s.contains("\"defaultModel\""))
        XCTAssertFalse(s.contains("\"llmApiKey\""))
        XCTAssertFalse(s.contains("yougile"))
    }

    func testSinkConfigEncodesSnakeCaseValue() throws {
        let s = String(data: try enc.encode(RoutineSinkConfig(kind: .vpsLocal)), encoding: .utf8)!
        XCTAssertTrue(s.contains("vps_local"))
    }

    func testErrorResponseDecodes() throws {
        let json = #"{"error":{"code":"conflict","message":"устарел rev"}}"#
        let e = try dec.decode(AgentErrorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(e.error.code, "conflict")
    }

    // MARK: - Построители запроса VPSAgentClient (чистые, без сети)

    func testMakeURLJoinsBaseTrailingSlashAndQuery() {
        let url = VPSAgentClient.makeURL(
            base: "https://vps.example/",
            path: "/agent/routines",
            query: [URLQueryItem(name: "limit", value: "20")])
        XCTAssertEqual(url?.absoluteString, "https://vps.example/agent/routines?limit=20")
    }

    func testMakeRequestSetsMethodHeadersBody() throws {
        let body = Data("{\"k\":1}".utf8)
        let req = try VPSAgentClient.makeRequest(
            base: "https://h", token: "T", method: "PUT",
            path: "/agent/mcp-servers", body: body)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.httpBody, body)
        XCTAssertEqual(req.url?.path, "/agent/mcp-servers")
    }
}
