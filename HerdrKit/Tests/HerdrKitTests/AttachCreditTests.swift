import Foundation
import Testing
@testable import HerdrKit

@Test(.timeLimit(.minutes(1))) func attachCreditsOnlyAfterConsumption() async throws {
    let core = FakeCore()
    let terminal = #"{"address":"t7","argv":["fish"],"cwd":"/tmp","state":"live","title":"~","labels":{},"cols":80,"rows":24,"created_ms":1}"#
    core.respond = { core, id, method in
        #expect(method == "terminal.attach")
        core.reply(id, #"{"terminal":\#(terminal),"channel":5}"#)
    }
    let client = try await HerdrClient.connect(over: core)
    let attached = try await client.attach(terminal: "t7", cols: 80, rows: 24)

    core.emit(Frame(channel: 5, kind: .data, payload: Data("hello".utf8)).encoded())
    var output = attached.output.makeAsyncIterator()
    let chunk = try #require(try await output.next())
    #expect(chunk.count == 5)

    func credits() -> [Frame] { core.sentFrames.filter { $0.channel == 5 && $0.kind == Frame.Kind.credit.rawValue } }
    try await Task.sleep(for: .milliseconds(100))
    #expect(credits().isEmpty)

    await attached.consumed(bytes: chunk.count)
    #expect(credits() == [.credit(channel: 5, bytes: 5)])
}
