import Foundation
import HerdrKit
import Testing
import UserNotifications
@testable import bergr

@MainActor
struct AnswerNotificationTests {
    let host = UUID()
    let question = AnswerQuestion(title: "Run rm?", options: ["Yes", "No"], keys: true)
    let screen = ["Run rm -rf build? (y/n)", ""]

    func status(_ title: String = "Run rm?", state: String = "blocked") throws -> TerminalStatus {
        let json = "{\"state\":\"\(state)\",\"msg\":\"\(title)\",\"kind\":\"permission\"}"
        return try JSONDecoder().decode(TerminalStatus.self, from: Data(json.utf8))
    }

    func request(_ index: Int = 0) -> AnswerNotificationRequest {
        AnswerNotificationRequest(host: host, address: "t1", question: question, index: index)
    }

    final class Log {
        var sent: [[PromptStep]] = []
        var recorded: [String] = []
        var opened: [String] = []
        var closed = 0
    }

    func flow(_ log: Log, status: TerminalStatus?, lines: [String]?, connected: Bool = true) -> AnswerFlow {
        AnswerFlow(
            screen: { _ in
                guard connected else { return nil }
                return AnswerFlow.Screen(
                    status: status, lines: lines,
                    send: { log.sent.append($0) }, record: { log.recorded.append("\($0) -> \($1)") },
                    close: { log.closed += 1 })
            },
            openChat: { log.opened.append($1) })
    }

    @Test func categoryFollowsOptionCount() {
        #expect(AnswerCategory.identifier(optionCount: 1) == nil)
        #expect(AnswerCategory.identifier(optionCount: 2) == "bergr.answer.2")
        #expect(AnswerCategory.identifier(optionCount: 3) == "bergr.answer.3")
        #expect(AnswerCategory.identifier(optionCount: 4) == "bergr.answer.4")
        #expect(AnswerCategory.identifier(optionCount: 5) == nil)
        #expect(AnswerCategory.categories().map(\.identifier).sorted() == ["bergr.answer.2", "bergr.answer.3", "bergr.answer.4"])
        let four = AnswerCategory.categories().first { $0.identifier == "bergr.answer.4" }
        #expect(four?.actions.count == 4)
        #expect(four?.actions.allSatisfy { $0.options.contains(.foreground) && $0.options.contains(.authenticationRequired) } == true)
    }

    @Test func userInfoRoundTripsIntoARequest() throws {
        let info = AnswerCategory.userInfo(question)
        let request = try #require(AnswerCategory.request(
            actionIdentifier: AnswerCategory.actionIdentifier(index: 1), info: info, target: (host, "t1")))
        #expect(request.index == 1)
        #expect(request.question == question)
        #expect(AnswerCategory.request(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", info: info, target: (host, "t1")) == nil)
        #expect(AnswerCategory.request(actionIdentifier: AnswerCategory.actionIdentifier(index: 2), info: info, target: (host, "t1")) == nil)
    }

    @Test func inAppPermissionAlertCarriesTheQuestion() throws {
        #expect(AgentNotifier.question(for: try status()) == question)
        let json = "{\"state\":\"blocked\",\"kind\":\"question\"}"
        #expect(AgentNotifier.question(for: try JSONDecoder().decode(TerminalStatus.self, from: Data(json.utf8))) == nil)
        #expect(AgentNotifier.question(for: try status(state: "done")) == nil)
    }

    @Test func staleQuestionOpensTheChatAndSendsNothing() async throws {
        let log = Log()
        // The agent moved on to another question.
        await flow(log, status: try status("Delete it?"), lines: ["Delete it? (y/n)"]).run(request())
        #expect(log.sent.isEmpty && log.recorded.isEmpty)
        #expect(log.opened == ["t1"])
        // No longer blocked.
        let log2 = Log()
        await flow(log2, status: try status(state: "working"), lines: screen).run(request())
        #expect(log2.sent.isEmpty && log2.opened == ["t1"])
        // The screen shows numbered choices, which Yes / No keys would not answer.
        let log3 = Log()
        await flow(log3, status: try status(), lines: ["Run rm?", "", "❯ 1. Allow", "  2. Deny"]).run(request())
        #expect(log3.sent.isEmpty && log3.opened == ["t1"])
        // Could not connect in time.
        let log4 = Log()
        await flow(log4, status: nil, lines: nil, connected: false).run(request())
        #expect(log4.sent.isEmpty && log4.opened == ["t1"])
    }

    @Test func validQuestionSendsTheChosenOptionOnce() async throws {
        let log = Log()
        await flow(log, status: try status(), lines: screen).run(request(1))
        #expect(log.sent == [[.text("n")]])
        #expect(log.recorded.count == 1)
        #expect(log.opened.isEmpty)
        #expect(log.closed == 1)
    }

    @Test func numberedPermissionMenuMapsYesAndNo() async throws {
        let menu = ["Run rm?", "", "❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No"]
        let yes = Log()
        await flow(yes, status: try status(), lines: menu).run(request(0))
        #expect(yes.sent == [[.enter]])
        let no = Log()
        await flow(no, status: try status(), lines: menu).run(request(1))
        #expect(no.sent == [[.down, .down, .enter]])
        #expect(yes.opened.isEmpty && no.opened.isEmpty)
    }

    @Test func numberedQuestionPressesArrowsAndEnter() async throws {
        let numbered = AnswerQuestion(title: "Edit file?", options: ["Yes", "Yes, and don't ask again", "No"], keys: false)
        let request = AnswerNotificationRequest(host: host, address: "t1", question: numbered, index: 2)
        let log = Log()
        await flow(log, status: try status("Edit file?"),
                   lines: ["Edit file?", "", "❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No"]).run(request)
        #expect(log.sent == [[.down, .down, .enter]])
    }
}
