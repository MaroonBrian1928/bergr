import XCTest

/// The iPad App Store set (`just appstore-shots dark "iPad Pro 13-inch (M5)"`): the demo in landscape,
/// list and chat side by side. Saves to BERGR_SHOTS like `DemoShotsTests`; skipped on an iPhone.
final class DemoPadShotsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES"] + extra
        if let appearance = ProcessInfo.processInfo.environment["BERGR_SHOT_APPEARANCE"] {
            app.launchArguments += ["-appearance", appearance]
        }
        app.launch()
        return app
    }

    /// The list with the finished turn beside it, the two prompts, two chats side by side, Usage.
    @MainActor
    func testPadListChatsUsage() throws {
        let app = launch(["-bergr.demoAway", "YES"])
        XCTAssertTrue(row(app, "t3").waitForExistence(timeout: 15), "the demo's agents show")
        row(app, "t1").tap()
        XCTAssertTrue(text(app, "Dark mode toggle is ready").waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, "48 tests passed in 12 seconds").exists, "the test run's summary")
        pause(2)
        shot(app, "p01-list-summaries")

        row(app, "t3").tap()
        let yes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Yes' AND NOT label CONTAINS 'ask'")).firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 10), "the answer card shows")
        pause(1.5)
        shot(app, "p02-answer-card")
        yes.tap()
        XCTAssertTrue(text(app, "Dangerous").waitForExistence(timeout: 15), "the second prompt is flagged")
        XCTAssertTrue(text(app, "Permanently deletes the order_totals_old table").waitForExistence(timeout: 5))
        pause(1)
        shot(app, "p03-dangerous-command")

        // Two conversations side by side: the working Codex run beside the Claude one.
        row(app, "t11").press(forDuration: 1.2)
        let beside = app.buttons["Open Beside"].firstMatch
        if beside.waitForExistence(timeout: 5) {
            beside.tap()
            XCTAssertTrue(text(app, "Two sub-agents").waitForExistence(timeout: 10))
            pause(2)
            shot(app, "p04-side-by-side")
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap(); pause(1) }
        } else {
            XCTFail("no Open Beside in the row's menu")
        }

        app.buttons["Settings"].firstMatch.tap()
        let usage = app.staticTexts["Usage"].firstMatch
        for _ in 0..<3 where !(usage.waitForExistence(timeout: 2) && usage.isHittable) { app.swipeUp() }
        usage.tap()
        XCTAssertTrue(text(app, "Current session").waitForExistence(timeout: 10), "plan windows show")
        pause(1.5)
        shot(app, "p05-usage")
    }

    /// Codex's question with a scanned sketch attached and an answer typed.
    @MainActor
    func testPadCodexReply() throws {
        let app = launch(["-bergr.demoAttach", "YES"])
        XCTAssertTrue(row(app, "t12").waitForExistence(timeout: 15))
        row(app, "t12").tap()
        XCTAssertTrue(text(app, "In Redis").waitForExistence(timeout: 10), "the question card")
        let view = app.textViews.matching(NSPredicate(format: "identifier != 'terminal-screen'")).firstMatch
        let field = view.waitForExistence(timeout: 3) ? view : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        field.typeText("Use Redis, like in this sketch")
        pause(1)
        shot(app, "p06-codex-reply")
    }

    // MARK: Helpers

    private func row(_ app: XCUIApplication, _ address: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: address).firstMatch
    }

    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// The whole screen (an app screenshot of a landscape iPad can come back portrait-sized).
    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
