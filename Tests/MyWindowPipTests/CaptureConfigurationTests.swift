import XCTest
@testable import my_window_pip

final class CaptureConfigurationTests: XCTestCase {
    func testFullWindowCapturePreservesAspectRatioAndRendererCropsPadding() {
        let config = CaptureEngine.makeConfiguration(
            sourceRect: .zero,
            pointSize: CGSize(width: 480, height: 270),
            scale: 2,
            fps: 15,
            showsCursor: false
        )
        XCTAssertTrue(config.scalesToFit)
        XCTAssertTrue(config.preservesAspectRatio)
    }

    func testCroppedCaptureStillPreservesAspectRatio() {
        let config = CaptureEngine.makeConfiguration(
            sourceRect: CGRect(x: 100, y: 80, width: 960, height: 540),
            pointSize: CGSize(width: 480, height: 270),
            scale: 2,
            fps: 15,
            showsCursor: false
        )
        XCTAssertTrue(config.scalesToFit)
        XCTAssertTrue(config.preservesAspectRatio)
    }

    func testContentGeometryChoosesScaleFactorWhenRectIsAlreadyInSurfacePoints() {
        let visible = FrameGate.resolvedVisibleRectPixels(
            contentRect: CGRect(x: 0, y: 5, width: 480, height: 260),
            scaleFactor: 2,
            contentScale: 0.25,
            bufferSize: CGSize(width: 960, height: 540)
        )
        XCTAssertEqual(visible?.origin.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(visible?.origin.y ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(visible?.width ?? 0, 960, accuracy: 0.001)
        XCTAssertEqual(visible?.height ?? 0, 520, accuracy: 0.001)
    }

    func testContentGeometryUsesContentScaleWhenRawRectIsSourceSized() {
        let visible = FrameGate.resolvedVisibleRectPixels(
            contentRect: CGRect(x: 0, y: 20, width: 1920, height: 1040),
            scaleFactor: 2,
            contentScale: 0.25,
            bufferSize: CGSize(width: 960, height: 540)
        )
        XCTAssertEqual(visible?.origin.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(visible?.origin.y ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(visible?.width ?? 0, 960, accuracy: 0.001)
        XCTAssertEqual(visible?.height ?? 0, 520, accuracy: 0.001)
    }
}
