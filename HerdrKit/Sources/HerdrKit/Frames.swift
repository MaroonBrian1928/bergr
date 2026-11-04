import Foundation

/// herdr-core framed mode: `[channel u32 LE][kind u8][len u32 LE][payload]`.
/// Channel 0 carries JSON-RPC, one message per DATA frame; other channels are streams.
public struct Frame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// Channel 0: one JSON-RPC message. Other channels: stream bytes.
        case data = 0
        /// u32 LE: bytes the receiver consumed; the sender may send that much more.
        case credit = 1
        /// The channel is over (a JSON reason from the core, empty from us).
        case close = 2
        /// Viewer → core: u16 LE cols, u16 LE rows.
        case resize = 3
        /// Viewer → core: 1 gained focus, 0 lost it.
        case focus = 4
        /// Viewer → core: JSON display facts.
        case facts = 5
        /// Viewer → core: bytes the viewer's emulator generated (query answers, mode 2048 size
        /// reports), not a person typing. Only once `terminal.attach` confirmed `automatic_input`.
        case automaticInput = 6
    }

    public static let headerSize = 9
    public static let maxPayload = 16 << 20

    public var channel: UInt32
    /// Raw kind byte; unknown kinds are kept so they can be skipped.
    public var kind: UInt8
    public var payload: Data

    public init(channel: UInt32, kind: Kind, payload: Data = Data()) {
        self.channel = channel
        self.kind = kind.rawValue
        self.payload = payload
    }

    init(channel: UInt32, rawKind: UInt8, payload: Data) {
        self.channel = channel
        self.kind = rawKind
        self.payload = payload
    }

    public static func credit(channel: UInt32, bytes: Int) -> Frame {
        Frame(channel: channel, kind: .credit, payload: le(UInt32(clamping: bytes)))
    }

    public static func resize(channel: UInt32, cols: UInt16, rows: UInt16) -> Frame {
        Frame(channel: channel, kind: .resize, payload: le(cols) + le(rows))
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(Self.le(channel))
        out.append(kind)
        out.append(Self.le(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

public enum FrameError: Error {
    case tooLarge(Int)
}

/// Splits a byte stream into lines while in plain mode and into frames after the switch.
struct FrameReader {
    private var buffer = Data()
    private var position = 0

    mutating func append(_ data: Data) {
        // Drop what was consumed before growing, so the buffer stays small.
        if position > 0 && position == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            position = 0
        } else if position > 64 * 1024 {
            buffer = Data(buffer[(buffer.startIndex + position)...])
            position = 0
        }
        buffer.append(data)
    }

    /// The next newline-terminated line, without the newline.
    mutating func nextLine() -> Data? {
        let start = buffer.startIndex + position
        guard let newline = buffer[start...].firstIndex(of: 0x0A) else { return nil }
        position = newline - buffer.startIndex + 1
        return Data(buffer[start..<newline])
    }

    mutating func nextFrame() throws -> Frame? {
        let start = buffer.startIndex + position
        guard buffer.count - position >= Frame.headerSize else { return nil }
        let channel = readLE(UInt32.self, at: start)
        let kind = buffer[start + 4]
        let length = Int(readLE(UInt32.self, at: start + 5))
        guard length <= Frame.maxPayload else { throw FrameError.tooLarge(length) }
        guard buffer.count - position >= Frame.headerSize + length else { return nil }
        let payloadStart = start + Frame.headerSize
        let payload = Data(buffer[payloadStart..<(payloadStart + length)])
        position += Frame.headerSize + length
        return Frame(channel: channel, rawKind: kind, payload: payload)
    }

    private func readLE<T: FixedWidthInteger>(_: T.Type, at index: Int) -> T {
        var value: T = 0
        for offset in 0..<MemoryLayout<T>.size {
            value |= T(buffer[index + offset]) << (8 * offset)
        }
        return value
    }
}

/// Splits stream bytes into newline-terminated lines (event channels carry JSON lines).
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[(newline + 1)...])
        }
        return lines
    }
}
