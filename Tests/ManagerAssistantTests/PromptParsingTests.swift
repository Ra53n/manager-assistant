// PromptParsingTests — парсеры и сборка промптов PipelinePrompts.
// Защищают разбор плана, вердикта, уточняющего вопроса, чистку маркеров,
// распознавание запроса смены стадии и инжекцию указаний пользователя.

import XCTest
@testable import ManagerAssistant

final class PromptParsingTests: XCTestCase {

    // MARK: parsePlanSteps

    func testParsePlanNumbered() {
        let steps = PipelinePrompts.parsePlanSteps("1. Раз\n2) Два\n- Три\n• Четыре")
        XCTAssertEqual(steps, ["Раз", "Два", "Три", "Четыре"])
    }

    func testParsePlanStopsAtDepsSection() {
        let steps = PipelinePrompts.parsePlanSteps("1. A\n2. B\nЗАВИСИМОСТИ:\n2: 1")
        XCTAssertEqual(steps, ["A", "B"])   // строки зависимостей — не шаги
    }

    func testParsePlanEmptyFallsBackToWholeText() {
        let steps = PipelinePrompts.parsePlanSteps("просто текст без нумерации")
        XCTAssertEqual(steps, ["просто текст без нумерации"])
    }

    func testParsePlanDropsMarkerFinalizerSteps() {
        // Планировщик иногда включает протокольный маркер как «шаг» — он невыполним
        // и зациклил бы проверку; такие шаги должны отбрасываться.
        let steps = PipelinePrompts.parsePlanSteps("1. Сделай A\n2. Сделай B\n3. Заверши ответ строкой NEXT_STEP")
        XCTAssertEqual(steps, ["Сделай A", "Сделай B"])
    }

    // MARK: parseVerdict

    func testVerdictPassFail() {
        XCTAssertTrue(PipelinePrompts.parseVerdict("всё ок\nВЕРДИКТ: ВЫПОЛНЕНО"))
        XCTAssertFalse(PipelinePrompts.parseVerdict("есть проблемы\nВЕРДИКТ: НЕ ВЫПОЛНЕНО"))
    }

    func testVerdictUsesLastOccurrence() {
        let t = "ВЕРДИКТ: НЕ ВЫПОЛНЕНО\n...исправили...\nВЕРДИКТ: ВЫПОЛНЕНО"
        XCTAssertTrue(PipelinePrompts.parseVerdict(t))
    }

    func testVerdictAmbiguousDefaultsTrue() {
        XCTAssertTrue(PipelinePrompts.parseVerdict("без явного вердикта"))
    }

    // MARK: маркеры

    func testWantsMarkers() {
        XCTAssertTrue(PipelinePrompts.wantsNextStep("готово\nNEXT_STEP"))
        XCTAssertTrue(PipelinePrompts.wantsReplan("план плох\nREPLAN"))
        XCTAssertFalse(PipelinePrompts.wantsReplan("обычный ответ"))
    }

    func testStripMarkersRemovesServiceLines() {
        let raw = """
        Результат шага.
        ЗАВИСИМОСТИ:
        2: 1
        NEXT_STEP
        """
        let cleaned = PipelinePrompts.stripMarkers(raw)
        XCTAssertEqual(cleaned, "Результат шага.")
        XCTAssertFalse(cleaned.contains("NEXT_STEP"))
        XCTAssertFalse(cleaned.contains("ЗАВИСИМОСТИ"))
    }

    func testStripMarkersRemovesAskBlock() {
        let raw = "ASK_USER\nQUESTION: что?\nOPTION: a\nOPTION: b"
        XCTAssertEqual(PipelinePrompts.stripMarkers(raw), "")
    }

    // MARK: parseQuestion

    func testParseQuestionValid() {
        let raw = """
        ASK_USER
        QUESTION: Какой формат вывода?
        OPTION: JSON
        OPTION: Текст
        """
        let q = PipelinePrompts.parseQuestion(raw)
        XCTAssertEqual(q?.question, "Какой формат вывода?")
        XCTAssertEqual(q?.options, ["JSON", "Текст"])
    }

    func testParseQuestionRequiresAllParts() {
        XCTAssertNil(PipelinePrompts.parseQuestion("QUESTION: нет маркера\nOPTION: a"))   // нет ASK_USER
        XCTAssertNil(PipelinePrompts.parseQuestion("ASK_USER\nQUESTION: без вариантов")) // нет OPTION
        XCTAssertNil(PipelinePrompts.parseQuestion("ASK_USER\nOPTION: a\nOPTION: b"))     // нет QUESTION
        XCTAssertNil(PipelinePrompts.parseQuestion("обычный ответ"))
    }

    func testParseQuestionDedupAndCap() {
        let raw = """
        ASK_USER
        QUESTION: Q?
        OPTION: a
        OPTION: A
        OPTION: b
        OPTION: c
        OPTION: d
        OPTION: e
        """
        let q = PipelinePrompts.parseQuestion(raw)
        XCTAssertEqual(q?.options.count, 4)          // дедуп (a==A) + ограничение до 4
        XCTAssertEqual(q?.options.first, "a")
    }

