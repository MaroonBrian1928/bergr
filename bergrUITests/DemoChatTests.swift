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
        let row = app.staticTexts["Add a dark mode toggle"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let field = app.descendants(matching: .any)["reply-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the chat's reply box shows")
        sleep(3)
        field.tap()
        sleep(4) // keyboard up, nothing touched: the list must hold still
        field.typeText("check the deploy")
        app.buttons["send-button"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'roll'")).firstMatch
            .waitForExistence(timeout: 15), "the fake agent answers")
        sleep(6) // after the answer, still nothing touched
    }
}
