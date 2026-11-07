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
        let close = app.buttons["beside.leading"].firstMatch
        XCTAssertTrue(close.exists, "the second pane has a Close button")
        let besideTitle = app.staticTexts["beside.title"].firstMatch
        let primaryTitle = app.staticTexts["primary.title"].firstMatch
        XCTAssertTrue(besideTitle.exists && primaryTitle.exists, "each pane has its own title")
        let screen = app.windows.firstMatch.frame
        // The beside pane's header lies right of the primary's title, and the primary's title left of the beside pane's.
        XCTAssertGreaterThan(close.frame.minX, primaryTitle.frame.maxX, "Close is in the beside pane, not the primary's bar")
        XCTAssertLessThanOrEqual(primaryTitle.frame.maxX, besideTitle.frame.minX, "titles are in separate panes")
        XCTAssertLessThanOrEqual(close.frame.minX, besideTitle.frame.minX, "Close leads the beside pane's title")
        XCTAssertGreaterThan(besideTitle.frame.minX, screen.midX - 300)
        XCTAssertLessThanOrEqual(besideTitle.frame.maxX, screen.maxX)
    }
}
