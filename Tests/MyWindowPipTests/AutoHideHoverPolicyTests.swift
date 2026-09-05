import XCTest
@testable import my_window_pip

final class AutoHideHoverPolicyTests: XCTestCase {
    func testCommandRestoresInteractionForZoomSelection() {
        let state = HoverState(
            isHovering: true,
            isOverHotZone: false,
            isOverResizeZone: false,
            optionHeld: false,
            commandHeld: true
        )
        XCTAssertEqual(autoHideHoverIntent(for: state), .command)
    }

    func testCommandTakesPriorityOverOptionAndResize() {
        let state = HoverState(
            isHovering: true,
            isOverHotZone: true,
            isOverResizeZone: true,
            optionHeld: true,
            commandHeld: true
        )
        XCTAssertEqual(autoHideHoverIntent(for: state), .command)
    }

    func testOptionTakesPriorityOverResize() {
        let state = HoverState(
            isHovering: true,
            isOverHotZone: true,
            isOverResizeZone: true,
            optionHeld: true,
            commandHeld: false
        )
        XCTAssertEqual(autoHideHoverIntent(for: state), .option)
    }

    func testResizeZoneTakesPriorityOverBar() {
        let state = HoverState(
            isHovering: true,
            isOverHotZone: true,
            isOverResizeZone: true,
            optionHeld: false,
            commandHeld: false
        )
        XCTAssertEqual(autoHideHoverIntent(for: state), .resize)
    }

    func testBarRestoresInteractionAwayFromResizeEdge() {
        let state = HoverState(
            isHovering: true,
            isOverHotZone: true,
            isOverResizeZone: false,
            optionHeld: false,
            commandHeld: false
        )
        XCTAssertEqual(autoHideHoverIntent(for: state), .bar)
    }

    func testPlainHoverFadesAndLeavingRestores() {
        XCTAssertEqual(
            autoHideHoverIntent(for: HoverState(
                isHovering: true,
                isOverHotZone: false,
                isOverResizeZone: false,
                optionHeld: false,
                commandHeld: false
            )),
            .fade
        )
        XCTAssertEqual(autoHideHoverIntent(for: .none), .leave)
    }

    func testResizeHotZoneCoversInsideAndOutsideOfEdges() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 240)
        XCTAssertTrue(isInResizeHotZone(
            point: CGPoint(x: 105, y: 220), frame: frame, thickness: 10
        ))
        XCTAssertTrue(isInResizeHotZone(
            point: CGPoint(x: 506, y: 220), frame: frame, thickness: 10
        ))
        XCTAssertTrue(isInResizeHotZone(
            point: CGPoint(x: 95, y: 95), frame: frame, thickness: 10
        ))
    }

    func testResizeHotZoneDoesNotStealContentCenterOrFarOutside() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 240)
        XCTAssertFalse(isInResizeHotZone(
            point: CGPoint(x: 300, y: 220), frame: frame, thickness: 10
        ))
        XCTAssertFalse(isInResizeHotZone(
            point: CGPoint(x: 80, y: 220), frame: frame, thickness: 10
        ))
    }
}