    // MARK: parseStateChangeRequest

    func testStateChangeRequests() {
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("вернись к планированию"), .planning)
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("перейди к проверке"), .validation)
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("назад к выполнению"), .execution)
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("перейти к ответу"), .answer)
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("go to validation"), .validation)
    }

    func testStateChangeRequiresVerb() {
        // Без глагола перехода — это обычное уточнение, не смена стадии.
        XCTAssertNil(PipelinePrompts.parseStateChangeRequest("доработай ответ подробнее"))
        XCTAssertNil(PipelinePrompts.parseStateChangeRequest("проверь ещё раз вот это"))
    }

    func testStateChangeRequiresPreposition() {
        // Глагол + метка БЕЗ предлога «к»/«to» — это уточнение, НЕ навигация
        // (иначе «верни ответ покороче» ошибочно ушло бы в смену стадии).
        XCTAssertNil(PipelinePrompts.parseStateChangeRequest("верни ответ покороче"))
        XCTAssertNil(PipelinePrompts.parseStateChangeRequest("верни выполнение шага без воды"))
        // С предлогом — это навигация.
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("верни к ответу"), .answer)
        XCTAssertEqual(PipelinePrompts.parseStateChangeRequest("back to planning please"), .planning)
    }

    // MARK: buildPrompt — указания пользователя

    func testBuildPromptInjectsGuidance() {
        var ctx = TaskContext(task: "сделать X", state: .execution)
        ctx.plan = ["шаг1"]; ctx.current = "шаг1"; ctx.total = 1
        ctx.guidance = ["учитывай требование Y"]
        let p = PipelinePrompts.buildPrompt(query: ctx.task, ctx: ctx, profile: "")
        XCTAssertTrue(p.contains("УКАЗАНИЯ ПОЛЬЗОВАТЕЛЯ"))
        XCTAssertTrue(p.contains("учитывай требование Y"))
    }

    func testBuildPromptNoGuidanceBlockWhenEmpty() {
        let ctx = TaskContext(task: "T", state: .planning)
        let p = PipelinePrompts.buildPrompt(query: ctx.task, ctx: ctx, profile: "")
        XCTAssertFalse(p.contains("УКАЗАНИЯ ПОЛЬЗОВАТЕЛЯ"))
    }

    // MARK: Диспетчер переходов (роутер)

    func testParseRouterDecisionForms() {
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ок\nДЕЙСТВИЕ: REDO_CURRENT"), .redoCurrent)
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: BACK"), .back)
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("надо переделать\nДЕЙСТВИЕ: REPLAN"), .replan)
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: RESTART"), .restart)
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: REFUSE"), .refuse)
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: GOTO:validation"), .goto(.validation))
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: GOTO: проверка"), .goto(.validation))
        XCTAssertEqual(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: GOTO:планирование"), .goto(.planning))
    }

    func testParseRouterDecisionJunk() {
        XCTAssertNil(PipelinePrompts.parseRouterDecision("просто текст без маркера"))
        XCTAssertNil(PipelinePrompts.parseRouterDecision("ДЕЙСТВИЕ: НЕПОНЯТНО"))
    }

    func testRouterTargetMapping() {
        XCTAssertNil(PipelinePrompts.routerTarget(.redoCurrent, from: .execution))
        XCTAssertNil(PipelinePrompts.routerTarget(.refuse, from: .validation))
        XCTAssertEqual(PipelinePrompts.routerTarget(.back, from: .validation), .execution)
        XCTAssertEqual(PipelinePrompts.routerTarget(.replan, from: .validation), .planning)
        XCTAssertEqual(PipelinePrompts.routerTarget(.restart, from: .execution), .planning)
        XCTAssertEqual(PipelinePrompts.routerTarget(.goto(.answer), from: .validation), .answer)
    }

    func testStripRouterMarker() {
        XCTAssertEqual(PipelinePrompts.stripRouterMarker("Вернёмся к проверке.\nДЕЙСТВИЕ: BACK"), "Вернёмся к проверке.")
        XCTAssertEqual(PipelinePrompts.stripRouterMarker("без маркера"), "без маркера")
    }

    func testTransitionRulesBlockNoViolationMarker() {
        // Скрытый инвариант переходов НЕ должен содержать маркер инвариантов (иначе ложный обрыв).
        let block = PipelinePrompts.transitionRulesBlock(from: .planning)
        XCTAssertFalse(block.contains(InvariantValidator.violationMarker))
        XCTAssertTrue(block.contains("Выполнение"))           // из planning доступно только выполнение
        XCTAssertTrue(PipelinePrompts.transitionRulesBlock(from: .answer).contains("терминальная"))
    }

    // MARK: Инварианты реально попадают в промпты

    func testInvariantsInjectedIntoPrompts() {
        let inv = Invariant(kind: .noBanned, name: "ETF", banned: ["ETF"], enforcement: .both)
        // Системный промпт стадии содержит блок ограничений и запрещённый термин.
        let sys = PipelinePrompts.systemPrompt(for: .answer, invariants: [inv])
        XCTAssertTrue(sys.contains("INVARIANTS"))
        XCTAssertTrue(sys.contains("ETF"))
        // User-сообщение стадии — тоже.
        var ctx = TaskContext(task: "куда вложить деньги", state: .answer)
        ctx.done = ["шаг"]
        let user = PipelinePrompts.buildPrompt(query: ctx.task, ctx: ctx, profile: "", invariants: [inv])
        XCTAssertTrue(user.contains("ETF"))
        // Промпт подагента роя — тоже.
        XCTAssertTrue(PipelinePrompts.subAgentSystemPrompt(invariants: [inv]).contains("ETF"))
    }

    func testInvariantPromptOmittedWhenCodeOnly() {
        // enforcement .code — НЕ показывается в промпте (только код-проверка).
        let inv = Invariant(kind: .noBanned, name: "X", banned: ["X"], enforcement: .code)
        XCTAssertFalse(PipelinePrompts.systemPrompt(for: .answer, invariants: [inv]).contains("INVARIANTS"))
    }

    func testValidationStageOmitsInvariantBlock() {
        // Проверяющему инварианты НЕ кладём — иначе он флагает их маркером и отчёт уходит «в ответ».
        let inv = Invariant(kind: .noBanned, name: "ETF", banned: ["ETF"], enforcement: .both)
        XCTAssertFalse(PipelinePrompts.systemPrompt(for: .validation, invariants: [inv]).contains("INVARIANTS"))
        var ctx = TaskContext(task: "T", state: .validation)
        ctx.done = ["шаг"]
        XCTAssertFalse(PipelinePrompts.buildPrompt(query: ctx.task, ctx: ctx, profile: "", invariants: [inv]).contains("INVARIANTS"))
    }

    // MARK: subAgentPrompt — узкий контекст

    func testSubAgentPromptIncludesOnlyDepOutputs() {
        let plan = ["A", "B", "C"]
        let results = ["вывод A", "вывод B", ""]
        let p = PipelinePrompts.subAgentPrompt(task: "T", stepIndex: 2, plan: plan,
                                               deps: [0], stepResults: results, profile: "")
        XCTAssertTrue(p.contains("вывод A"))        // зависимость включена
        XCTAssertFalse(p.contains("вывод B"))       // НЕ-зависимость не включена (экономия контекста)
        XCTAssertTrue(p.contains("C"))              // текущий шаг
    }

    // MARK: dialogContext — контекст предыдущего диалога для прогона FSM

    func testDialogContextKeepsUserAndFinalAnswersOnly() {
        var planning = ChatMessage(role: .assistant, content: "план этапа")
        planning.state = .planning
        var execution = ChatMessage(role: .assistant, content: "шаг 1 сделан")
        execution.state = .execution
        var answer = ChatMessage(role: .assistant, content: "итоговый ответ")
        answer.state = .answer
        let msgs = [ChatMessage(role: .user, content: "составь стратегию"),
                    planning, execution, answer,
                    ChatMessage(role: .assistant, content: "обычный ответ вне FSM")]
        let dlg = PipelinePrompts.dialogContext(messages: msgs)
        XCTAssertTrue(dlg.contains("Пользователь: составь стратегию"))
        XCTAssertTrue(dlg.contains("Ассистент: итоговый ответ"))
        XCTAssertTrue(dlg.contains("Ассистент: обычный ответ вне FSM"))
        XCTAssertFalse(dlg.contains("план этапа"))          // промежуточные этапы — шум
        XCTAssertFalse(dlg.contains("шаг 1 сделан"))
    }

    func testDialogContextLimitsAndTruncates() {
        let msgs = (1...10).map { ChatMessage(role: .user, content: "вопрос \($0) " + String(repeating: "х", count: 600)) }
        let dlg = PipelinePrompts.dialogContext(messages: msgs, maxTurns: 3, maxTurnChars: 50)
        XCTAssertFalse(dlg.contains("вопрос 7"))            // только последние 3
        XCTAssertTrue(dlg.contains("вопрос 8"))
        XCTAssertTrue(dlg.contains("вопрос 10"))
        XCTAssertFalse(dlg.contains(String(repeating: "х", count: 51)))   // усечено
        XCTAssertEqual(PipelinePrompts.dialogContext(messages: []), "")
    }

    func testBuildPromptInjectsDialogBlock() {
        let ctx = TaskContext(task: "T", state: .planning)
        let with = PipelinePrompts.buildPrompt(query: "T", ctx: ctx, profile: "",
                                               dialog: "Пользователь: зафиксируй ограничение")
        XCTAssertTrue(with.contains("[КОНТЕКСТ ДИАЛОГА"))
        XCTAssertTrue(with.contains("зафиксируй ограничение"))
        XCTAssertTrue(with.contains("НЕ фрагментами базы знаний"))
        let without = PipelinePrompts.buildPrompt(query: "T", ctx: ctx, profile: "")
        XCTAssertFalse(without.contains("[КОНТЕКСТ ДИАЛОГА"))
    }
}
