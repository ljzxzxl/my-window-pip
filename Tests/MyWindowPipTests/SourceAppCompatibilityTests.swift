import Darwin
import XCTest
@testable import my_window_pip

final class SourceAppCompatibilityTests: XCTestCase {
    func testChatGPTHasVerifiedCompatibilityProfile() {
        let profile = SourceAppCompatibility.profile(for: "com.openai.codex")
        XCTAssertEqual(profile?.appName, "ChatGPT")
        XCTAssertEqual(
            profile?.launchArguments,
            ["--disable-backgrounding-occluded-windows"]
        )
    }

    func testChromeHasVerifiedCompatibilityProfile() {
        let profile = SourceAppCompatibility.profile(for: "com.google.Chrome")
        XCTAssertEqual(profile?.appName, "Google Chrome")
        XCTAssertEqual(profile?.isVerified, true)
        XCTAssertEqual(
            profile?.launchArguments,
            ["--disable-backgrounding-occluded-windows"]
        )
    }

    func testUnknownApplicationsDoNotGetStaticCompatibilityArguments() {
        XCTAssertNil(SourceAppCompatibility.profile(for: "com.example.NativeApp"))
        XCTAssertNil(SourceAppCompatibility.profile(for: nil))
    }

    func testVerifiedAppNamesComeFromAllowlist() {
        XCTAssertEqual(SourceAppCompatibility.verifiedAppNames, ["ChatGPT", "Google Chrome"])
    }

    func testElectronFrameworkIsEnoughForConservativeDetection() {
        XCTAssertTrue(SourceAppCompatibility.isChromiumLike(.init(
            hasElectronFramework: true,
            hasElectronAsar: false,
            hasRendererHelper: false,
            hasResourcesPak: false,
            hasICUData: false
        )))
    }

    func testChromiumRuntimeSignatureRequiresRendererAndResources() {
        XCTAssertTrue(SourceAppCompatibility.isChromiumLike(.init(
            hasElectronFramework: false,
            hasElectronAsar: false,
            hasRendererHelper: true,
            hasResourcesPak: true,
            hasICUData: true
        )))
        XCTAssertFalse(SourceAppCompatibility.isChromiumLike(.init(
            hasElectronFramework: false,
            hasElectronAsar: false,
            hasRendererHelper: true,
            hasResourcesPak: true,
            hasICUData: false
        )))
    }

    func testKernProcArgsParserFindsCompatibilityArgument() {
        var argc: Int32 = 3
        var bytes: [UInt8] = []
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }

        func appendCString(_ value: String) {
            bytes.append(contentsOf: value.utf8)
            bytes.append(0)
        }

        appendCString("/Applications/Test.app/Contents/MacOS/Test")
        bytes.append(0) // executable path 与 argv 之间的 padding
        appendCString("Test")
        appendCString("--disable-backgrounding-occluded-windows")
        appendCString("--other")

        XCTAssertEqual(
            SourceAppCompatibility.parseProcessArgumentsBuffer(bytes),
            ["Test", "--disable-backgrounding-occluded-windows", "--other"]
        )
    }

    func testProcessArgumentsCanReadCurrentProcess() {
        let arguments = SourceAppCompatibility.processArguments(pid: getpid())
        XCTAssertNotNil(arguments)
        XCTAssertFalse(arguments?.isEmpty ?? true)
    }

    func testCompatibilityArgumentsAreAppendedToExistingLaunchArguments() {
        XCTAssertEqual(
            SourceAppCompatibility.launchArgumentsByAppendingCompatibility(
                processArguments: [
                    "Google Chrome",
                    "--variations-override-country=us",
                    "--profile-directory=Default",
                ],
                compatibilityArguments: ["--disable-backgrounding-occluded-windows"]
            ),
            [
                "--variations-override-country=us",
                "--profile-directory=Default",
                "--disable-backgrounding-occluded-windows",
            ]
        )
    }

    func testCompatibilityAppendDoesNotDuplicateExistingArgument() {
        XCTAssertEqual(
            SourceAppCompatibility.launchArgumentsByAppendingCompatibility(
                processArguments: [
                    "ChatGPT",
                    "--disable-backgrounding-occluded-windows",
                ],
                compatibilityArguments: ["--disable-backgrounding-occluded-windows"]
            ),
            ["--disable-backgrounding-occluded-windows"]
        )
    }

    func testCompatibilityAppendFallsBackToCompatibilityArgumentsWhenArgvUnavailable() {
        XCTAssertEqual(
            SourceAppCompatibility.launchArgumentsByAppendingCompatibility(
                processArguments: nil,
                compatibilityArguments: ["--disable-backgrounding-occluded-windows"]
            ),
            ["--disable-backgrounding-occluded-windows"]
        )
    }

    func testChromiumCompatibilityPreferenceRoundTrips() {
        let prefs = Preferences.shared
        let original = prefs.chromiumCompatibilityMode
        defer { prefs.chromiumCompatibilityMode = original }

        for mode in ChromiumCompatibilityMode.allCases {
            prefs.chromiumCompatibilityMode = mode
            XCTAssertEqual(prefs.chromiumCompatibilityMode, mode)
        }
    }
}
