import XCTest
@testable import my_window_pip

final class RendererDiagnosticsTests: XCTestCase {

    func testIncidentTimingSeparatesFullStallFromRecoveryLatency() {
        let timing = RendererIncidentTiming(
            stallStartedAt: 10,
            detectedAt: 12,
            recoveredAt: 12.2,
            lastPhaseDuration: 0.2
        )

        XCTAssertEqual(timing.stallDuration, 2.2, accuracy: 0.001)
        XCTAssertEqual(timing.recoveryDuration, 0.2, accuracy: 0.001)
    }

    func testIncidentTimingFallsBackToLastPhaseDuration() {
        let timing = RendererIncidentTiming(
            stallStartedAt: nil,
            detectedAt: nil,
            recoveredAt: 12.2,
            lastPhaseDuration: 0.2
        )

        XCTAssertEqual(timing.stallDuration, 0.2, accuracy: 0.001)
        XCTAssertEqual(timing.recoveryDuration, 0, accuracy: 0.001)
    }

    func testRingBufferKeepsNewestEvents() {
        var diagnostics = RendererDiagnostics(capacity: 2)

        diagnostics.record("one", at: 1)
        diagnostics.record("two", at: 2)
        diagnostics.record("three", at: 3)

        XCTAssertEqual(diagnostics.events, [
            .init(uptime: 2, message: "two"),
            .init(uptime: 3, message: "three"),
        ])
    }

    func testIncidentReportContainsSnapshotAndRelativeHistory() {
        var diagnostics = RendererDiagnostics(capacity: 4)
        diagnostics.record("capture.retune.apply output=640x480", at: 8)
        diagnostics.record("renderer.not-ready.begin", at: 9.25)

        let report = diagnostics.incidentReport(
            id: "R-TEST",
            label: "Cursor · cohort-flow",
            at: 10,
            trigger: "持续 not-ready",
            snapshot: "status=rendering ready=false"
        )

        XCTAssertTrue(report.contains("renderer incident R-TEST"))
        XCTAssertTrue(report.contains("Cursor · cohort-flow"))
        XCTAssertTrue(report.contains("status=rendering ready=false"))
        XCTAssertTrue(report.contains("-2.000s  capture.retune.apply output=640x480"))
        XCTAssertTrue(report.contains("-0.750s  renderer.not-ready.begin"))
    }

    func testCapacityHasSafeLowerBound() {
        let diagnostics = RendererDiagnostics(capacity: 0)
        XCTAssertEqual(diagnostics.capacity, 1)
    }

    func testExternalTextCannotInjectAdditionalLogLines() {
        var diagnostics = RendererDiagnostics(capacity: 2)
        diagnostics.record("title first\nsecond", at: 1)

        let report = diagnostics.incidentReport(
            id: "R-TEST\nforged",
            label: "Cursor\nforged source:",
            at: 2,
            trigger: "not-ready\nforged trigger:",
            snapshot: "ready=false\nforged snapshot:"
        )

        XCTAssertTrue(report.contains("R-TEST forged"))
        XCTAssertTrue(report.contains("Cursor forged source:"))
        XCTAssertTrue(report.contains("title first second"))
        XCTAssertFalse(report.contains("\nforged"))
    }
}
