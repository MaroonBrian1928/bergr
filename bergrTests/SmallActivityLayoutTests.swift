import Foundation
import Testing
@testable import bergr

struct SmallActivityLayoutTests {
    typealias B = BergrActivityAttributes
    let row = B.Row(kind: "claude", title: "api", status: "Working", machine: "box", needsYou: false, host: "h", address: "t1")

    func state(prompt: B.Prompt? = nil, rows: [B.Row]? = nil) -> B.ContentState {
        B.ContentState(needsYou: prompt == nil ? 0 : 1, working: 1, done: 0, rows: rows ?? [row], prompt: prompt)
    }
    func prompt(_ q: String, _ options: [B.Option]) -> B.Prompt {
        B.Prompt(host: "h", address: "t1", title: "api", question: q, options: options)
    }
    let yes = B.Option(number: 0, label: "Yes", key: "y")
    let no = B.Option(number: 0, label: "No", key: "n")

    @Test func statusWithoutPrompt() {
        #expect(SmallActivityLayout.make(state()) == .status(name: "api", line: "Working"))
        #expect(SmallActivityLayout.make(state(rows: [])) == .status(name: "Agents", line: "1 working"))
    }

    @Test func yesNoPromptGetsButtons() {
        let p = prompt("Run ls?", [yes, no])
        #expect(SmallActivityLayout.make(state(prompt: p)) == .answer(prompt: p, yes: yes, no: no))
    }

    @Test func numberedChoicesMapToYesAndNo() {
        let opts = [B.Option(number: 1, label: "Yes", key: ""), B.Option(number: 2, label: "Yes, and don't ask again", key: ""),
                    B.Option(number: 3, label: "No", key: "")]
        guard case .answer(_, let y, let n) = SmallActivityLayout.make(state(prompt: prompt("Edit?", opts))) else {
            Issue.record("expected answer"); return
        }
        #expect(y == opts[0])
        #expect(n == opts[2])
    }

    @Test func dangerousCommandGetsNoButtons() {
        let layout = SmallActivityLayout.make(state(prompt: prompt("Run rm -rf build?", [yes, no])))
        #expect(layout == .openOnPhone(name: "api", question: "Run rm -rf build?"))
    }

    @Test func noYesNoOptionsOpensOnPhone() {
        let opts = [B.Option(number: 1, label: "Postgres", key: ""), B.Option(number: 2, label: "SQLite", key: "")]
        #expect(SmallActivityLayout.make(state(prompt: prompt("Which db?", opts))) == .openOnPhone(name: "api", question: "Which db?"))
    }
}
