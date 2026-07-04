// FSMTests — таблица переходов конечного автомата задачи и страж transitioned(to:).
// Эти инварианты — фундамент детерминизма; тесты ловят случайную правку таблицы.

import XCTest
@testable import ManagerAssistant

final class FSMTests: XCTestCase {

    /// Эталонная таблица допустимых переходов — единственный источник истины.
    private let expected: [TaskState: Set<TaskState>] = [
        .planning:   [.execution],
        .execution:  [.validation, .planning],
        .validation: [.answer, .execution, .planning],
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

    /// Нелегальные «прыжки» запрещены (planning↛answer/validation, execution↛answer).
    func testIllegalJumpsDisallowed() {
        XCTAssertFalse(TaskFSM.allows(.planning, to: .answer))
        XCTAssertFalse(TaskFSM.allows(.planning, to: .validation))
        XCTAssertFalse(TaskFSM.allows(.execution, to: .answer))
        XCTAssertFalse(TaskFSM.allows(.answer, to: .planning))
    }

    /// validation → planning теперь ЛЕГАЛЕН (перепланировать «кардинально не так»).
    func testValidationToPlanningAllowed() {
        XCTAssertTrue(TaskFSM.allows(.validation, to: .planning))
        XCTAssertEqual(TaskContext(task: "T", state: .validation).transitioned(to: .planning).state, .planning)
    }

    // MARK: - День 15: контролируемые переходы (явные требования задания)

    /// «Нельзя делать финал без валидации»: в стадию «Ответ» можно ТОЛЬКО из «Проверки».
    func testNoFinalWithoutValidation() {
        for s in TaskState.allCases {
            XCTAssertEqual(TaskFSM.allows(s, to: .answer), s == .validation,
                           "В «Ответ» можно ТОЛЬКО из «Проверки» — пробовали из \(s.rawValue)")
        }
    }

    /// «Нельзя делать реализацию до утверждённого плана»: из «Планирования» можно ТОЛЬКО
    /// в «Выполнение» (нельзя перепрыгнуть сразу в проверку или ответ).
    func testNoImplementationBeforePlan() {
        XCTAssertEqual(Set(TaskFSM.transitions[.planning, default: []]), [.execution])
        XCTAssertFalse(TaskFSM.allows(.planning, to: .validation))
        XCTAssertFalse(TaskFSM.allows(.planning, to: .answer))
    }

    /// «Ассистент не может перепрыгнуть этап»: ни один переход не пропускает стадию.
    func testNoStageSkipping() {
        XCTAssertFalse(TaskFSM.allows(.planning, to: .validation))   // через «Выполнение»
        XCTAssertFalse(TaskFSM.allows(.planning, to: .answer))       // через всё
        XCTAssertFalse(TaskFSM.allows(.execution, to: .answer))      // через «Проверку»
    }

    /// Готовность: ВПЕРЁД нельзя «перепрыгнуть» через невыполненный этап — пока этап-
    /// источник не дал результат, прямой переход вперёд недоступен.
    func testForwardTransitionsRequireStageOutput() {
        // Планирование без плана → нельзя в «Выполнение».
        var p = TaskContext(task: "T", state: .planning)
        XCTAssertFalse(p.canTransition(to: .execution))
        p.plan = ["шаг1", "шаг2"]
        XCTAssertTrue(p.canTransition(to: .execution))

        // Выполнение без завершённых шагов → нельзя в «Проверку».
        var ex = TaskContext(task: "T", state: .execution)
        ex.plan = ["a", "b"]; ex.done = ["вывод a"]      // 1/2 — не завершено
        XCTAssertFalse(ex.canTransition(to: .validation))
        ex.done = ["вывод a", "вывод b"]                 // 2/2
        XCTAssertTrue(ex.canTransition(to: .validation))

        // Проверка без вердикта → нельзя в «Ответ».
        var va = TaskContext(task: "T", state: .validation)
        XCTAssertFalse(va.canTransition(to: .answer))
        va.validationResult = "ВЕРДИКТ: ВЫПОЛНЕНО"
        XCTAssertTrue(va.canTransition(to: .answer))
    }

    /// Шаги НАЗАД (переделать/перепланировать) доступны всегда, без условий готовности.
    func testBackwardTransitionsAlwaysAllowed() {
        let ex = TaskContext(task: "T", state: .execution)   // пустой
        XCTAssertTrue(ex.canTransition(to: .planning))       // перепланировать
        let va = TaskContext(task: "T", state: .validation)  // пустой
        XCTAssertTrue(va.canTransition(to: .execution))      // переделать выполнение
        XCTAssertTrue(va.canTransition(to: .planning))       // перепланировать
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
