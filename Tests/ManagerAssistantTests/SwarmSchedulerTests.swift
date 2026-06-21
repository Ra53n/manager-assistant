// SwarmSchedulerTests — парсер зависимостей и топосортировка волн (рой агентов).
// Критично: волны должны корректно распараллеливать независимые шаги и безопасно
// откатываться к последовательному выполнению при цикле/мусоре.

import XCTest
@testable import ManagerAssistant

final class SwarmSchedulerTests: XCTestCase {

    // MARK: parseDeps

    func testParseDepsBasic() {
        let text = """
        1. A
        2. B
        3. C
        ЗАВИСИМОСТИ:
        3: 1,2
        """
        let deps = PipelinePrompts.parseDeps(text, stepCount: 3)
        XCTAssertEqual(deps[0], [])
        XCTAssertEqual(deps[1], [])
        XCTAssertEqual(deps[2], [0, 1])   // 1-based → 0-based
    }

    func testParseDepsMissingSection() {
        let deps = PipelinePrompts.parseDeps("1. A\n2. B", stepCount: 2)
        XCTAssertEqual(deps, [[], []])
    }

    func testParseDepsDropsOutOfRangeSelfAndDuplicates() {
        let text = """
        ЗАВИСИМОСТИ:
        2: 1, 1, 5, 0, 2
        """
        let deps = PipelinePrompts.parseDeps(text, stepCount: 2)
        XCTAssertEqual(deps[1], [0])      // 1→0 ок; дубль убран; 5 вне диапазона; 0 невалиден; 2==self убран
    }

    func testParseDepsZeroSteps() {
        XCTAssertTrue(PipelinePrompts.parseDeps("ЗАВИСИМОСТИ:\n1: 2", stepCount: 0).isEmpty)
    }

    // MARK: computeWaves

    func testWavesAllIndependent() {
        let waves = PipelinePrompts.computeWaves(n: 3, deps: [[], [], []])
        XCTAssertEqual(waves, [[0, 1, 2]])   // всё в одной волне
    }

    func testWavesLinearChain() {
        let deps: [Set<Int>] = [[], [0], [1]]
        let waves = PipelinePrompts.computeWaves(n: 3, deps: deps)
        XCTAssertEqual(waves, [[0], [1], [2]])
    }

    func testWavesDiamond() {
        // 0 → {1,2} → 3
        let deps: [Set<Int>] = [[], [0], [0], [1, 2]]
        let waves = PipelinePrompts.computeWaves(n: 4, deps: deps)
        XCTAssertEqual(waves, [[0], [1, 2], [3]])
    }

    func testWavesCycleFallsBackToSequential() {
        let deps: [Set<Int>] = [[1], [0]]    // 0↔1 цикл
        let waves = PipelinePrompts.computeWaves(n: 2, deps: deps)
        XCTAssertEqual(waves, [[0], [1]])    // безопасный фолбэк
    }

    func testWavesEmpty() {
        XCTAssertEqual(PipelinePrompts.computeWaves(n: 0, deps: []), [])
    }

    func testWavesDepsSizeMismatchIsSafe() {
        // deps короче n — не должно падать, недостающие = без зависимостей.
        let waves = PipelinePrompts.computeWaves(n: 3, deps: [[]])
        XCTAssertEqual(waves, [[0, 1, 2]])
    }

    func testParseAndComputeIntegration() {
        let text = """
        1. подготовка
        2. модуль A
        3. модуль B
        4. сборка
        ЗАВИСИМОСТИ:
        2: 1
        3: 1
        4: 2,3
        """
        let n = 4
        let deps = PipelinePrompts.parseDeps(text, stepCount: n)
        let waves = PipelinePrompts.computeWaves(n: n, deps: deps)
        XCTAssertEqual(waves, [[0], [1, 2], [3]])
    }

    // MARK: chunked

    func testChunked() {
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(into: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual([1, 2, 3].chunked(into: 5), [[1, 2, 3]])
        XCTAssertEqual([Int]().chunked(into: 3), [])
        XCTAssertEqual([1, 2].chunked(into: 0), [[1, 2]])   // защита от деления на 0
    }
}
