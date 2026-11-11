import Foundation
import Testing
@testable import bergr

@MainActor
struct ReplyDraftsTests {
    private let d = UserDefaults(suiteName: "ReplyDraftsTests-\(UUID().uuidString)")!

    @Test func eachAgentKeepsItsOwn() {
        ReplyDrafts.set("half a thought", for: "m|a", in: d)
        ReplyDrafts.set("other", for: "m|b", in: d)
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "half a thought")
        #expect(ReplyDrafts.text(for: "m|b", in: d) == "other")
    }

    @Test func emptyingRemovesIt() {
        ReplyDrafts.set("x", for: "m|a", in: d)
        ReplyDrafts.set("", for: "m|a", in: d)
        #expect((d.dictionary(forKey: ReplyDrafts.key) ?? [:]).isEmpty)
    }

    @Test func noAgentKeepsNothing() {
        ReplyDrafts.set("x", for: nil, in: d)
        #expect(ReplyDrafts.text(for: nil, in: d) == "")
    }
}
