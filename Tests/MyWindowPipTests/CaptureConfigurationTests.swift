import XCTest
@testable import my_window_pip

final class CaptureConfigurationTests: XCTestCase {
    func testRetuningCaptureKeepsChildWindowsExcluded() throws {
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("Child-window capture configuration requires macOS 14.2")
        }
        // 同一配置入口用于建流、放大、复位、跨屏和重连；这些更新不能重新扩大捕获范围。
        let crop = CGRect(x: 100, y: 80, width: 960, height: 540)
        for (rect, scale, fps) in [(CGRect.zero, 1.0, 5), (crop, 2.0, 15), (.zero, 2.0, 30)] {
            let config = CaptureEngine.makeConfiguration(
                sourceRect: rect, pointSize: CGSize(width: 640, height: 360),
                scale: scale, fps: fps, showsCursor: false
            )
            XCTAssertFalse(config.includeChildWindows)
            XCTAssertEqual(config.sourceRect, rect)
            XCTAssertTrue(config.preservesAspectRatio)
        }
    }

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
