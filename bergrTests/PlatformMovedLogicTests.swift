import Foundation
import Testing
@testable import bergr

/// Logic that moved out of iOS-only files so the Mac app can share it.
struct PlatformMovedLogicTests {
    @Test func terminalFontKeysAndNames() {
        #expect(TerminalFont.storageKey == "terminal.font")
        #expect(TerminalFont.sizeKey == "terminal.fontSize")
        #expect(TerminalFont.allCases.count == 4)
        #expect(TerminalFont.jetBrainsMono.title == "JetBrains Mono")
        #expect(TerminalFont.comicMono.names == ["ComicMono", "ComicMono-Bold", nil, nil])
        #expect(TerminalFont.sfMono.names.allSatisfy { $0 == nil })
    }

    @Test func agentLinkParsesTheDeepLink() throws {
        let host = UUID()
        let url = try #require(URL(string: "bergr://terminal?host=\(host.uuidString)&address=t7"))
        let target = try #require(AgentLink.target(of: url))
        #expect(target.host == host)
        #expect(target.address == "t7")
    }

    @Test func agentLinkRefusesOtherLinks() {
        #expect(AgentLink.target(of: URL(string: "https://example.com")!) == nil)
        #expect(AgentLink.target(of: URL(string: "bergr://settings")!) == nil)
        #expect(AgentLink.target(of: URL(string: "bergr://terminal?host=nope&address=t1")!) == nil)
        #expect(AgentLink.target(of: URL(string: "bergr://terminal?host=\(UUID().uuidString)&address=")!) == nil)
    }

    @Test func settingsKeysKeepTheirValues() {
        #expect(LiveActivityKeys.push == "bergr.liveActivity.push")
        #expect(LiveActivityKeys.content == "bergr.liveActivity.content")
        #expect(LiveActivityKeys.history == "bergr.liveActivity.history")
        #expect(KeepAliveKey.value == "bergr.keepConnectedInBackground")
    }
}
