import Testing
@testable import bergr

@MainActor
struct CommandSuggestionsTests {
    private static func command(_ name: String) -> ChatFeed.Command {
        ChatFeed.Command(name: name, description: "")
    }

    private let commands = [
        Self.command("/ponytail:ponytail-review"),
        Self.command("/review-pr"),
        Self.command("/compact"),
        Self.command("/Context"),
        Self.command("/stop"),
        Self.command("$stop-slop"),
        Self.command("$slides"),
    ]

    private func names(_ draft: String, limit: Int = 6) -> [String] {
        CommandMatcher.matches(commands, draft: draft, limit: limit).map(\.name)
    }

    @Test func prefixMatchesComeBeforeContainsMatches() {
        #expect(names("/rev") == ["/review-pr", "/ponytail:ponytail-review"])
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(names("/COM") == ["/compact"])
        #expect(names("/CONT") == ["/Context"])
        #expect(names("/CONTEXT") == [])
    }

    @Test func dollarOnlyMatchesDollarNames() {
        #expect(names("$st") == ["$stop-slop"])
        #expect(names("$") == ["$stop-slop", "$slides"])
        #expect(names("/st") == ["/stop"])
        #expect(names("/slides") == [])
    }

    @Test func draftWithSpaceMatchesNothing() {
        #expect(names("/compact ") == [])
        #expect(names("/comp act") == [])
    }

    @Test func plainTextMatchesNothing() {
        #expect(names("") == [])
        #expect(names("compact") == [])
        #expect(names("hello /comp") == ["/compact"])
        #expect(names("hello/comp") == [])
        #expect(names("hello /compact now") == [])
        #expect(CommandMatcher.picking("/compact", in: "please run /comp") == "please run /compact ")
        #expect(CommandMatcher.picking("/compact", in: "/co") == "/compact ")
    }

    @Test func exactSingleMatchIsEmpty() {
        #expect(names("/compact") == [])
        #expect(names("/Compact") == [])
        #expect(names("/comp") == ["/compact"])
    }

    @Test func limitIsRespected() {
        let many = (1...10).map { Self.command("/a\($0)") }
        #expect(CommandMatcher.matches(many, draft: "/a").count == 6)
        #expect(CommandMatcher.matches(many, draft: "/a", limit: 3).map(\.name) == ["/a1", "/a2", "/a3"])
    }
}
