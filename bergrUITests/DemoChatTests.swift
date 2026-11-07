import XCTest

/// The real chat over the demo machine's fake agent: open it, keyboard up, send, wait for the
/// answer. Run while recording the simulator to see how things move.
final class DemoChatTests: XCTestCase {
    @MainActor
    func testSendAndReceive() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-bergr.demo", "YES", "-bergr.demoChat", "YES"]
        app.launch()
        let row = app.staticTexts["Running tests"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let reply = NSPredicate(format: "placeholderValue BEGINSWITH 'Reply'")
        let asView = app.textViews.matching(reply).firstMatch
        let asField = app.textFields.matching(reply).firstMatch
        XCTAssertTrue(asView.waitForExistence(timeout: 10) || asField.exists, "the chat's reply box shows")
        let field = asView.exists ? asView : asField
        sleep(3)
        field.tap()
        sleep(4) // keyboard up, nothing touched: the list must hold still
        field.typeText("check the deploy")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'roll'")).firstMatch
            .waitForExistence(timeout: 15), "the fake agent answers")
        sleep(6) // after the answer, still nothing touched
    }
}
