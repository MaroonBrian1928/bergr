import Network
import Foundation
import HerdrKit
import NIOCore
import Testing
@testable import bergr

@MainActor
struct ConnectionErrorTests {
    let host = Host(name: "laptop", target: SSHTarget(host: "192.168.1.30", username: "me"))

    @Test func localNetworkBlocked() {
        // What iOS gives an app without Local Network permission: EPERM.
        let message = HostSession.describe(IOError(errnoCode: 1, reason: "connect"), host: host)
        #expect(message.contains("Local Network"))
    }

    @Test func refused() {
        let message = HostSession.describe(IOError(errnoCode: 61, reason: "connect"), host: host)
        #expect(message.contains("Nothing accepted SSH at 192.168.1.30:22"))
    }

    @Test func unreachable() {
        let message = HostSession.describe(IOError(errnoCode: 65, reason: "connect"), host: host)
        #expect(message.contains("Can't reach laptop"))
    }

    @Test func keyNotAccepted() {
        let message = HostSession.describe(SSHTransportError.authenticationFailed(username: "me"), host: host)
        #expect(message.contains("didn't accept your key for me"))
        #expect(message.contains("authorized_keys"))
    }

    @Test func channelTimeoutHasAnActionableMessage() {
        let message = HostSession.describe(ChannelError.connectTimeout(.seconds(10)), host: host)
        #expect(message.contains("SSH timed out"))
        #expect(!message.contains("error 0"))
        #expect(HostSession.describe(ChannelError.ioOnClosedChannel, host: host).contains("connection to laptop closed"))
    }

    @Test func faceIDCanceled() {
        let error = NSError(domain: "com.apple.LocalAuthentication", code: -2)
        #expect(HostSession.describe(error, host: host).contains("canceled"))
    }

    @Test func networkFrameworkErrors() {
        let host = Host(name: "pop", target: SSHTarget(host: "192.168.1.20", username: "me"))
        #expect(HostSession.describe(NWError.posix(.ECONNREFUSED), host: host).hasPrefix("Nothing accepted SSH"))
        #expect(HostSession.describe(NWError.posix(.ETIMEDOUT), host: host).hasPrefix("Timed out reaching pop"))
        #expect(HostSession.describe(NWError.posix(.EHOSTUNREACH), host: host).hasPrefix("Can't reach pop"))
        #expect(HostSession.describe(NWError.dns(-65554), host: host).hasPrefix("Couldn't look up 192.168.1.20"))
    }
}
