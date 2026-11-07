import XCTest

/// Adds a machine at an address with nothing listening and presses Test Connection: the form
/// must show the key block and a plain failure, not a raw error. Needs a signed simulator build
/// (keys live in the Keychain).
final class HostEditorConnectTests: XCTestCase {
    @MainActor
    func testConnectionFailureReads() throws {
        let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"]
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Running tests"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Machines"].tap()
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        app.buttons["Add Machine…"].tap()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("me@127.0.0.1:1\n")
        if let folder { save(app, folder, "connect-1-top") }
        app.swipeUp()
        if let folder { save(app, folder, "connect-2-key") }
        let test = app.buttons["Test Connection"]
        if !test.isHittable { app.swipeUp() }
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()
        let failure = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Nothing accepted SSH' OR label CONTAINS 'blocked' OR label CONTAINS 'reach'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "a plain failure shows")
        if let folder { save(app, folder, "connect-3-result") }
    }

    private func save(_ app: XCUIApplication, _ folder: String, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
