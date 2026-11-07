import XCTest

/// Screenshots of Settings and Machines, light and dark, into `TEST_RUNNER_BERGR_SHOTS`.
final class SettingsShotsTests: XCTestCase {
    @MainActor
    func testSettingsShots() throws {
        let folder = ProcessInfo.processInfo.environment["BERGR_SHOTS"] ?? ""
        try XCTSkipIf(folder.isEmpty, "BERGR_SHOTS not set")
        for mode in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-bergr.demo", "YES",
                                    "-appearance", mode]
            app.launch()
            let gear = app.buttons["Settings"].firstMatch
            XCTAssertTrue(gear.waitForExistence(timeout: 15))
            sleep(2)
            gear.tap()
            sleep(2)
            shot("settings-\(mode)-1", folder)
            app.swipeUp()
            sleep(1)
            shot("settings-\(mode)-2", folder)
            app.buttons["Done"].firstMatch.tap()
            app.buttons["Machines"].firstMatch.tap()
            sleep(1)
            app.buttons["Demo machine"].firstMatch.tap()
            app.buttons["Manage Machines…"].firstMatch.tap()
            sleep(2)
            shot("machines-\(mode)", folder)
            app.terminate()
        }
    }

    private func shot(_ name: String, _ folder: String) {
        let image = XCUIScreen.main.screenshot()
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
