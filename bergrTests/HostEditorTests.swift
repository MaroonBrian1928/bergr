import Testing
@testable import bergr

struct HostEditorTests {
    @Test func userAtHost() {
        #expect(parseAddress("me@server.example.com") == ParsedAddress(user: "me", host: "server.example.com", port: nil))
    }
    @Test func userAtHostPort() {
        #expect(parseAddress("me@server:2222") == ParsedAddress(user: "me", host: "server", port: 2222))
    }
    @Test func plainHost() {
        #expect(parseAddress("server") == ParsedAddress(user: nil, host: "server", port: nil))
    }
    @Test func ipv4() {
        #expect(parseAddress("me@192.168.1.20:22") == ParsedAddress(user: "me", host: "192.168.1.20", port: 22))
    }
    @Test func badPort() {
        #expect(parseAddress("me@h:abc").badPort)
        #expect(parseAddress("me@h:70000").badPort)
        #expect(parseAddress("me@h:0").badPort)
        #expect(parseAddress("me@h:99").badPort == false)
    }
    @Test func whitespace() {
        #expect(parseAddress("  me@host:2200 \n") == ParsedAddress(user: "me", host: "host", port: 2200))
    }
    @Test func ipv6() {
        #expect(parseAddress("me@[::1]:2222") == ParsedAddress(user: "me", host: "::1", port: 2222))
    }
    @Test func command() {
        #expect(authorizeCommand(for: "ssh-ed25519 AAA me") == "echo 'ssh-ed25519 AAA me' >> ~/.ssh/authorized_keys")
        #expect(authorizeCommand(for: "k it's").contains("'\\''"))
    }
}
