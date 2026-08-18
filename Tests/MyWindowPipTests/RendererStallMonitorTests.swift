import XCTest
@testable import my_window_pip

final class RendererStallMonitorTests: XCTestCase {

    func testTransientNotReadyDoesNotTriggerRecovery() {
        var monitor = RendererStallMonitor(timeout: 2)

        XCTAssertEqual(monitor.observeNotReady(at: 10), .none)
        XCTAssertEqual(monitor.stallStartedAt, 10)
        XCTAssertEqual(monitor.observeNotReady(at: 11.99), .none)
        XCTAssertEqual(monitor.observeReady(at: 12) ?? -1, 2, accuracy: 0.001)
        XCTAssertFalse(monitor.isTrackingStall)
        XCTAssertNil(monitor.stallStartedAt)
    }

    func testPersistentNotReadyEscalatesInOrder() {
        var monitor = RendererStallMonitor(timeout: 2)

        XCTAssertEqual(monitor.observeNotReady(at: 0), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 1.99), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 2), .flush)
        XCTAssertEqual(monitor.observeNotReady(at: 3.99), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 4), .rebuildLayer)
        XCTAssertEqual(monitor.observeNotReady(at: 5.99), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 6), .restartCapture)
        XCTAssertEqual(monitor.observeNotReady(at: 20), .none)
    }

    func testSuccessfulFrameResetsEscalation() {
        var monitor = RendererStallMonitor(timeout: 2)

        XCTAssertEqual(monitor.observeNotReady(at: 0), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 2), .flush)
        XCTAssertEqual(monitor.observeReady(at: 2.5) ?? -1, 2.5, accuracy: 0.001)

        XCTAssertEqual(monitor.observeNotReady(at: 10), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 12), .flush)
    }

    func testKnownDiscontinuityFlushesImmediately() {
        var monitor = RendererStallMonitor(timeout: 2)

        XCTAssertEqual(monitor.requestImmediateFlush(at: 5), .flush)
        XCTAssertEqual(monitor.requestImmediateFlush(at: 5.1), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 6.99), .none)
        XCTAssertEqual(monitor.observeNotReady(at: 7), .rebuildLayer)
    }

    func testTimeoutHasSafeLowerBound() {
        let monitor = RendererStallMonitor(timeout: 0)
        XCTAssertEqual(monitor.timeout, 0.25)
    }
}
