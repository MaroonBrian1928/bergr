import Foundation
import Testing
@testable import bergr

struct ChatEventParserTests {
    private func lines(_ events: [String]) -> Data { Data((events.joined(separator: "\n") + "\n").utf8) }

    private func parseAll(_ chunks: [Data]) -> [ChatEvent] {
        var splitter = ChatLineSplitter()
        return chunks.flatMap { splitter.feed($0) }.compactMap { ChatEvent.parse(line: $0) }
    }

    private let msg = ##"{"t":"msg","id":"a","role":"assistant","text":"# Hi\n\nthere"}"##
    private let tool = #"{"t":"tool","id":"b","name":"Bash","summary":"ls"}"#

    @Test func chunkSplitMidLineMatchesWholeLines() {
        let whole = lines([msg, tool])
        let expected = parseAll([whole])
        for cut in [1, 10, msg.utf8.count, msg.utf8.count + 1, msg.utf8.count + 5] {
            let got = parseAll([whole.prefix(cut), whole.dropFirst(cut)].map { Data($0) })
            #expect(got.map(\.type) == expected.map(\.type))
            #expect(got.map { $0.event["id"] as? String } == ["a", "b"])
            #expect(got.first?.blocks == expected.first?.blocks)
        }
    }

    @Test func byteAtATimeKeepsEverything() {
        let whole = lines([msg, tool])
        let got = parseAll(whole.map { Data([$0]) })
        #expect(got.map { $0.event["id"] as? String } == ["a", "b"])
    }

    @Test func multipleLinesInOneChunkKeepOrder() {
        let events = (0..<5).map { #"{"t":"tool","id":"t\#($0)","name":"x","summary":""}"# }
        let got = parseAll([lines(events)])
        #expect(got.map { $0.event["id"] as? String } == (0..<5).map { "t\($0)" })
    }

    @Test func incompleteTrailingLineWaits() {
        var splitter = ChatLineSplitter()
        #expect(splitter.feed(Data(tool.utf8)).isEmpty)
        #expect(splitter.feed(Data("\n".utf8)).count == 1)
    }

    @Test func imageLineDecodes() {
        let bytes = Data([1, 2, 3, 4])
        let line = #"{"t":"image","id":"i","role":"user","data":"\#(bytes.base64EncodedString())"}"#
        let got = parseAll([lines([line])])
        #expect(got.first?.imageData == bytes)
        #expect(parseAll([lines([#"{"t":"image","id":"i","data":"!!!"}"#])]).isEmpty)
    }

    @Test func garbageLinesAreSkipped() {
        let got = parseAll([lines(["not json", tool])])
        #expect(got.count == 1)
    }

    @MainActor @Test func liveReplyGetsRevealStart() async {
        let feed = ChatFeed()
        feed.loadItems([])
        feed.applyDemo(["t": "msg", "id": "a", "role": "assistant", "text": "one"])
        #expect(feed.revealStart.keys.contains("a"))
    }
}
