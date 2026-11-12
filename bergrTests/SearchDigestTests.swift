import Foundation
import HerdrKit
import Testing
@testable import bergr

struct SearchDigestTests {
    func terminal(_ address: String, _ state: String, ms: UInt64, app: String = "claude-code", msg: String? = nil) throws -> Terminal {
        let m = msg.map { ",\"msg\":\"\($0)\"" } ?? ""
        let json = """
        {"address":"\(address)","name":"\(address)","state":"live","turn":1,"labels":{},"created_ms":1,"status_ms":\(ms),
         "status":{"state":"\(state)","app":"\(app)"\(m)}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func digestSelectsAgentsThatChangedSince() throws {
        let since = Date(timeIntervalSince1970: 1000)
        let all = [
            try terminal("t1", "done", ms: 2_000_000),
            try terminal("t2", "done", ms: 500_000),      // before
            try terminal("t3", "working", ms: 3_000_000), // not a digest state
            try terminal("t4", "blocked", ms: 4_000_000),
            try terminal("t5", "error", ms: 1_500_000),
        ]
        let picked = AwayDigest.changed(all, since: since) { $0 }
        #expect(picked.map(\.address) == ["t4", "t1", "t5"])
        #expect(DigestKind(picked[0].agentState) == .needsYou)
    }

    @Test func fallbackUsesLastAssistantSentenceTruncated() {
        let ctx = DigestContext(title: "x", kind: .finished, lines: [
            DigestLine(role: .assistant, text: "Started. Fixed the bug."),
            DigestLine(role: .user, text: "thanks"),
            DigestLine(role: .assistant, text: "First line.\nI updated the parser. Tests pass now."),
            DigestLine(role: .tool, text: "Bash ls"),
        ], statusMessage: "status")
        #expect(AwayDigest.fallbackSummary(ctx) == "Tests pass now.")
        let long = DigestContext(title: "x", kind: .finished, lines: [
            DigestLine(role: .assistant, text: String(repeating: "word ", count: 80))], statusMessage: nil)
        let s = AwayDigest.fallbackSummary(long, limit: 50)
        #expect(s.count <= 50 && s.hasSuffix("…"))
        let none = DigestContext(title: "x", kind: .error, lines: [], statusMessage: "Build failed")
        #expect(AwayDigest.fallbackSummary(none) == "Build failed")
        #expect(AwayDigest.fallbackSummary(DigestContext(title: "x", kind: .error, lines: [], statusMessage: nil)) == "Error")
    }

    struct Fake: DigestSummarizing {
        let answer: String?
        func summarize(_ context: DigestContext) async -> String? { answer }
    }

    @MainActor
    @Test func modelFillsSummariesAndFallsBack() async throws {
        let host = Host(name: "box", target: SSHTarget(host: "box", username: "u"))
        let cands = [AwayDigestModel.Candidate(host: host, machine: "box", terminal: try terminal("t1", "done", ms: 2_000_000, msg: "All good"), lines: nil)]
        let model = AwayDigestModel(summarizer: Fake(answer: nil))
        model.build(since: Date(timeIntervalSince1970: 1), candidates: cands)
        #expect(model.entries.count == 1)
        for _ in 0..<50 where model.entries[0].summary == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.entries[0].summary == "All good")
        let fake = AwayDigestModel(summarizer: Fake(answer: "It shipped."))
        fake.build(since: Date(timeIntervalSince1970: 1), candidates: cands)
        for _ in 0..<50 where fake.entries[0].summary == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fake.entries[0].summary == "It shipped.")
        fake.dismiss()
        #expect(fake.entries.isEmpty)
    }

    @MainActor
    @Test func shortAbsenceShowsNothing() async throws {
        let model = AwayDigestModel(summarizer: Fake(answer: "x"))
        let start = Date(timeIntervalSince1970: 10_000)
        model.appDidLeave(at: start)
        model.appDidReturn(now: start.addingTimeInterval(60), settle: .milliseconds(1)) { [] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.entries.isEmpty)
    }

    @Test func resultsDecode() throws {
        let out = """
        Welcome banner
        {"hits":[{"agent":"claude","role":"user","path":"/h/a.jsonl","session":"s1","cwd":"/w/app","title":"Fix it","snippet":"…flux…","ts":1700000000.5}],"truncated":true}
        """
        let r = try SearchResponse.decode(out)
        #expect(r.truncated)
        #expect(r.hits.count == 1)
        #expect(r.hits[0].folder == "app" && r.hits[0].agentName == "Claude")
        #expect(r.hits[0].date == Date(timeIntervalSince1970: 1700000000.5))
        #expect(throws: TranscriptSearchError.self) { try SearchResponse.decode("python: not found") }
    }

    @Test func commandIsWindowsSafe() throws {
        let win = TranscriptSearch.command(windows: true)
        #expect(!win.contains("$"))
        let line = try String(decoding: TranscriptSearch.input(query: "a \"b\" $c", script: "print(1)"), as: UTF8.self)
        #expect(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1)
        #expect(!line.contains("a \"b\""))
    }
}
