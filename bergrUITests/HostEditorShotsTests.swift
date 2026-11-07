import XCTest

/// Screenshots of the Add Machine form (TEST_RUNNER_BERGR_SHOTS=<folder>).
final class HostEditorShotsTests: XCTestCase {
    @MainActor
    func testAddMachineShots() throws {
        guard let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"] else { throw XCTSkip("BERGR_SHOTS not set") }
        for style in ["Dark", "Light"] {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES",
                                    "-appearance", style.lowercased()]
            app.launch()
            XCTAssertTrue(app.staticTexts["Running tests"].firstMatch.waitForExistence(timeout: 15))
            app.buttons["Machines"].tap()
            let title = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap()
            let add = app.buttons["Add Machine…"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            let field = app.textFields["address-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("me@192.168.1.20")
            field.typeText("\n")
            // Unsigned simulator builds cannot create keys (keychain entitlement), so the
            // "Let this phone in" block does not show here.
            shot(folder, "\(style.lowercased())-1-top")
            app.swipeUp()
            shot(folder, "\(style.lowercased())-2-mid")
            app.swipeUp()
            shot(folder, "\(style.lowercased())-3-bottom")
            app.terminate()
        }
    }

    private func shot(_ folder: String, _ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("hosteditor-\(name).png"))
    }
}
