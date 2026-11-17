import XCTest

/// Walks the demo machines through every screen the App Store shot list asks for
/// (`plans/screenshot-shotlist.md`) and saves one picture per frame. Set BERGR_SHOTS
/// (TEST_RUNNER_BERGR_SHOTS for xcodebuild) to the folder; without it the pictures are only
/// attached to the test. Everything shown is the demo's fixed text, so two runs match.
final class DemoShotsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES"] + extra
        if let appearance = ProcessInfo.processInfo.environment["BERGR_SHOT_APPEARANCE"] {
            app.launchArguments += ["-appearance", appearance]
        }
        app.launch()
        return app
    }

    /// Frames 1, 2, 9 and 6: the agents list with the away card, the finished Claude turn with its
    /// summaries and reply chips, its Changes sheet, and Usage over seven days.
    @MainActor
    func testListChatChangesUsage() throws {
        let app = launch(["-bergr.demoAway", "YES"])
        XCTAssertTrue(row(app, "t3").waitForExistence(timeout: 15), "the demo's agents show")
        XCTAssertTrue(row(app, "t11").waitForExistence(timeout: 10), "also the second machine's")
        XCTAssertTrue(row(app, "t21").waitForExistence(timeout: 10), "and the third's")
        XCTAssertTrue(app.staticTexts["Wants to run the orders migration"].waitForExistence(timeout: 10), "the away card")
        pause(1)
        shot(app, "01-agents")

        // The finished turn.
        row(app, "t1").tap()
        XCTAssertTrue(text(app, "Dark mode toggle is ready").waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, "48 tests passed in 12 seconds").exists, "the test run's summary")
        XCTAssertTrue(text(app, "20 files changed, mostly header and theme styles").exists)
        XCTAssertTrue(text(app, "Build succeeded; bundle grew by 2 KB").exists)
        XCTAssertTrue(app.buttons.matching(identifier: "reply-chip").firstMatch.waitForExistence(timeout: 5), "reply chips")
        pause(1.5)
        shot(app, "02-chat-summaries")

        // Commands after a slash.
        let field = replyField(app)
        XCTAssertTrue(field.exists, "the reply box")
        field.tap()
        dismissKeyboardHint(app)
        field.typeText("/re")
        XCTAssertTrue(text(app, "/review").waitForExistence(timeout: 5), "commands that match")
        pause(1)
        shot(app, "02e-chat-commands")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        if app.buttons["Hide Keyboard"].exists { app.buttons["Hide Keyboard"].tap() } else { app.swipeDown(velocity: .slow) }
        pause(1)

        // Message times, on a sideways drag.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        middle.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45)),
                     withVelocity: .slow, thenHoldForDuration: 1.2)
        shot(app, "02b-chat-after-time-drag")

        // Further up: the plan, and the run with the failed step.
        app.swipeDown()
        pause(1)
        shot(app, "02c-chat-earlier")
        let failed = app.buttons.matching(NSPredicate(format: "label CONTAINS '1 failed'")).firstMatch
        if failed.waitForExistence(timeout: 3) {
            failed.tap()
            pause(1)
            shot(app, "02d-chat-failed-step-open")
            failed.tap()
        }

        // Usage from the chat: context, plan windows and their history.
        if app.buttons["Context"].firstMatch.exists {
            app.buttons["Context"].firstMatch.tap()
            pause(1.5)
            shot(app, "02f-chat-usage")
            close(app)
        }

        // Changes.
        let changes = app.buttons["Changes"].firstMatch
        if changes.waitForExistence(timeout: 3) {
            changes.tap()
            XCTAssertTrue(text(app, "Adds a dark mode toggle").waitForExistence(timeout: 10), "the staged summary")
            pause(1.5)
            shot(app, "09-changes")
            let header = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Header.tsx'")).firstMatch
            if header.exists {
                header.tap()
                pause(1.5)
                shot(app, "09b-changes-diff")
            }
            close(app)
        }
        back(app)

        // Usage, the last 24 hours: each 5-hour window reads as a climb and a reset (at 7 days they
        // squeeze into spikes).
        app.buttons["Settings"].firstMatch.tap()
        let usage = app.staticTexts["Usage"].firstMatch
        for _ in 0..<3 where !(usage.exists && usage.isHittable) { app.swipeUp() }
        usage.tap()
        XCTAssertTrue(text(app, "Current session").waitForExistence(timeout: 10), "plan windows show")
        pause(1.5)
        shot(app, "06-usage")
        app.swipeUp()
        pause(1)
        shot(app, "06b-usage-more")
    }

    /// Frames 3 and 4: the permission prompt as a card, then (after Yes) the dangerous one with
    /// its explanation.
    @MainActor
    func testAnswerCards() throws {
        let app = launch()
        XCTAssertTrue(row(app, "t3").waitForExistence(timeout: 15))
        row(app, "t3").tap()
        let yes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Yes' AND NOT label CONTAINS 'ask'")).firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 10), "the answer card shows")
        XCTAssertTrue(text(app, "npm run migrate -- --name add_order_totals").exists, "with the command")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS \"don't ask again\"")).firstMatch.exists)
        pause(1.5)
        shot(app, "03-answer-card")

        yes.tap()
        pause(1.5)
        shot(app, "03b-migration-running")
        XCTAssertTrue(text(app, "Dangerous").waitForExistence(timeout: 15), "the second prompt is flagged")
        XCTAssertTrue(text(app, "Permanently deletes the order_totals_old table").waitForExistence(timeout: 5),
                      "with the staged explanation")
        pause(1)
        shot(app, "04-dangerous-command")
    }

    /// Frame 7 and the live run: Codex's question with the "Answers: …" composer and a scanned
    /// sketch attached, then the one agent that is at work.
    @MainActor
    func testCodexQuestionAndLiveRun() throws {
        let app = launch(["-bergr.demoAttach", "YES"])
        XCTAssertTrue(row(app, "t11").waitForExistence(timeout: 15))
        // The working agent first, while it works.
        row(app, "t11").tap()
        XCTAssertTrue(text(app, "Two sub-agents").waitForExistence(timeout: 10))
        pause(3)
        shot(app, "10-codex-working")
        back(app)

        row(app, "t12").tap()
        XCTAssertTrue(text(app, "In Redis").waitForExistence(timeout: 10), "the question card")
        XCTAssertTrue(text(app, "Answers: Where should").waitForExistence(timeout: 5), "the reply answers it")
        pause(1.5)
        shot(app, "07a-codex-question")
        let field = replyField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        dismissKeyboardHint(app)
        field.typeText("Use Redis, like in this sketch")
        pause(1)
        shot(app, "07-codex-reply")
        back(app)

        // The idle one, on the Windows machine.
        row(app, "t21").tap()
        XCTAssertTrue(text(app, "50 runs in a row").waitForExistence(timeout: 10))
        pause(1.5)
        shot(app, "11-antigravity-idle")
        back(app)

        // By now the working agent has finished.
        XCTAssertTrue(app.staticTexts["Upgraded Postgres to 18"].waitForExistence(timeout: 45), "the run ends")
        row(app, "t11").tap()
        XCTAssertTrue(text(app, "Postgres 18.1").waitForExistence(timeout: 10))
        pause(1.5)
        shot(app, "10b-codex-finished")
    }

    /// The limit bar with Continue Then (Claude's session used up), and the "+" menu with a scanned
    /// sketch already attached.
    @MainActor
    func testLimitBarAndAttachMenu() throws {
        let app = launch(["-bergr.demoLimit", "YES", "-bergr.demoAttach", "YES"])
        XCTAssertTrue(row(app, "t1").waitForExistence(timeout: 15))
        row(app, "t1").tap()
        XCTAssertTrue(text(app, "Limit reached").waitForExistence(timeout: 10), "the limit bar")
        XCTAssertTrue(app.buttons["Continue Then"].exists, "with Continue Then")
        pause(1.5)
        shot(app, "05-continue-then")
        back(app)

        row(app, "t12").tap()
        let attach = app.buttons["Attach image"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "the + button")
        pause(1)
        attach.tap()
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5), "the menu")
        pause(1)
        shot(app, "08-attach-menu")
    }

    /// The Lock Screen with the Live Activity (Bergr kept running, full content).
    @MainActor
    func testLockScreenLiveActivity() throws {
        let app = launch(["-bergr.keepConnectedInBackground", "YES", "-bergr.liveActivity.push", "YES",
                          "-bergr.liveActivity.content", "full"])
        XCTAssertTrue(row(app, "t3").waitForExistence(timeout: 15))
        pause(4)
        XCUIDevice.shared.press(.home)
        pause(4)
        screenShot("12-home-live-activity")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        pause(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'Always Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            pause(1)
            XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
            pause(2)
            XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
            pause(3)
        }
        screenShot("13-lock-live-activity")
    }

    // MARK: Helpers

    private func row(_ app: XCUIApplication, _ address: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: address).firstMatch
    }

    private func text(_ app: XCUIApplication, _ part: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    private func replyField(_ app: XCUIApplication) -> XCUIElement {
        // A text view or a field, whichever SwiftUI made of it (the terminal is a text view too).
        let view = app.textViews.matching(NSPredicate(format: "identifier != 'terminal-screen'")).firstMatch
        return view.waitForExistence(timeout: 3) ? view : app.textFields.firstMatch
    }

    @MainActor
    private func dismissKeyboardHint(_ app: XCUIApplication) {
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
    }

    @MainActor
    private func close(_ app: XCUIApplication) {
        for name in ["Done", "Close"] where app.buttons[name].firstMatch.exists {
            app.buttons[name].firstMatch.tap()
            pause(0.8)
            return
        }
        app.swipeDown(velocity: .fast)
        pause(0.8)
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        if app.buttons["Hide Keyboard"].exists { app.buttons["Hide Keyboard"].tap() }
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() } else if button.exists { button.tap() }
        pause(1.2)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @MainActor
    private func screenShot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
