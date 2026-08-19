import AppKit
import XCTest
@testable import my_window_pip

final class WindowPositionMemoryTests: XCTestCase {

    private final class TestClock {
        private(set) var value: TimeInterval = 0
        func next() -> TimeInterval {
            value += 1
            return value
        }
    }

    private func makePreferences(clock: TestClock = TestClock()) -> (Preferences, UserDefaults) {
        let suiteName = "WindowPositionMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (Preferences(defaults: defaults, now: { clock.next() }), defaults)
    }

    func testWindowPositionKeyUsesWindowIDAndIgnoresChangingTitle() {
        let first = CaptureSource.window(
            id: 42, bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor", title: "a.swift"
        )
        let renamed = CaptureSource.window(
            id: 42, bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor", title: "b.swift"
        )
        let sibling = CaptureSource.window(
            id: 43, bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor", title: "a.swift"
        )
        let firstIdentity = PositionMemoryIdentity.window(
            appPreferenceKey: first.preferenceKey, windowID: first.windowID!
        )
        let renamedIdentity = PositionMemoryIdentity.window(
            appPreferenceKey: renamed.preferenceKey, windowID: renamed.windowID!
        )
        let siblingIdentity = PositionMemoryIdentity.window(
            appPreferenceKey: sibling.preferenceKey, windowID: sibling.windowID!
        )

        XCTAssertEqual(firstIdentity.preferenceKey, renamedIdentity.preferenceKey)
        XCTAssertNotEqual(firstIdentity.preferenceKey, siblingIdentity.preferenceKey)
        XCTAssertEqual(firstIdentity.fallbackPreferenceKey, siblingIdentity.fallbackPreferenceKey)
    }

    func testCaptureRegionsHaveIndependentPositionKeys() {
        let appKey = "com.microsoft.VSCode"
        let whole = PositionMemoryIdentity.window(appPreferenceKey: appKey, windowID: 42)
        let regionA = PositionMemoryIdentity.windowRegion(
            appPreferenceKey: appKey, windowID: 42, rect: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let regionB = PositionMemoryIdentity.windowRegion(
            appPreferenceKey: appKey, windowID: 42, rect: CGRect(x: 10, y: 0, width: 400, height: 300)
        )
        let displayA = PositionMemoryIdentity.displayRegion(
            displayID: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let displayB = PositionMemoryIdentity.displayRegion(
            displayID: 2, rect: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertNotEqual(whole.preferenceKey, regionA.preferenceKey)
        XCTAssertNotEqual(regionA.preferenceKey, regionB.preferenceKey)
        XCTAssertNotEqual(displayA.preferenceKey, displayB.preferenceKey)
    }

    func testWindowRegionRetargetKeepsGeometryAndChangesWindowID() {
        let original = PositionMemoryIdentity.windowRegion(
            appPreferenceKey: "com.microsoft.VSCode",
            windowID: 42,
            rect: CGRect(x: 10, y: 20, width: 400, height: 300)
        )
        let rematched = original.retargetingWindow(to: .window(
            id: 99,
            bundleID: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            title: "changed title"
        ))

        XCTAssertNotEqual(original.preferenceKey, rematched.preferenceKey)
        XCTAssertEqual(original.fallbackPreferenceKey, rematched.fallbackPreferenceKey)
        XCTAssertTrue(rematched.preferenceKey.contains(":99:"))
    }

    func testExactOriginWinsEvenWhenSiblingIsActive() {
        let exact = CGPoint(x: 100, y: 200)

        XCTAssertEqual(
            SessionStore.selectInitialOrigin(
                exactOrigin: exact,
                fallbackOrigin: CGPoint(x: 300, y: 400),
                hasActiveSibling: true
            ),
            exact
        )
    }

    func testNewSiblingUsesCascadeInsteadOfSharedFallbackOrigin() {
        XCTAssertNil(
            SessionStore.selectInitialOrigin(
                exactOrigin: nil,
                fallbackOrigin: CGPoint(x: 300, y: 400),
                hasActiveSibling: true
            )
        )
    }

    func testFirstCaptureCanUseLegacyFallbackOrigin() {
        let fallback = CGPoint(x: 300, y: 400)

        XCTAssertEqual(
            SessionStore.selectInitialOrigin(
                exactOrigin: nil, fallbackOrigin: fallback, hasActiveSibling: false
            ),
            fallback
        )
    }

    func testPreferencesPersistExactAndFallbackOrigins() {
        let (prefs, defaults) = makePreferences()
        let first = PositionMemoryIdentity.window(appPreferenceKey: "com.example.editor", windowID: 1)
        let second = PositionMemoryIdentity.window(appPreferenceKey: "com.example.editor", windowID: 2)
        let firstOrigin = CGPoint(x: 100, y: 200)
        let secondOrigin = CGPoint(x: 300, y: 400)

        prefs.setOrigin(firstOrigin, for: first)
        prefs.setOrigin(secondOrigin, for: second)

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.origin(for: first), firstOrigin)
        XCTAssertEqual(reloaded.origin(for: second), secondOrigin)
        XCTAssertEqual(reloaded.fallbackOrigin(for: first), secondOrigin)
    }

    func testPreferencesReadLegacyAppOriginAsFallback() {
        let (prefs, defaults) = makePreferences()
        defaults.set(["com.example.editor": [12.0, 34.0]], forKey: "originByApp")
        let identity = PositionMemoryIdentity.window(
            appPreferenceKey: "com.example.editor", windowID: 42
        )

        XCTAssertNil(prefs.origin(for: identity))
        XCTAssertEqual(prefs.fallbackOrigin(for: identity), CGPoint(x: 12, y: 34))
    }

    func testPositionOriginLRUKeepsRecentlyReadEntry() {
        let clock = TestClock()
        let (prefs, _) = makePreferences(clock: clock)
        let identities = (1...128).map {
            PositionMemoryIdentity.window(
                appPreferenceKey: "com.example.editor", windowID: CGWindowID($0)
            )
        }
        for (index, identity) in identities.enumerated() {
            prefs.setOrigin(CGPoint(x: index, y: index), for: identity)
        }

        XCTAssertNotNil(prefs.origin(for: identities[0])) // 刷新第一条的最近使用时间
        let newest = PositionMemoryIdentity.window(
            appPreferenceKey: "com.example.editor", windowID: 129
        )
        prefs.setOrigin(CGPoint(x: 129, y: 129), for: newest)

        XCTAssertNotNil(prefs.origin(for: identities[0]))
        XCTAssertNil(prefs.origin(for: identities[1]))
        XCTAssertNotNil(prefs.origin(for: newest))
    }
}
