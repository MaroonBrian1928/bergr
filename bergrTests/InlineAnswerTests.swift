import Foundation
import HerdrKit
import Testing
@testable import bergr

@MainActor
struct InlineAnswerTests {
    let host = UUID()

    func status(_ msg: String = "Run npm test?", state: String = "blocked", kind: String = "permission") throws -> TerminalStatus {
        let json = "{\"state\":\"\(state)\",\"msg\":\"\(msg)\",\"kind\":\"\(kind)\"}"
        return try JSONDecoder().decode(TerminalStatus.self, from: Data(json.utf8))
    }

    func term(_ st: TerminalStatus) throws -> Terminal {
        let status = try JSONEncoder().encode(st)
        let json = "{\"address\":\"t1\",\"name\":\"api\",\"state\":\"live\",\"status\":" + String(decoding: status, as: UTF8.self) + "}"
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func yesNoPermissionPromptGetsButtons() throws {
        #expect(InlineAnswer.options(status: try status()) == ["Yes", "No"])
    }

    @Test func otherPromptsGetNone() throws {
        #expect(InlineAnswer.options(status: try status(kind: "question")).isEmpty)
        #expect(InlineAnswer.options(status: try status(state: "working")).isEmpty)
        #expect(InlineAnswer.options(status: nil).isEmpty)
    }

    @Test func dangerousCommandGetsNone() throws {
        #expect(InlineAnswer.options(status: try status("Run rm -rf / ?")).isEmpty)
    }

    @Test func numberedYesNoChoicesAreMapped() throws {
        let lines = ["Do you want to proceed?", "❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No, and tell Claude what to do"]
        #expect(InlineAnswer.options(status: try status(), lines: lines) == ["Yes", "No"])
        let other = ["Pick a color", "❯ 1. Red", "  2. Blue"]
        #expect(InlineAnswer.options(status: try status(kind: "question"), lines: other).isEmpty)
    }

    @Test func dispatchRecordsAsTheAnswerCard() async throws {
        final class Log { var sent: [[PromptStep]] = []; var recorded: [(String, String, ApprovalEntry.Source)] = []; var closed = 0 }
        let log = Log()
        let st = try status()
        let terminal = try #require(InlineAnswer.request(host: host, terminal: try term(st), index: 0))
        let outcome = await InlineAnswer.perform(terminal, connect: { _, _ in
            AnswerFlow.Screen(
                status: st, lines: ["Run npm test? (y/n)"], send: { log.sent.append($0) },
                record: { _, _ in }, close: { log.closed += 1 })
        }, record: { log.recorded.append(($0, $1, $2)) })
        #expect(outcome == .sent)
        #expect(log.sent == [[.text("y")]])
        #expect(log.recorded.count == 1 && log.recorded[0].1 == "Yes" && log.recorded[0].2 == .card)
        #expect(log.closed == 1)
    }

    @Test func changedPromptPressesNothing() async throws {
        final class Log { var sent = 0; var recorded = 0 }
        let log = Log()
        let st = try status()
        let request = try #require(InlineAnswer.request(host: host, terminal: try term(st), index: 0))
        let outcome = await InlineAnswer.perform(request, connect: { _, _ in
            AnswerFlow.Screen(status: try? status("Another question?"), lines: ["Another question? (y/n)"], send: { _ in log.sent += 1 },
                              record: { _, _ in }, close: {})
        }, record: { _, _, _ in log.recorded += 1 })
        #expect(outcome == .changed && log.sent == 0 && log.recorded == 0)
        let failed = await InlineAnswer.perform(request, connect: { _, _ in nil }, record: { _, _, _ in })
        #expect(failed == .failed)
    }
}
