import Testing
@testable import HerdrKit

struct LocalMachineTests {
    @Test func loopbackAndOwnNames() {
        for name in ["localhost", "LOCALHOST.", "127.0.0.1", "::1", "[::1]", "studio", "Studio.local", " studio.local. "] {
            #expect(LocalMachine.matches(name, names: ["studio.local"]))
        }
        #expect(LocalMachine.matches("studio.local", names: ["studio"]))
    }

    @Test func remoteNamesStayRemote() {
        for name in ["", "other.local", "studio.example.com", "studio.local.evil", "localhost.evil", "127.0.0.2", "192.168.1.2", "-studio"] {
            #expect(!LocalMachine.matches(name, names: ["studio.local", ""]))
        }
    }
}
