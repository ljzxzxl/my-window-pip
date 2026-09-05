import XCTest
@testable import my_window_pip

final class SourceWindowHealthTests: XCTestCase {
    func testOffscreenAliveDoesNotBecomeMissing() {
        let result = classifySourceWindowHealth(SourceWindowObservation(
            cgWindowExists: true,
            processAlive: true,
            ownerPIDMatches: true,
            isOnScreen: false,
            axMinimized: false
        ))
        XCTAssertEqual(result, .offScreenAlive)
    }

    func testAXMinimizedIsRequiredForMinimizedState() {
        let result = classifySourceWindowHealth(SourceWindowObservation(
            cgWindowExists: true,
            processAlive: true,
            ownerPIDMatches: true,
            isOnScreen: false,
            axMinimized: true
        ))
        XCTAssertEqual(result, .minimized)
    }

    func testNoAXPermissionFallsBackToAlive() {
        let result = classifySourceWindowHealth(SourceWindowObservation(
            cgWindowExists: true,
            processAlive: true,
            ownerPIDMatches: true,
            isOnScreen: false,
            axMinimized: nil
        ))
        XCTAssertEqual(result, .offScreenAlive)
    }

    func testDirectWindowServerMissIsMissingEvenWhenProcessLives() {
        let result = classifySourceWindowHealth(SourceWindowObservation(
            cgWindowExists: false,
            processAlive: true,
            ownerPIDMatches: nil,
            isOnScreen: nil,
            axMinimized: nil
        ))
        XCTAssertEqual(result, .missing)
    }

    func testDeadProcessIsMissing() {
        let result = classifySourceWindowHealth(SourceWindowObservation(
            cgWindowExists: false,
            processAlive: false,
            ownerPIDMatches: false,
            isOnScreen: false,
            axMinimized: nil
        ))
        XCTAssertEqual(result, .missing)
    }

    func testOwnerPIDMismatchIsMissing() {
        let result = classifySourceWindowHealth(SourceWindowObservation(
            cgWindowExists: true,
            processAlive: true,
            ownerPIDMatches: false,
            isOnScreen: true,
            axMinimized: nil
        ))
        XCTAssertEqual(result, .missing)
    }
}
