import CoreGraphics
import XCTest
@testable import my_window_pip

final class WindowSnappingTests: XCTestCase {

    func testSnapCandidateMustBeActuallyVisibleOnCurrentSpace() {
        XCTAssertTrue(PiPSession.canParticipateInSnapping(
            isHidden: false,
            isWindowVisible: true,
            isOcclusionVisible: true
        ))
        XCTAssertFalse(PiPSession.canParticipateInSnapping(
            isHidden: true,
            isWindowVisible: true,
            isOcclusionVisible: true
        ))
        XCTAssertFalse(PiPSession.canParticipateInSnapping(
            isHidden: false,
            isWindowVisible: false,
            isOcclusionVisible: true
        ))
        XCTAssertFalse(PiPSession.canParticipateInSnapping(
            isHidden: false,
            isWindowVisible: true,
            isOcclusionVisible: false
        ))
    }

    func testScreenEdgeSnappingSupportsNegativeDisplayCoordinatesAndPreservesSize() {
        let visibleFrame = CGRect(x: -1200, y: -100, width: 1200, height: 900)
        let proposed = CGRect(x: -311, y: 200, width: 300, height: 180)

        let snapped = Geo.snappedWindowFrame(proposed, in: visibleFrame, siblings: [])

        XCTAssertEqual(snapped.maxX, -12, accuracy: 0.001)
        XCTAssertEqual(snapped.origin.y, proposed.origin.y, accuracy: 0.001)
        XCTAssertEqual(snapped.size, proposed.size)
    }

    func testSiblingSnappingJoinsEveryAdjacentEdgeWithNoGap() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let sibling = CGRect(x: 900, y: 400, width: 200, height: 100)

        let cases: [(proposed: CGRect, expectedOrigin: CGPoint)] = [
            (CGRect(x: 902, y: 503, width: 200, height: 100), CGPoint(x: 900, y: 500)),
            (CGRect(x: 902, y: 297, width: 200, height: 100), CGPoint(x: 900, y: 300)),
            (CGRect(x: 697, y: 402, width: 200, height: 100), CGPoint(x: 700, y: 400)),
            (CGRect(x: 1103, y: 402, width: 200, height: 100), CGPoint(x: 1100, y: 400)),
        ]

        for testCase in cases {
            let snapped = Geo.snappedWindowFrame(
                testCase.proposed,
                in: visibleFrame,
                siblings: [sibling]
            )

            XCTAssertEqual(snapped.origin.x, testCase.expectedOrigin.x, accuracy: 0.001)
            XCTAssertEqual(snapped.origin.y, testCase.expectedOrigin.y, accuracy: 0.001)
            XCTAssertEqual(snapped.size, testCase.proposed.size)
        }
    }

    func testScreenEdgeOutsideThresholdDoesNotSnap() {
        let visibleFrame = CGRect(x: -1200, y: -100, width: 1200, height: 900)
        let proposed = CGRect(x: -327, y: 200, width: 300, height: 180)

        let snapped = Geo.snappedWindowFrame(proposed, in: visibleFrame, siblings: [])

        XCTAssertEqual(snapped, proposed)
    }

    func testDistantSiblingDoesNotInfluenceAlignment() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let proposed = CGRect(x: 650, y: 650, width: 200, height: 100)
        let distantSibling = CGRect(x: 649, y: 50, width: 200, height: 100)

        let snapped = Geo.snappedWindowFrame(
            proposed,
            in: visibleFrame,
            siblings: [distantSibling]
        )

        XCTAssertEqual(snapped, proposed)
    }

    func testScreenSelectionPrefersLargestOverlapAcrossDisplays() {
        // 左屏带负坐标，右屏与左屏之间留 40pt 空洞，模拟真实的多显示器排布。
        let screenFrames = [
            CGRect(x: -1440, y: -200, width: 1440, height: 900),
            CGRect(x: 40, y: 0, width: 1920, height: 1080),
        ]

        let mostlyOnLeft = CGRect(x: -300, y: 100, width: 300, height: 180)
        XCTAssertEqual(
            Geo.indexOfScreen(containing: mostlyOnLeft, screenFrames: screenFrames),
            0
        )

        let mostlyOnRight = CGRect(x: -20, y: 100, width: 300, height: 180)
        XCTAssertEqual(
            Geo.indexOfScreen(containing: mostlyOnRight, screenFrames: screenFrames),
            1
        )
    }

    func testScreenSelectionFallsBackToNearestDisplayInsideGap() {
        let screenFrames = [
            CGRect(x: -1440, y: -200, width: 1440, height: 900),
            CGRect(x: 40, y: 0, width: 1920, height: 1080),
        ]

        // 整窗落在两块屏幕之间的 40pt 空洞里：没有任何重叠，应取距窗口中心最近的一块。
        let insideGap = CGRect(x: 14, y: 400, width: 24, height: 24)
        XCTAssertEqual(
            Geo.indexOfScreen(containing: insideGap, screenFrames: screenFrames),
            1
        )

        XCTAssertNil(Geo.indexOfScreen(containing: insideGap, screenFrames: []))
    }

    func testSquaredDistanceIsZeroInsideRectAndGrowsOutside() {
        let rect = CGRect(x: -100, y: -50, width: 200, height: 100)

        XCTAssertEqual(Geo.squaredDistance(from: CGPoint(x: 0, y: 0), to: rect), 0, accuracy: 0.001)
        XCTAssertEqual(
            Geo.squaredDistance(from: CGPoint(x: -103, y: -54), to: rect),
            3 * 3 + 4 * 4,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Geo.squaredDistance(from: CGPoint(x: 106, y: 58), to: rect),
            6 * 6 + 8 * 8,
            accuracy: 0.001
        )
    }
}
