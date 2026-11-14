import Foundation
import XCTest
@testable import my_window_pip

/// 静止画面 / 原生全屏 Space 下整屏捕获不再进入「每 2 秒重启一次流」的风暴。
final class DisplayStallRecoveryTests: XCTestCase {

    private func enterHealthCheckPhase(_ recovery: inout DisplayStallRecovery) {
        for _ in 0..<(DisplayStallRecovery.restartDelays.count + 1) {
            _ = recovery.schedule()
        }
    }

    func testRestartsBackOffBeforeSwitchingToHealthChecks() {
        var recovery = DisplayStallRecovery()
        XCTAssertEqual(recovery.schedule(), .restart(delay: 2))
        XCTAssertEqual(recovery.schedule(), .restart(delay: 4))
        XCTAssertEqual(recovery.schedule(), .restart(delay: 8))
        XCTAssertEqual(recovery.schedule(), .healthCheck(delay: 30))
        XCTAssertEqual(recovery.schedule(), .healthCheck(delay: 30))
    }

    func testDelaysAreStrictlyIncreasing() {
        let delays = DisplayStallRecovery.restartDelays
        XCTAssertTrue((delays.first ?? 0) >= 2)
        for index in 1..<delays.count {
            XCTAssertTrue(delays[index] > delays[index - 1])
        }
    }

    func testRestartBudgetIsCappedNoMatterHowManyStallsArrive() {
        var recovery = DisplayStallRecovery()
        for _ in 0..<50 { _ = recovery.schedule() }
        XCTAssertEqual(recovery.restartCount, DisplayStallRecovery.restartDelays.count)
        XCTAssertEqual(recovery.schedule(), .healthCheck(delay: 30))
    }

    func testRealFrameResetsTheBackOffBudget() {
        var recovery = DisplayStallRecovery()
        _ = recovery.schedule()
        _ = recovery.schedule()
        recovery.reset()
        XCTAssertEqual(recovery.restartCount, 0)
        XCTAssertEqual(recovery.healthChecks, 0)
        XCTAssertFalse(recovery.displayIsMissing)
        XCTAssertEqual(recovery.schedule(), .restart(delay: 2))
    }

    func testSteadyDisplayOnlyGetsOneSparseRestart() {
        var recovery = DisplayStallRecovery()
        enterHealthCheckPhase(&recovery)
        for _ in 1..<DisplayStallRecovery.healthChecksPerSparseRestart {
            XCTAssertFalse(recovery.observeHealth(displayPresent: true))
        }
        XCTAssertTrue(recovery.observeHealth(displayPresent: true))
        // 稀疏重启不消耗退避预算，也不会退化成每 30 秒重启一次。
        XCTAssertFalse(recovery.observeHealth(displayPresent: true))
        XCTAssertEqual(recovery.restartCount, DisplayStallRecovery.restartDelays.count)
    }

    func testMissingDisplayStaysQuiet() {
        var recovery = DisplayStallRecovery()
        enterHealthCheckPhase(&recovery)
        XCTAssertFalse(recovery.observeHealth(displayPresent: false))
        XCTAssertTrue(recovery.displayIsMissing)
        XCTAssertFalse(recovery.observeHealth(displayPresent: false))
        XCTAssertEqual(recovery.healthChecks, 0)
    }

    func testDisplayReappearingRestartsAndRestoresFullBudget() {
        var recovery = DisplayStallRecovery()
        enterHealthCheckPhase(&recovery)
        XCTAssertFalse(recovery.observeHealth(displayPresent: false))
        XCTAssertTrue(recovery.observeHealth(displayPresent: true))
        XCTAssertFalse(recovery.displayIsMissing)
        XCTAssertEqual(recovery.restartCount, 0)
        XCTAssertEqual(recovery.schedule(), .restart(delay: 2))
    }

    func testActionDelays() {
        XCTAssertEqual(DisplayStallRecovery.Action.restart(delay: 8).delay, 8)
        XCTAssertEqual(DisplayStallRecovery.Action.healthCheck(delay: 30).delay, 30)
    }
}
