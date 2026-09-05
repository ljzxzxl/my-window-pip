import XCTest
@testable import my_window_pip

final class GeometrySelectionTests: XCTestCase {
    func testCmdSelectionKeepsItsOwnAspectRatio() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 270)
        let selection = CGRect(x: 120, y: 45, width: 120, height: 180)

        let normalized = Geo.visibleNormalizedRect(
            forSelection: selection,
            aspect: CGSize(width: 16, height: 9),
            bounds: bounds
        )
        XCTAssertNotNil(normalized)

        let source = normalized.flatMap {
            Geo.sourceRect(
                fromNormalizedVisibleRect: $0,
                within: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            )
        }
        XCTAssertNotNil(source)
        XCTAssertEqual(source?.minX ?? 0, 480, accuracy: 0.001)
        XCTAssertEqual(source?.minY ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(source?.width ?? 0, 480, accuracy: 0.001)
        XCTAssertEqual(source?.height ?? 0, 720, accuracy: 0.001)
        XCTAssertEqual((source?.width ?? 0) / (source?.height ?? 1), 2.0 / 3.0, accuracy: 0.001)
    }

    func testSelectedCropRemapsAcrossSourceResize() {
        let oldBase = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let selected = CGRect(x: 480, y: 180, width: 480, height: 720)
        let newBase = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let mapped = Geo.remap(selected, from: oldBase, to: newBase)
        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped?.minX ?? 0, 360, accuracy: 0.001)
        XCTAssertEqual(mapped?.minY ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(mapped?.width ?? 0, 360, accuracy: 0.001)
        XCTAssertEqual(mapped?.height ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual((mapped?.width ?? 0) / (mapped?.height ?? 1), 0.6, accuracy: 0.001)
    }

    func testDisplayLayerFrameCropsTopAndRightSurfacePadding() {
        let frame = Geo.displayLayerFrame(
            bufferSize: CGSize(width: 1000, height: 600),
            visibleRectPixels: CGRect(x: 0, y: 10, width: 990, height: 590),
            in: CGRect(x: 0, y: 0, width: 495, height: 295)
        )

        XCTAssertNotNil(frame)
        // visible rect 的左/下边正好落在 view 左/下；surface 多出的 top/right 被推出裁剪区。
        XCTAssertEqual(frame?.minX ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(frame?.minY ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(frame?.width ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(frame?.height ?? 0, 300, accuracy: 0.001)
    }

    func testDisplayLayerFrameAccountsForLeftAndBottomPadding() {
        let frame = Geo.displayLayerFrame(
            bufferSize: CGSize(width: 1000, height: 600),
            visibleRectPixels: CGRect(x: 10, y: 0, width: 990, height: 590),
            in: CGRect(x: 0, y: 0, width: 495, height: 295)
        )

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.minX ?? 0, -5, accuracy: 0.001)
        XCTAssertEqual(frame?.minY ?? 0, -5, accuracy: 0.001)
        XCTAssertEqual(frame?.width ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(frame?.height ?? 0, 300, accuracy: 0.001)
    }
}
