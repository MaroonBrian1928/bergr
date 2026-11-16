import Foundation
import HerdrKit
import Testing
@testable import bergr

@MainActor
struct ApprovalSafetyTests {
    @Test func dangerousCommandsAreFlagged() {
        let yes = ["rm -rf build", "rm -fr /", "rm -r -f x", "rm -Rf x", "git push --force", "git push -f origin x",
                   "git push origin main --force-with-lease", "git reset --hard HEAD~1", "git clean -fd", "sudo rm x",
                   "mkfs.ext4 /dev/sda1", "dd if=/dev/zero of=/dev/sda", "DROP TABLE users", "drop database x",
                   "TRUNCATE users", "chmod -R 777 /srv", "echo x > /dev/sda", "rails db:migrate:reset",
                   "prisma migrate reset", "artisan migrate:rollback"]
        for text in yes { #expect(DangerousCommand.check(text) != nil, "\(text)") }
    }

    @Test func nearMissesAreNot() {
        let no = ["rm file", "rm -f file", "rm -r dir", "git push", "git push -u origin main", "git reset HEAD file",
                  "git clean -n", "pseudo sudoku", "chmod 755 x", "chmod -R 755 x", "dd of=x", "migrate up",
                  "output truncated", "ls > /dev/null", "git push --follow-tags"]
        for text in no { #expect(DangerousCommand.check(text) == nil, "\(text)") }
    }

    @Test func dangerousPromptGetsNoApproveButtons() throws {
        func status(_ msg: String) throws -> TerminalStatus {
            let json = "{\"state\":\"blocked\",\"msg\":\"\(msg)\",\"kind\":\"permission\"}"
            return try JSONDecoder().decode(TerminalStatus.self, from: Data(json.utf8))
        }
        #expect(AgentNotifier.question(for: try status("Bash: rm -rf /tmp/x")) == nil)
        #expect(AgentNotifier.question(for: try status("Bash: rm file")) != nil)
    }

    @Test func replyTextReachesTheSendPathOnce() async {
        final class Log { var sent: [[PromptStep]] = []; var opened = 0; var closed = 0 }
        let log = Log()
        let host = UUID()
        let flow = AnswerFlow(
            screen: { _ in nil }, openChat: { _, _ in log.opened += 1 },
            replyScreen: { _ in
                AnswerFlow.Screen(status: nil, lines: ["> "], send: { log.sent.append($0) },
                                  record: { _, _ in }, close: { log.closed += 1 })
            })
        let request = AnswerCategory.replyRequest(
            actionIdentifier: AnswerCategory.replyAction, text: "  use main\nplease ", target: (host, "t1"))
        #expect(request?.text == "use main\nplease")
        await flow.reply(request!)
        #expect(log.sent == [[.text("use main please"), .enter]])
        #expect(log.opened == 0 && log.closed == 1)
        #expect(AnswerCategory.replyRequest(actionIdentifier: AnswerCategory.replyAction, text: "  ", target: (host, "t1")) == nil)
        #expect(AnswerCategory.replyRequest(actionIdentifier: "other", text: "hi", target: (host, "t1")) == nil)
    }

    @Test func replyIsNeverTypedIntoAPermissionPrompt() async throws {
        final class Log { var sent: [[PromptStep]] = []; var opened: [String] = []; var closed = 0 }
        let defaults = try #require(UserDefaults(suiteName: "bergr.tests.reply.\(UUID().uuidString)"))
        let json = "{\"state\":\"blocked\",\"msg\":\"Bash: rm -rf build\",\"kind\":\"permission\"}"
        let blocked = try JSONDecoder().decode(TerminalStatus.self, from: Data(json.utf8))
        let menu = ["Do you want to proceed?", "❯ 1. Yes", "  2. No, and tell Claude what to do differently", ""]
        let host = UUID()
        // Blocked by status, or a menu on screen while the status says otherwise: nothing is typed.
        for (status, lines) in [(Optional(blocked), menu), (nil, menu), (Optional(blocked), ["> "])] {
            let log = Log()
            var flow = AnswerFlow(
                screen: { _ in nil }, openChat: { log.opened.append($1) },
                replyScreen: { _ in
                    AnswerFlow.Screen(status: status, lines: lines, send: { log.sent.append($0) },
                                      record: { _, _ in }, close: { log.closed += 1 })
                })
            flow.draftDefaults = defaults
            ReplyDrafts.set("", for: "\(host.uuidString)|t1", in: defaults)
            await flow.reply(ReplyNotificationRequest(host: host, address: "t1", text: "no, don't"))
            #expect(log.sent.isEmpty)
            #expect(log.opened == ["t1"] && log.closed == 1)
            #expect(ReplyDrafts.text(for: "\(host.uuidString)|t1", in: defaults) == "no, don't")
        }
    }

    @Test func dangerousScreenIsNeverAnsweredFromAButton() async throws {
        final class Log { var sent: [[PromptStep]] = []; var recorded = 0; var opened = 0 }
        let log = Log()
        let title = "Run rm -rf build?"
        let json = "{\"state\":\"blocked\",\"msg\":\"\(title)\",\"kind\":\"permission\"}"
        let status = try JSONDecoder().decode(TerminalStatus.self, from: Data(json.utf8))
        let flow = AnswerFlow(
            screen: { _ in
                AnswerFlow.Screen(status: status, lines: ["\(title) (y/n)", ""], send: { log.sent.append($0) },
                                  record: { _, _ in log.recorded += 1 }, close: {})
            },
            openChat: { _, _ in log.opened += 1 })
        let question = AnswerQuestion(title: title, options: ["Yes", "No"], keys: true)
        await flow.run(AnswerNotificationRequest(host: UUID(), address: "t1", question: question, index: 0))
        #expect(log.sent.isEmpty && log.recorded == 0 && log.opened == 1)
    }

    @MainActor @Test func replyToACodexQuestionSelectsItThenSends() async throws {
        final class Log { var sent: [[PromptStep]] = []; var selected = false }
        let log = Log()
        let status = try JSONDecoder().decode(TerminalStatus.self,
            from: Data(#"{"state":"blocked","app":"codex","kind":"question","msg":"Which branch?"}"#.utf8))
        let flow = AnswerFlow(
            screen: { _ in nil }, openChat: { _, _ in Issue.record("opened the chat") },
            replyScreen: { _ in
                AnswerFlow.Screen(status: status, lines: ["› "],
                                  send: { steps in
                                      log.sent.append(steps)
                                      if steps == [.previousQuestion] { log.selected = true }
                                  },
                                  currentLines: { log.selected ? ["Re: Which branch?", "› "] : ["› "] },
                                  record: { _, _ in }, close: {})
            })
        let outcome = await flow.reply(ReplyNotificationRequest(host: UUID(), address: "t1", text: "main",
                                                                question: "Which branch?"))
        #expect(outcome == .sent)
        #expect(log.sent == [[.previousQuestion], [.text("main")], [.enter]])
    }

    @Test func replyOpensTheChatWhenTheConnectionFails() async {
        final class Log { var opened: [String] = [] }
        let log = Log()
        let flow = AnswerFlow(
            screen: { _ in nil }, openChat: { log.opened.append($1) }, replyScreen: { _ in nil })
        await flow.reply(ReplyNotificationRequest(host: UUID(), address: "t1", text: "hi"))
        #expect(log.opened == ["t1"])
    }

    @Test func replyIsOfferedOnEveryPlatform() {
        #expect(AnswerCategory.replyEnabled)
        #expect(AnswerCategory.replyIdentifier == "bergr.reply")
    }

    @Test func approvalLogAppendsAndCapsAtFiveHundred() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<(ApprovalLog.limit + 3) {
            ApprovalLog.record(
                machine: "m", agent: "claude-code", question: index == 502 ? "Bash: rm -rf x" : "q\(index)",
                answer: "Yes", source: .card, to: url)
        }
        let entries = ApprovalLog.load(from: url)
        #expect(entries.count == 500)
        #expect(entries.first?.question == "q3")
        #expect(entries.last?.dangerous == true)
        #expect(entries.last?.source == .card)
    }
}
