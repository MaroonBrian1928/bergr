import XCTest

final class CodexQuestionTests: XCTestCase {
    @MainActor func testFreeformQuestionInBothAppearances() throws {
        let app = XCUIApplication()
        for style in ["Light", "Dark"] {
            app.launchArguments = ["-bergr.chatPreview", "YES", "-bergr.chatPreviewLive", "YES",
                                   "-bergr.previewAsyncQuestion", "YES", "-AppleInterfaceStyle", style,
                                   "-appearance", style.lowercased()]
            app.launch()
            let field = app.textFields["codex-question-answer"]
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["codex-question-send"].exists)
            field.tap()
            field.typeText("src/example.swift")
            XCTAssertTrue(app.buttons["codex-question-send"].isEnabled)
            if let directory = ProcessInfo.processInfo.environment["BERGR_SHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("codex-question-\(style.lowercased())-\(Int(app.frame.width)).png"))
            }
            app.terminate()
        }
    }
}
