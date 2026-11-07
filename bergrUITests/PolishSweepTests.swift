import XCTest

/// Polish sweep screenshots into `TEST_RUNNER_BERGR_SHOTS`. Every step is best effort.
final class PolishSweepTests: XCTestCase {
    @MainActor
    func testSweep() throws {
        guard let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"] else { throw XCTSkip("no folder") }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for mode in ["dark", "light"] { run(mode, big: false, folder) }
        run("dark", big: true, folder)
    }

    private func launch(_ mode: String, big: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES",
                                "-bergr.demoChat", "YES", "-appearance", mode]
        if big { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        app.launch()
        _ = app.staticTexts["Running tests"].firstMatch.waitForExistence(timeout: 15)
        sleep(2)
        return app
    }

    private func shot(_ folder: String, _ name: String) {
        sleep(1)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    private func tap(_ e: XCUIElement, _ t: TimeInterval = 4) -> Bool {
        guard e.waitForExistence(timeout: t) else { return false }
        e.tap(); return true
    }

    @MainActor
    private func run(_ mode: String, big: Bool, _ folder: String) {
        let p = big ? "big-" : "\(mode)-"
        var app = launch(mode, big: big)
        shot(folder, p + "01-agents")
        if !tap(app.staticTexts["Running tests"].firstMatch) { return }
        sleep(3)
        shot(folder, p + "02-chat")
        if big {
            app.terminate(); app = launch(mode, big: big)
        } else {
            app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(1)
            shot(folder, p + "03-chat-top")
            let pred = NSPredicate(format: "placeholderValue BEGINSWITH 'Reply'")
            let f = app.textViews.matching(pred).firstMatch.exists ? app.textViews.matching(pred).firstMatch : app.textFields.matching(pred).firstMatch
            if f.exists { f.tap(); sleep(2); shot(folder, p + "04-chat-keyboard"); app.swipeDown(velocity: .fast) }
            if tap(app.buttons["More"].firstMatch, 2) { shot(folder, p + "05-more-menu"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
            sleep(1)
            if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model'")).firstMatch, 2) {
                shot(folder, p + "06-model-sheet"); app.swipeDown(velocity: .fast); sleep(1)
            }
            if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Context'")).firstMatch, 2) {
                shot(folder, p + "07-usage-sheet"); app.swipeDown(velocity: .fast); sleep(1)
            }
            if tap(app.buttons["Show Terminal"].firstMatch, 2) { sleep(2); shot(folder, p + "08-terminal") }
            app.terminate(); app = launch(mode, big: big)
            if tap(app.staticTexts["Run the database migration?"].firstMatch, 3) { sleep(3); shot(folder, p + "09-blocked-chat") }
            app.terminate(); app = launch(mode, big: big)
        }
        if tap(app.buttons["Settings"].firstMatch) {
            sleep(1); shot(folder, p + "10-settings")
            app.swipeUp(); shot(folder, p + "10b-settings-bottom")
            if !big {
                app.swipeDown(); app.swipeDown()
                let keys = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Keys'")).firstMatch
                if tap(keys, 2) || tap(app.staticTexts["Keys"].firstMatch, 2) { sleep(1); shot(folder, p + "11-keys") }
            }
        }
        if big { app.terminate(); return }
        app.terminate(); app = launch(mode, big: big)
        if tap(app.buttons["Machines"].firstMatch) {
            sleep(1); shot(folder, p + "12-machines")
            let title = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch
            if tap(title, 3), tap(app.buttons["Add Machine…"], 3) { sleep(1); shot(folder, p + "13-add-machine") }
        }
        app.terminate()
    }
}
