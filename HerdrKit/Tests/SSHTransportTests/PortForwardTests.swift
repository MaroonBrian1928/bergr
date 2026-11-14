import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SSHTransport

/// Echoes what it reads, upper-cased, so a reply shows it went through the "remote" side.
private final class UpperEcho: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let text = String(buffer: unwrapInboundIn(data)).uppercased()
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: text)), promise: nil)
    }
}

/// Collects what a client reads.
private final class Collector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var text = ""
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let piece = String(buffer: unwrapInboundIn(data))
        lock.withLock { text += piece }
    }
    var received: String { lock.withLock { text } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

@Test func portForwardPipesBytesBothWaysAndCloses() async throws {
    let group = MultiThreadedEventLoopGroup.singleton
    let echo = try await ServerBootstrap(group: group)
        .childChannelInitializer { $0.pipeline.addHandler(UpperEcho()) }
        .bind(host: "127.0.0.1", port: 0).get()
    defer { echo.close(promise: nil) }
    let echoPort = echo.localAddress!.port!

    let opened = Counter()
    let forward = try await LocalForwarder.start {
        opened.increment()
        return try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: echoPort).get()
    }

    let collector = Collector()
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { $0.pipeline.addHandler(collector) }
        .connect(host: "127.0.0.1", port: forward.localPort).get()
    // Sent at once: bytes that arrive before the remote side is open wait for it.
    try await client.writeAndFlush(ByteBuffer(string: "hello")).get()
    try await waitFor { collector.received == "HELLO" }
    #expect(collector.received == "HELLO")
    #expect(opened.value == 1)

    forward.close()
    try await waitFor { !client.isActive }
    #expect(!client.isActive)
    await #expect(throws: (any Error).self) {
        try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: forward.localPort).get()
    }
}

@Test func portForwardClosesTheLocalConnectionWhenTheRemoteRefuses() async throws {
    let group = MultiThreadedEventLoopGroup.singleton
    let forward = try await LocalForwarder.start { throw ChannelError.connectTimeout(.seconds(1)) }
    defer { forward.close() }
    let client = try await ClientBootstrap(group: group)
        .connect(host: "127.0.0.1", port: forward.localPort).get()
    try await waitFor { !client.isActive }
    #expect(!client.isActive)
}
