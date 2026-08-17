import XCTest
@testable import my_window_pip

final class RendererDiagnosticsTests: XCTestCase {

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
}
