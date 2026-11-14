import Foundation
import NIOCore
import NIOPosix

/// A port on this device (127.0.0.1) that reaches a port on the remote machine. Close it when done.
public final class PortForward: @unchecked Sendable {
    public let localPort: Int
    private let lock = NSLock()
    private var onClose: (@Sendable () -> Void)?

    init(localPort: Int, onClose: @escaping @Sendable () -> Void) {
        self.localPort = localPort
        self.onClose = onClose
    }

    public var isClosed: Bool { lock.withLock { onClose == nil } }

    public func close() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onClose = nil }
            return onClose
        }
        action?()
    }

    deinit { onClose?() }
}

/// Listens on 127.0.0.1 and joins each accepted connection to a channel `connect` opens (an SSH
/// `direct-tcpip` channel in the app). `connect` must return a channel that reads and writes
/// `ByteBuffer`s.
enum LocalForwarder {
    static func start(
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        connect: @escaping @Sendable () async throws -> any Channel
    ) async throws -> PortForward {
        let children = ChannelSet()
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { local in
                children.insert(local)
                let handler = ForwardHandler()
                do {
                    try local.pipeline.syncOperations.addHandler(handler)
                } catch {
                    return local.eventLoop.makeFailedFuture(error)
                }
                // The initializer runs on the local channel's loop: bind the handler there.
                let bound = NIOLoopBound(handler, eventLoop: local.eventLoop)
                Task {
                    do {
                        let remote = try await connect()
                        children.insert(remote)
                        try await remote.pipeline.addHandler(ForwardHandler(partner: local)).get()
                        local.eventLoop.execute { bound.value.join(remote, local: local) }
                    } catch {
                        local.close(promise: nil)
                    }
                }
                return local.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = server.localAddress?.port ?? 0
        return PortForward(localPort: port) {
            server.close(promise: nil)
            children.closeAll()
        }
    }
}

/// Channels to close with the forward. Closed ones drop out.
private final class ChannelSet: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var closed = false

    func insert(_ channel: any Channel) {
        let id = ObjectIdentifier(channel)
        let alreadyClosed = lock.withLock {
            if !closed { channels[id] = channel }
            return closed
        }
        if alreadyClosed { channel.close(promise: nil); return }
        channel.closeFuture.whenComplete { [weak self] _ in
            _ = self?.lock.withLock { self?.channels.removeValue(forKey: id) }
        }
    }

    func closeAll() {
        let all = lock.withLock {
            closed = true
            defer { channels.removeAll() }
            return Array(channels.values)
        }
        for channel in all { channel.close(promise: nil) }
    }
}

/// Sends what one side reads to the other, which may run on another event loop. Bytes read
/// before the other side exists wait for it. When either side closes, so does the other.
final class ForwardHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var partner: (any Channel)?
    private var pending: [ByteBuffer] = []

    init(partner: (any Channel)? = nil) { self.partner = partner }

    /// On the local channel's loop, once the remote channel is ready.
    func join(_ remote: any Channel, local: any Channel) {
        guard local.isActive else { remote.close(promise: nil); return }
        partner = remote
        for buffer in pending { remote.write(buffer, promise: nil) }
        pending.removeAll()
        remote.flush()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let partner { partner.writeAndFlush(buffer, promise: nil) } else { pending.append(buffer) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The remote sent EOF: pass it on, so a server that ends its reply with EOF is heard.
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
