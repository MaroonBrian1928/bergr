import XCTest
/// The demo's Codex question takes a tapped answer (App Review walks through this).
final class DemoCodexQuestionTests: XCTestCase {
    @MainActor func testPickingAnAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES"]
        app.launch()
        let row = app.staticTexts["Where should product images be cached?"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let opt = app.staticTexts["In Redis"].firstMatch
        XCTAssertTrue(opt.waitForExistence(timeout: 15)); opt.tap()
        sleep(8)
        let err = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'select this Codex question'")).firstMatch
        XCTAssertFalse(err.exists, "pick failed")
        // The fake agent took it and works on: back on the list, only one agent still needs you.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Needs you, 1"].waitForExistence(timeout: 15), "the agent took the answer")
    }
}
