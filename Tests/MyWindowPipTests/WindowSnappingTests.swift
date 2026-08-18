import CoreGraphics
import XCTest
@testable import my_window_pip

final class WindowSnappingTests: XCTestCase {

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
}
