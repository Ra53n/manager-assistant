// MigrationTests — миграционная устойчивость Codable: новые поля сохраняются и
// читаются, а СТАРЫЙ JSON (без новых ключей) декодируется с дефолтами (а не падает
// в .corrupt.json). Это главный регрессионный страж против ловушки из CLAUDE.md.

import XCTest
@testable import ManagerAssistant

final class MigrationTests: XCTestCase {

    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    // MARK: TaskContext

    func testTaskContextRoundTripNewFields() throws {
        var ctx = TaskContext(task: "T", state: .execution)
        ctx.guidance = ["уточнение 1", "уточнение 2"]
        ctx.pendingQuestion = PendingQuestion(question: "Q?", options: ["a", "b"])
        ctx.waves = [[0, 1], [2]]
        ctx.waveIndex = 1
        ctx.stepResults = ["r0", "r1", ""]
        ctx.stepDeps = [[], [], [0, 1]]
        ctx.status = .awaitingInput

        let data = try enc.encode(ctx)
        let back = try dec.decode(TaskContext.self, from: data)

        XCTAssertEqual(back.guidance, ctx.guidance)
        XCTAssertEqual(back.pendingQuestion, ctx.pendingQuestion)
        XCTAssertEqual(back.waves, ctx.waves)
        XCTAssertEqual(back.waveIndex, 1)
        XCTAssertEqual(back.stepResults, ctx.stepResults)
        XCTAssertEqual(back.stepDeps, ctx.stepDeps)
        XCTAssertEqual(back.status, .awaitingInput)
        XCTAssertEqual(back.state, .execution)
    }

    func testTaskContextOldJSONGetsDefaults() throws {
        // Старый контекст без новых ключей — поля получают дефолты, decode не падает.
        let json = #"{"id":"\#(UUID().uuidString)","task":"старая задача","state":"planning","step":0}"#
        let data = Data(json.utf8)
        let ctx = try dec.decode(TaskContext.self, from: data)
        XCTAssertEqual(ctx.task, "старая задача")
        XCTAssertEqual(ctx.guidance, [])
        XCTAssertNil(ctx.pendingQuestion)
        XCTAssertEqual(ctx.waves, [])
        XCTAssertEqual(ctx.waveIndex, 0)
        XCTAssertEqual(ctx.stepResults, [])
        XCTAssertEqual(ctx.stepDeps, [])
    }

    func testTaskRunStatusUnknownDecodesToPaused() throws {
        // Неизвестный статус (например, от будущей версии) → .paused (возобновляемо).
        let json = #"{"task":"T","state":"execution","status":"someFutureStatus"}"#
        let ctx = try dec.decode(TaskContext.self, from: Data(json.utf8))
        XCTAssertEqual(ctx.status, .paused)
    }

    func testAwaitingInputStatusRoundTrips() throws {
        let json = #"{"task":"T","state":"planning","status":"awaitingInput"}"#
        let ctx = try dec.decode(TaskContext.self, from: Data(json.utf8))
        XCTAssertEqual(ctx.status, .awaitingInput)
    }

    // MARK: GenerationSettings

    func testGenerationSettingsRoundTripSwarm() throws {
        var s = GenerationSettings()
        s.swarmEnabled = false
        s.maxParallelAgents = 5
        let back = try dec.decode(GenerationSettings.self, from: enc.encode(s))
        XCTAssertEqual(back.swarmEnabled, false)
        XCTAssertEqual(back.maxParallelAgents, 5)
    }

    func testGenerationSettingsOldJSONDefaults() throws {
        // Старые настройки без swarm-полей → дефолты (рой ВКЛ, 3 подагента).
        let json = #"{"provider":"deepseek","model":"deepseek-chat","temperature":0.7}"#
        let s = try dec.decode(GenerationSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.model, "deepseek-chat")
        XCTAssertEqual(s.swarmEnabled, true)
        XCTAssertEqual(s.maxParallelAgents, 3)
    }

    // MARK: MsgNode wave-поля (миграция дерева сообщений)

    func testMsgNodeOldJSONWithoutWaveFields() throws {
        // Старый узел без waveGroupID/waveSize — Optional → nil, decode НЕ падает.
        let json = #"{"id":"\#(UUID().uuidString)","role":"assistant","content":"привет"}"#
        let node = try dec.decode(MsgNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.content, "привет")
        XCTAssertNil(node.waveGroupID)
        XCTAssertNil(node.waveSize)
    }

    func testMsgNodeRoundTripWaveFields() throws {
        let gid = UUID()
        var node = MsgNode(id: UUID(), parentID: nil, role: .assistant, content: "шаг",
                           state: .execution, step: 1, total: 3)
        node.waveGroupID = gid
        node.waveSize = 3
        let back = try dec.decode(MsgNode.self, from: enc.encode(node))
        XCTAssertEqual(back.waveGroupID, gid)
        XCTAssertEqual(back.waveSize, 3)
        XCTAssertEqual(back.step, 1)
    }

    func testChatLiveSubAgentsNotPersisted() throws {
        var chat = Chat(title: "T")
        chat.liveSubAgents = [LiveSubAgent(id: 0, title: "шаг", status: .running)]
        chat.isDeciding = true
        let back = try dec.decode(Chat.self, from: enc.encode(chat))
        XCTAssertTrue(back.liveSubAgents.isEmpty)   // runtime-поля не сохраняются
        XCTAssertFalse(back.isDeciding)
    }

    // MARK: PendingQuestion

    func testPendingQuestionRoundTrip() throws {
        let q = PendingQuestion(question: "Что выбрать?", options: ["X", "Y", "Z"])
        let back = try dec.decode(PendingQuestion.self, from: enc.encode(q))
        XCTAssertEqual(back, q)
    }

    // MARK: Chat (контейнер) с taskContext

    func testChatPersistsTaskContext() throws {
        var chat = Chat(title: "Тест")
        var ctx = TaskContext(task: "T", state: .validation)
        ctx.waves = [[0]]
        ctx.guidance = ["g"]
        chat.taskContext = ctx
        let back = try dec.decode(Chat.self, from: enc.encode(chat))
        XCTAssertEqual(back.taskContext?.state, .validation)
        XCTAssertEqual(back.taskContext?.guidance, ["g"])
        XCTAssertEqual(back.taskContext?.waves, [[0]])
        // Рантайм-поле баннера НЕ сохраняется (всегда nil после декода).
        XCTAssertNil(back.stateChangeError)
    }
}
