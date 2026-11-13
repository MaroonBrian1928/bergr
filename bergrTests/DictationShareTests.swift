import Foundation
import Testing
@testable import bergr

struct DictationShareTests {
    // MARK: Dictation text

    @Test func partialsReplaceEachOtherInsteadOfStacking() {
        let base = DictationText.prepared(base: "Fix")
        #expect(base == "Fix ")
        #expect(DictationText.merged(base: base, partial: "the") == "Fix the")
        #expect(DictationText.merged(base: base, partial: "the login bug") == "Fix the login bug")
    }

    @Test func emptyDraftAndEmptyPartial() {
        #expect(DictationText.prepared(base: "") == "")
        #expect(DictationText.merged(base: "", partial: "hello") == "hello")
        #expect(DictationText.merged(base: "Note: ", partial: "  ") == "Note: ")
        #expect(DictationText.prepared(base: "line\n") == "line\n")
    }

    // MARK: Markdown export

    private func item(_ id: String, _ kind: ChatFeed.Kind) -> ChatFeed.Item { .init(id: id, kind: kind) }

    @Test func emptyChatIsEmpty() {
        #expect(TranscriptExport.markdown(items: [], agent: "Claude") == "")
    }

    @Test func rolesCodeBlocksAndToolSteps() {
        let reply = "Done:\n\n```swift\nlet x = 1\n```"
        let items = [
            item("1", .user("Add x")),
            item("2", .tool(name: "Read", summary: "a.swift")),
            item("3", .tool(name: "Edit", summary: "a.swift\nsecond line")),
            item("4", .assistant(text: reply, blocks: [])),
            item("5", .plan([])),
        ]
        let md = TranscriptExport.markdown(items: items, agent: "Claude")
        #expect(md == "## You\n\nAdd x\n\n- Read: a.swift\n- Edit: a.swift\n\n## Claude\n\n" + reply + "\n")
    }
}
