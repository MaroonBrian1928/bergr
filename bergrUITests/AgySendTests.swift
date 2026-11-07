import XCTest

/// Sends one message in a real agent's chat (diagnosing agy sends). Skips unless
/// BERGR_SEND_ROW (row title) and BERGR_SEND_TEXT are set.
final class AgySendTests: XCTestCase {
    @MainActor
    func testSendInChat() throws {
        let env = ProcessInfo.processInfo.environment
        guard let title = env["BERGR_SEND_ROW"], let text = env["BERGR_SEND_TEXT"] else { throw XCTSkip("not set") }
        let app = XCUIApplication()
        app.launch()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        row.tap()
        let reply = NSPredicate(format: "placeholderValue BEGINSWITH 'Reply'")
        let field = app.textViews.matching(reply).firstMatch.exists ? app.textViews.matching(reply).firstMatch
            : app.textFields.matching(reply).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        sleep(4)
        field.tap()
        field.typeText(text)
        app.buttons["Send"].firstMatch.tap()
        sleep(12)
        if let dir = env["BERGR_SHOTS"] {
            try XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("agy-send.png"))
        }
    }
}
