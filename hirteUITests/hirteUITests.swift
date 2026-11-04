import XCTest

/// Walks through the demo machine. Set HIRTE_SHOTS (TEST_RUNNER_HIRTE_SHOTS for xcodebuild)
/// to a folder to also save screenshots there, e.g. for the App Store.
final class DemoTourTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoTour() throws {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        if environment["HIRTE_SHOTS"] != nil {
            // Screenshots: English, and a terminal font that fills the screen without wrapping.
            let fontSize = environment["HIRTE_SHOT_FONT"] ?? "17"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-terminal.fontSize", fontSize]
        }
        app.launch()

        startDemo(app)

        XCTAssertTrue(app.staticTexts["website"].waitForExistence(timeout: 10), "demo spaces appear")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.exists)
        sleep(1)
        shot(app, "1-terminals")

        open(app, "t1")
        sleep(2)
        shot(app, "2-agent")
        back(app)

        open(app, "t3")
        sleep(2)
        shot(app, "3-needs-you")
        back(app)

        // A shell with the keyboard and key bar up.
        open(app, "t5")
        sleep(1)
        let keyboard = app.buttons["Show Keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        sleep(1)
        // iOS explains slide-to-type the first time a keyboard appears.
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("git status\n")
        sleep(1)
        shot(app, "4-shell")
        app.buttons["Hide Keyboard"].tap()
        back(app)

        open(app, "t2")
        sleep(4)
        shot(app, "5-tests")
    }

    /// The README video, recorded by `scripts/video.sh`: the demo at a pace people can follow.
    /// Only runs with HIRTE_VIDEO set to a folder; it writes `start` and `end` (Unix times) there,
    /// so the script can cut the recording to the app.
    @MainActor
    func testVideoTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let marks = environment["HIRTE_VIDEO"] else { throw XCTSkip("HIRTE_VIDEO is not set") }
        let app = XCUIApplication()
        let fontSize = environment["HIRTE_SHOT_FONT"] ?? "15"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-terminal.fontSize", fontSize]
        app.launch()
        let tryDemo = app.buttons["Try the Demo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10), "a fresh install offers the demo")
        mark(marks, "start")
        pause(1.5)
        tryDemo.tap()

        // Everything at a glance; the blocked agent sits on top.
        XCTAssertTrue(app.staticTexts["website"].waitForExistence(timeout: 10))
        pause(3)

        // An agent at work.
        open(app, "t1")
        pause(3)
        back(app)
        pause(1)

        // The blocked one: answer in a tap and watch it go.
        open(app, "t3")
        pause(2.5)
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "the needs-you bar shows")
        yes.tap()
        pause(5)
        back(app)
        pause(2)

        // A real terminal: type, then pinch to zoom.
        open(app, "t5")
        pause(1)
        app.buttons["Show Keyboard"].tap()
        pause(1)
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        for character in "git log" {
            app.typeText(String(character))
            pause(0.08)
        }
        app.typeText("\n")
        pause(1.5)
        app.buttons["Hide Keyboard"].tap()
        pause(0.5)
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        screen.pinch(withScale: 2.2, velocity: 1.5)
        pause(2)
        screen.pinch(withScale: 0.45, velocity: -1.5)
        pause(1.5)
        back(app)
        // Back on the list: the migration went through.
        pause(2.5)
        mark(marks, "end")
    }

    /// The video on a real device (`scripts/video-device.sh`), made for the unfolded iPhone Duo: the
    /// app records itself (ReplayKit, Debug builds) and stops when the test sends it home. Opens the
    /// demo machine without touching the other machines. Only runs with HIRTE_DEVICE_VIDEO set.
    @MainActor
    func testDeviceVideoTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["HIRTE_DEVICE_VIDEO"] else { throw XCTSkip("HIRTE_DEVICE_VIDEO is not set") }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hirte.demo", "YES", "-hirte.record", name]
        if let fontSize = environment["HIRTE_SHOT_FONT"] { app.launchArguments += ["-terminal.fontSize", fontSize] }
        app.launch()
        allowScreenRecording(app)
        XCTAssertTrue(app.staticTexts["website"].waitForExistence(timeout: 10), "the demo's terminals show")
        pause(2.5)

        // An agent at work.
        open(app, "t1")
        pause(3)
        backIfStacked(app)

        // The blocked one: answer in a tap and watch it go.
        open(app, "t3")
        pause(2.5)
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "the needs-you bar shows")
        yes.tap()
        pause(5)
        backIfStacked(app)

        // A real terminal: type, then pinch to zoom.
        open(app, "t5")
        pause(1)
        app.buttons["Show Keyboard"].tap()
        pause(1)
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("git log")
        pause(0.5)
        app.typeText("\n")
        pause(2)
        app.buttons["Hide Keyboard"].tap()
        pause(0.5)
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        screen.pinch(withScale: 2.2, velocity: 1.5)
        pause(2)
        screen.pinch(withScale: 0.45, velocity: -1.5)
        pause(1.5)
        backIfStacked(app)

        // Tests streaming in.
        open(app, "t2")
        pause(4)

        // Home: the app stops recording and writes the file.
        XCUIDevice.shared.press(.home)
        pause(4)
    }

    /// iOS asks before an app records its screen (again after some minutes). Taps the button that
    /// allows it, in any language: the one that isn't "Don't Allow" / "Nicht erlauben".
    @MainActor
    private func allowScreenRecording(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                let refuse = NSPredicate(format: "label CONTAINS[c] 'don' OR label CONTAINS[c] 'nicht' OR label CONTAINS[c] 'not'")
                let accept = alert.buttons.allElementsBoundByIndex.first { !refuse.evaluate(with: $0) }
                accept?.tap()
                return
            }
            pause(0.2)
        }
    }

    /// Two columns (unfolded Duo) keep the list next to the terminal; a stack needs going back.
    @MainActor
    private func backIfStacked(_ app: XCUIApplication) {
        let list = app.staticTexts["website"]
        if !(list.exists && list.isHittable) { back(app) }
        pause(1)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func mark(_ folder: String, _ name: String) {
        let now = String(Date().timeIntervalSince1970)
        try? now.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Pinch to zoom: the font changes once per gesture and the screen comes back crisp.
    @MainActor
    func testPinchZoom() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        sleep(2)
        shot(app, "zoom-0-start")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        screen.pinch(withScale: 1.6, velocity: 1)
        sleep(1)
        shot(app, "zoom-1-in")
        screen.pinch(withScale: 0.6, velocity: -1)
        sleep(1)
        shot(app, "zoom-2-out")
    }

    /// One sidebar: the machine is picked from the list's title.
    @MainActor
    func testMachineSwitcher() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        XCTAssertTrue(app.staticTexts["website"].waitForExistence(timeout: 10), "the demo's terminals show")
        shot(app, "switcher-0-list")
        // The title is a menu button: "Demo machine ⌄".
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let manage = app.buttons["Manage Machines…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), "the title opens the switcher")
        shot(app, "switcher-1-menu")
        manage.tap()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 5))
        shot(app, "switcher-2-manage")
    }

    /// Settings: the font preview, the demo button and About.
    @MainActor
    func testSettings() throws {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5))
        shot(app, "settings")
        // A row's label is its title and value: "Dark Theme, Hirte Dark".
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dark Theme'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Dracula"].waitForExistence(timeout: 5))
        shot(app, "settings-dark-themes")
        back(app)

        // Licenses: the list, then one license's text.
        app.swipeUp()
        let licenses = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open-Source Licenses'")).firstMatch
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.tap()
        let ghostty = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ghostty'")).firstMatch
        XCTAssertTrue(ghostty.waitForExistence(timeout: 5), "the licenses list shows")
        shot(app, "settings-licenses")
        ghostty.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'MIT License'")).firstMatch
            .waitForExistence(timeout: 5), "a license's text shows")
        shot(app, "settings-license-ghostty")
    }

    /// The appearance setting reaches sheets too, and switching it applies at once (also back to System).
    @MainActor
    func testAppearanceInSettings() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        sleep(1)
        shot(app, "appearance-dark")
        app.buttons["Light"].tap()
        sleep(1)
        shot(app, "appearance-light")
        app.buttons["System"].tap()
        sleep(1)
        shot(app, "appearance-system")
    }

    /// A light terminal theme: the screen, its title bar and the keyboard follow it.
    @MainActor
    func testLightTheme() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-appearance", "light", "-theme.light", "catppuccin-latte", "-terminal.fontSize", "15"]
        app.launch()
        startDemo(app)
        open(app, "t1")
        sleep(2)
        shot(app, "theme-light-agent")
        back(app)
        open(app, "t3")
        sleep(2)
        shot(app, "theme-light-needs-you")
    }

    /// A fresh install offers the demo in its empty state; later launches open on the last machine.
    @MainActor
    private func startDemo(_ app: XCUIApplication) {
        let tryDemo = app.buttons["Try the Demo"]
        if tryDemo.waitForExistence(timeout: 5) { tryDemo.tap() }
        XCTAssertTrue(app.staticTexts["website"].waitForExistence(timeout: 10), "the demo's terminals show")
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ address: String) {
        // Rows carry their terminal's address as identifier (the address itself isn't shown).
        let row = app.descendants(matching: .any).matching(identifier: address).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(address) is listed")
        row.tap()
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        // The back button sits in a side rail on wide screens, in the navigation bar otherwise.
        for candidate in [app.buttons["BackButton"], app.buttons["Demo machine"], app.buttons["Back"]] where candidate.exists {
            candidate.tap()
            return
        }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
