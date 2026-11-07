import XCTest

/// The Usage sheet offering to set up Claude's status line (the demo agent has no numbers).
/// Saves a screenshot to TEST_RUNNER_BERGR_SHOTS when set.
final class UsageSetupShotTests: XCTestCase {
    @MainActor
    func testUsageSetupSheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-bergr.demo", "YES", "-bergr.demoChat", "YES"]
        app.launch()
        let row = app.staticTexts["Running tests"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let ring = app.buttons["Context"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 10))
        sleep(2)
        ring.tap()
        XCTAssertTrue(app.buttons["Copy Setup Prompt"].waitForExistence(timeout: 5))
        sleep(1)
        if let dir = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("usage-setup.png"))
        }
    }
}
