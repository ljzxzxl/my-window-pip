import CoreGraphics
import Foundation
import XCTest
@testable import my_window_pip

/// issue #12（一键捕获外接显示器）与 issue #13（区域捕获误升级为单窗口流）的回归测试。
final class DisplayCaptureTests: XCTestCase {

    // MARK: - 显示器目标选择（issue #12）

    private func display(_ id: CGDirectDisplayID, _ name: String,
                         main: Bool = false, builtin: Bool = false,
                         frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)) -> DisplayTarget {
        DisplayTarget(displayID: id, name: name, frame: frame,
                      isMain: main, isBuiltin: builtin)
    }

    func testHotkeyTargetPrefersExternalDisplay() {
        let builtin = display(1, "Built-in Retina Display", main: true, builtin: true)
        let external = display(2, "External Display",
                               frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(DisplayCaptureTarget.hotkeyTarget(in: [builtin, external], lastUsedID: nil),
                       external)
    }

    func testHotkeyTargetReusesLastPickedDisplay() {
        let builtin = display(1, "Built-in", main: true, builtin: true)
        let external = display(2, "External")
        XCTAssertEqual(DisplayCaptureTarget.hotkeyTarget(in: [builtin, external], lastUsedID: 1),
                       builtin)
    }

    func testStaleLastPickedDisplayFallsBackToExternal() {
        let builtin = display(1, "Built-in", main: true, builtin: true)
        let external = display(2, "External")
        // 上次那块屏已经拔掉，不能因此什么都不捕获
        XCTAssertEqual(DisplayCaptureTarget.hotkeyTarget(in: [builtin, external], lastUsedID: 99),
                       external)
    }

    func testHotkeyTargetWithSingleBuiltinDisplay() {
        let builtin = display(1, "Built-in", main: true, builtin: true)
        XCTAssertEqual(DisplayCaptureTarget.hotkeyTarget(in: [builtin], lastUsedID: nil), builtin)
    }

    func testHotkeyTargetWhenExternalIsMainDisplay() {
        let external = display(2, "External", main: true, builtin: false)
        let builtin = display(1, "Built-in", builtin: true)
        XCTAssertEqual(DisplayCaptureTarget.hotkeyTarget(in: [builtin, external], lastUsedID: nil),
                       external)
    }

    func testHotkeyTargetWithoutDisplaysReturnsNil() {
        XCTAssertNil(DisplayCaptureTarget.hotkeyTarget(in: [], lastUsedID: nil))
    }

    // MARK: - 区域捕获目标策略（issue #13）

    func testPlainDragUsesDisplayCompositeStreamEvenWhenWindowIsHit() {
        // 全屏 VLC 覆盖整块副屏时，选区中心必然命中它；默认仍必须拍整块屏幕区域。
        XCTAssertFalse(RegionCapturePolicy.usesWindowStream(
            snapWindow: false, followsWindowByDefault: false, hitWindowID: 4242
        ))
    }

    func testOptionClickStillUsesSingleWindowStream() {
        XCTAssertTrue(RegionCapturePolicy.usesWindowStream(
            snapWindow: true, followsWindowByDefault: false, hitWindowID: 4242
        ))
    }

    func testLegacyPreferenceRestoresWindowFollowing() {
        XCTAssertTrue(RegionCapturePolicy.usesWindowStream(
            snapWindow: false, followsWindowByDefault: true, hitWindowID: 4242
        ))
    }

    func testNoHitWindowNeverUsesWindowStream() {
        XCTAssertFalse(RegionCapturePolicy.usesWindowStream(
            snapWindow: true, followsWindowByDefault: true, hitWindowID: nil
        ))
    }

    // MARK: - 整屏捕获模型

    func testDisplaySourceCarriesDisplayIDAndRegionPreferences() {
        let source = CaptureSource.display(
            displayID: 7, name: "External", rect: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        XCTAssertEqual(source.displayID, 7)
        XCTAssertNil(source.windowID)
        XCTAssertEqual(source.preferenceKey, CaptureSource.regionPreferenceKey)
        XCTAssertTrue(source.title.contains("2560×1440"))
        XCTAssertTrue(source.displayTitle.contains("External"))
    }

    func testFullDisplayPositionIdentityDoesNotDependOnRect() {
        let identity = PositionMemoryIdentity.display(displayID: 7)
        let region = PositionMemoryIdentity.displayRegion(
            displayID: 7, rect: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        XCTAssertNotEqual(identity.preferenceKey, region.preferenceKey)
        XCTAssertEqual(identity.fallbackPreferenceKey, CaptureSource.regionPreferenceKey)
        XCTAssertTrue(PositionMemoryIdentity.isSpecificPreferenceKey(identity.preferenceKey))
    }

    // MARK: - 全屏 / 多屏下的健壮性

    func testSanitizedSourceRectClampsNegativeOrigin() {
        let sanitized = CaptureEngine.sanitizedSourceRect(
            CGRect(x: -120, y: -40, width: 800, height: 600)
        )
        XCTAssertEqual(sanitized, CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testSanitizedSourceRectKeepsValidCropsAndFallsBackOnInvalidOnes() {
        let crop = CGRect(x: 100, y: 80, width: 960, height: 540)
        XCTAssertEqual(CaptureEngine.sanitizedSourceRect(crop), crop)
        XCTAssertEqual(CaptureEngine.sanitizedSourceRect(.zero), .zero)
        XCTAssertEqual(CaptureEngine.sanitizedSourceRect(
            CGRect(x: 10, y: 10, width: CGFloat.nan, height: 100)), .zero)
    }

    func testWindowBoundsParserHandlesNSNumberValues() {
        let info: [String: Any] = [
            "X": NSNumber(value: 10.0), "Y": NSNumber(value: 20.0),
            "Width": NSNumber(value: 300), "Height": NSNumber(value: 200),
        ]
        XCTAssertEqual(WindowBoundsParser.rect(from: info),
                       CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    func testWindowBoundsParserRejectsMalformedBounds() {
        XCTAssertNil(WindowBoundsParser.rect(from: ["X": NSNumber(value: 1)]))
        XCTAssertNil(WindowBoundsParser.rect(from: [
            "X": "0", "Y": NSNumber(value: 0),
            "Width": NSNumber(value: 100), "Height": NSNumber(value: 100),
        ]))
        XCTAssertNil(WindowBoundsParser.rect(from: [
            "X": NSNumber(value: 0), "Y": NSNumber(value: 0),
            "Width": NSNumber(value: 0), "Height": NSNumber(value: 100),
        ]))
    }
}
