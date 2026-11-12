import CryptoKit
import Foundation
import KeyStore
import Testing
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import SSHTransport

#if canImport(Network)
@Test func windowsDetectionUsesTheServerGreetingWithoutAnExec() {
    let windows = SSHServerIdentification()
    windows.receive(ByteBuffer(string: "Welcome\r\nSSH-2.0-OpenSSH_for_"))
    #expect(!windows.isWindows)
    windows.receive(ByteBuffer(string: "Windows_9.5\r\n"))
    #expect(windows.isWindows)
    let unix = SSHServerIdentification()
    unix.receive(ByteBuffer(string: "SSH-2.0-OpenSSH_9.9\r\n"))
    #expect(!unix.isWindows)
}

@Test func bufferedServerGreetingIsReplayedWithoutAnotherRead() throws {
    let channel = EmbeddedChannel(handler: HoldUntilSSH())
    defer { _ = try? channel.finish() }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
    // The server speaks before Citadel installs the SSH handler, then waits for our reply.
    try channel.writeInbound(ByteBuffer(string: "SSH-2.0-OpenSSH_for_Windows_9.5\r\n"))
    let key = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
    let validator = TOFUHostKeyValidator(host: "test", store: InMemoryKnownHosts(), onUnknownHost: { _ in false })
    let config = SSHClientConfiguration(
        userAuthDelegate: PublicKeyAuthentication(username: "me", key: key), serverAuthDelegate: validator)
    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
        role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil))
    channel.embeddedEventLoop.run()
    // Client greeting plus a binary KEXINIT: proof the buffered server greeting was consumed.
    let greeting = try #require(try channel.readOutbound(as: ByteBuffer.self))
    #expect(String(buffer: greeting).hasPrefix("SSH-2.0-"))
    #expect(try channel.readOutbound(as: ByteBuffer.self) != nil)
}
#endif

@Test func authorizedKeysLineParsesInNIOSSH() {
    let key = P256.Signing.PrivateKey().publicKey
    let line = OpenSSH.authorizedKeysLine(key, comment: "phone")
    let parts = line.split(separator: " ")
    #expect(normalizedOpenSSHPublicKey(line) == "\(parts[0]) \(parts[1])")
}

@Test func knownHostsNames() {
    #expect(SSHTarget(host: "box", username: "me").knownHostsName == "box")
    #expect(SSHTarget(host: "box", port: 2222, username: "me").knownHostsName == "[box]:2222")
}

@Test func inMemoryKnownHosts() {
    let hosts = InMemoryKnownHosts()
    #expect(hosts.hostKey(for: "box") == nil)
    hosts.setHostKey("ssh-ed25519 AAAA", for: "box")
    #expect(hosts.hostKey(for: "box") == "ssh-ed25519 AAAA")
    hosts.removeHostKey(for: "box")
    #expect(hosts.hostKey(for: "box") == nil)
}
