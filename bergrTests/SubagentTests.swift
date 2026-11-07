import Foundation
import Testing
@testable import bergr

@MainActor
struct SubagentTests {
    private func event(_ id: String, parent: String? = "t1", state: String = "running", steps: Int = 1,
                       summary: String = "Reading") -> [String: Any] {
        var e: [String: Any] = ["t": "subagent", "id": id, "name": "Audit \(id)", "kind": "Explore",
                                "state": state, "steps": steps, "summary": summary]
        e["parent"] = parent ?? NSNull()
        return e
    }

    @Test func upsertsByIdAndKeepsOrder() {
        let feed = ChatFeed()
        feed.applySubagent(event("a"))
        feed.applySubagent(event("b", parent: "t2"))
        feed.applySubagent(event("a", state: "done", steps: 4, summary: "Finished"))
        #expect(feed.subagents.map(\.id) == ["a", "b"])
        #expect(feed.subagents[0].state == .done)
        #expect(feed.subagents[0].steps == 4)
        #expect(feed.subagents[0].summary == "Finished")
        #expect(feed.subagents[1].parent == "t2")
        #expect(feed.runningSubagents == 1)
    }

    @Test func neverEntersTheConversation() {
        let feed = ChatFeed()
        feed.applyDemo(event("a"))
        #expect(feed.items.isEmpty)
        #expect(feed.subagents.count == 1)
    }

    @Test func nullParentIsUnanchored() {
        let feed = ChatFeed()
        feed.applySubagent(event("a", parent: nil))
        #expect(feed.subagents[0].parent == nil)
    }

    @Test func foldTitle() {
        let feed = ChatFeed()
        feed.applySubagent(event("a"))
        feed.applySubagent(event("b"))
        feed.applySubagent(event("c", state: "done"))
        #expect(SubagentGroup.title(feed.subagents) == "3 sub-agents (2 running)")
        feed.applySubagent(event("a", state: "done"))
        feed.applySubagent(event("b", state: "failed"))
        #expect(SubagentGroup.title(feed.subagents) == "3 sub-agents")
    }
}
