// FSMTests — таблица переходов конечного автомата задачи и страж transitioned(to:).
// Эти инварианты — фундамент детерминизма; тесты ловят случайную правку таблицы.

import XCTest
@testable import ManagerAssistant

final class FSMTests: XCTestCase {

    /// Эталонная таблица допустимых переходов — единственный источник истины.
    private let expected: [TaskState: Set<TaskState>] = [
        .planning:   [.execution],
        .execution:  [.validation, .planning],
        .validation: [.answer, .execution],
        .answer:     [],
    ]

    /// allows() для ВСЕХ упорядоченных пар совпадает с эталоном.
    func testAllowsMatchesTableForEveryPair() {
        for from in TaskState.allCases {
            for to in TaskState.allCases {
                let want = expected[from, default: []].contains(to)
                XCTAssertEqual(TaskFSM.allows(from, to: to), want,
                               "\(from.rawValue) → \(to.rawValue): ожидали \(want)")
            }
        }
    }

    /// Таблица в коде ровно та же, что эталон (на случай добавления/удаления стрелок).
    func testTransitionsTableExact() {
        for from in TaskState.allCases {
            let actual = Set(TaskFSM.transitions[from, default: []])
            XCTAssertEqual(actual, expected[from, default: []],
                           "переходы из \(from.rawValue) не совпали")
        }
    }

    /// answer — терминал (никаких исходящих переходов).
    func testAnswerIsTerminal() {
        XCTAssertTrue(TaskFSM.transitions[.answer, default: []].isEmpty)
        for to in TaskState.allCases {
            XCTAssertFalse(TaskFSM.allows(.answer, to: to))
        }
    }

    /// Нелегальные «прыжки» запрещены (planning↛answer/validation, validation↛planning).
    func testIllegalJumpsDisallowed() {
        XCTAssertFalse(TaskFSM.allows(.planning, to: .answer))
        XCTAssertFalse(TaskFSM.allows(.planning, to: .validation))
        XCTAssertFalse(TaskFSM.allows(.validation, to: .planning))
        XCTAssertFalse(TaskFSM.allows(.execution, to: .answer))
    }

    /// transitioned(to:) для легального перехода меняет state и сохраняет остальное.
    func testTransitionedLegal() {
        let ctx = TaskContext(task: "T", state: .planning)
        let next = ctx.transitioned(to: .execution)
        XCTAssertEqual(next.state, .execution)
        XCTAssertEqual(next.task, "T")
        XCTAssertEqual(next.id, ctx.id)
    }

    func testTransitionedLegalBackwards() {
        let ctx = TaskContext(task: "T", state: .validation)
        XCTAssertEqual(ctx.transitioned(to: .execution).state, .execution)
        let ctx2 = TaskContext(task: "T", state: .execution)
        XCTAssertEqual(ctx2.transitioned(to: .planning).state, .planning)
    }
}
