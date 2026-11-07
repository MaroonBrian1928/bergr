import XCTest

/// Holds the chat preview open with the keyboard up, for a screen recording of whether the
/// conversation moves by itself.
final class ChatBounceTests: XCTestCase {
    @MainActor
    func testChatHoldsStillWithKeyboardUp() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-bergr.chatPreview", "YES", "-bergr.chatPreviewLive", "YES", "-bergr.chatPreviewWorking", "YES"]
        app.launch()
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        sleep(8)
    }
}
