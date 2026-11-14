import Foundation
import Testing
import TerminalCore
@testable import bergr

@MainActor struct LocalLinksTests {
    @Test func chatTextLinksLocalAddressesToThePreview() {
        var text = AttributedString("Running at localhost:3000/app and https://example.com")
        LocalLinks.link(&text)
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "http://localhost:3000/app")!])
        #expect(LocalWebAddress(url: links[0])?.port == 3000)
    }
}
