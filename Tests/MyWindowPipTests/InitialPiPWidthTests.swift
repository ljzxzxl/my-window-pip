import XCTest
@testable import my_window_pip

final class InitialPiPWidthTests: XCTestCase {
    func testFullscreenWindowUsesCompactDefaultWidth() {
        let width = Geo.initialPiPWidth(
            sourceSize: CGSize(width: 1920, height: 1080),
            rememberedWidth: nil,
            screenSizes: [CGSize(width: 1920, height: 1080)],
            isWindowSource: true
        )
        XCTAssertEqual(width, 480, accuracy: 0.001)
    }

    func testLegacyFullscreenDefault640MigratesToCompactWidth() {
        let width = Geo.initialPiPWidth(
            sourceSize: CGSize(width: 1920, height: 1080),
            rememberedWidth: 640,
            screenSizes: [CGSize(width: 1920, height: 1080)],
            isWindowSource: true
        )
        XCTAssertEqual(width, 480, accuracy: 0.001)
    }

    func testExplicitNonLegacyRememberedWidthIsPreservedForFullscreen() {
        let width = Geo.initialPiPWidth(
            sourceSize: CGSize(width: 1920, height: 1080),
            rememberedWidth: 560,
            screenSizes: [CGSize(width: 1920, height: 1080)],
            isWindowSource: true
        )
        XCTAssertEqual(width, 560, accuracy: 0.001)
    }

    func testNormalWindowKeepsExistingDefaultPolicy() {
        let width = Geo.initialPiPWidth(
            sourceSize: CGSize(width: 1200, height: 800),
            rememberedWidth: nil,
            screenSizes: [CGSize(width: 1920, height: 1080)],
            isWindowSource: true
        )
        XCTAssertEqual(width, 600, accuracy: 0.001)
    }

    func testRegionCaptureDoesNotUseFullscreenWindowRule() {
        let width = Geo.initialPiPWidth(
            sourceSize: CGSize(width: 1920, height: 1080),
            rememberedWidth: nil,
            screenSizes: [CGSize(width: 1920, height: 1080)],
            isWindowSource: false
        )
        XCTAssertEqual(width, 640, accuracy: 0.001)
    }

    func testFullscreenMainWindowCountsAsScreenFilling() {
        XCTAssertTrue(Geo.isScreenFillingWindow(
            size: CGSize(width: 1920, height: 1080),
            screenSizes: [CGSize(width: 1920, height: 1080)]
        ))
    }

    func testWideChromeAuxiliarySurfaceDoesNotCountAsScreenFilling() {
        XCTAssertFalse(Geo.isScreenFillingWindow(
            size: CGSize(width: 1920, height: 132),
            screenSizes: [CGSize(width: 1920, height: 1080)]
        ))
    }

    func testSplitScreenWindowDoesNotStealFullscreenPriority() {
        XCTAssertFalse(Geo.isScreenFillingWindow(
            size: CGSize(width: 960, height: 972),
            screenSizes: [CGSize(width: 1920, height: 1080)]
        ))
    }
}
