import Foundation
import Testing
@testable import TerminalCore

@Test(arguments: [
    ("http://localhost:3000", 3000, ""),
    ("http://localhost:3000/", 3000, "/"),
    ("http://127.0.0.1:8080/app?x=1#top", 8080, "/app?x=1#top"),
    ("http://0.0.0.0:5173/", 5173, "/"),
    ("http://[::1]:4000/a", 4000, "/a"),
    ("HTTP://LOCALHOST:3000/Path", 3000, "/Path"),
    ("http://localhost/", 80, "/"),
    ("https://localhost/", 443, "/"),
])
func localAddressesAreRecognized(url: String, port: Int, path: String) throws {
    let address = try #require(LocalWebAddress(url: URL(string: url)!))
    #expect(address.port == port)
    #expect(address.path == path)
    #expect(address.forwarded(to: 61000).absoluteString == "\(address.scheme)://127.0.0.1:61000\(path)")
}

@Test(arguments: [
    "https://example.com:3000/", "http://localhost.example.com:3000", "ssh://localhost:22",
    "file:///tmp/x", "http://192.168.1.5:3000", "bergr-file://open?path=a",
])
func otherURLsAreLeftAlone(url: String) {
    #expect(LocalWebAddress(url: URL(string: url)!) == nil)
}

@Test func localAddressDisplayKeepsPathAndShowsLocalhost() throws {
    let address = try #require(LocalWebAddress(url: URL(string: "http://0.0.0.0:3000/users/1")!))
    #expect(address.display == "localhost:3000/users/1")
    #expect(LocalWebAddress(url: URL(string: "http://127.0.0.1:3000/")!)?.display == "localhost:3000")
}

@Test func localAddressesInPlainTextWithAndWithoutScheme() {
    let text = "The page works at localhost:3000. Also see (http://127.0.0.1:8000/docs), "
        + "not user@localhost:22 or app.localhost:3000 or https://example.com."
    let found = LocalWebAddress.matches(in: text)
    #expect(found.map { String(text[$0.range]) } == ["localhost:3000", "http://127.0.0.1:8000/docs"])
    #expect(found.map(\.address.port) == [3000, 8000])
    #expect(LocalWebAddress.matches(in: "localhost without a port").isEmpty)
}
