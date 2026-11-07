import XCTest

/// Two conversations side by side on a wide screen: open one, then another with "Open Beside".
/// Saves screenshots to TEST_RUNNER_BERGR_SHOTS when set.
final class TwoPaneShotTests: XCTestCase {
    @MainActor
    func testOpenBeside() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-bergr.demo", "YES", "-bergr.demoChat", "YES"]
        app.launch()
        let first = app.staticTexts["Running tests"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        sleep(3)
        let second = app.staticTexts["Upgraded Postgres to 18"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.press(forDuration: 1.2)
        sleep(1)
        if let dir = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("two-pane-menu.png"))
        }
        let beside = app.buttons["Open Beside"].firstMatch
        XCTAssertTrue(beside.waitForExistence(timeout: 5))
        beside.tap()
        sleep(4)
        if let dir = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("two-pane.png"))
        }
        XCTAssertTrue(app.buttons["Close"].firstMatch.exists, "the second pane has a Close button")
    }
}
