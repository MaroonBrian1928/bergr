import Foundation

/// Tracks keystrokes sent over a terminal channel that herdr never acknowledges.
///
/// A keystroke is confirmed once its write returned without error and terminal output arrived
/// after it was sent. When a channel ends, unconfirmed keystrokes become ambiguous: they may or
/// may not have reached the host, so the user decides whether to resend or discard them. Nothing
/// here resends on its own.
nonisolated struct InputJournal: Sendable {
    struct Entry: Equatable, Sendable {
        let seq: Int
        let data: Data
        let sentAt: ContinuousClock.Instant
        var written: Bool
    }

    /// Oldest entries are dropped beyond this count, in both `pending` and `ambiguous`.
    static let maxEntries = 256

    /// Sent, not yet confirmed.
    private(set) var pending: [Entry] = []
    /// Left unconfirmed when a channel ended, or whose write failed.
    private(set) var ambiguous: [Entry] = []

    private var nextSeq = 1
    /// When output last arrived: an echo can come back before the write call itself returns.
    private var lastOutputAt: ContinuousClock.Instant?

    init() {}

    /// A user keystroke/paste about to be written. Returns its sequence number.
    mutating func sent(_ data: Data, at: ContinuousClock.Instant) -> Int {
        let seq = nextSeq
        nextSeq += 1
        pending.append(Entry(seq: seq, data: data, sentAt: at, written: false))
        if pending.count > Self.maxEntries {
            pending.removeFirst(pending.count - Self.maxEntries)
        }
        return seq
    }

    /// Its write returned without error.
    mutating func written(_ seq: Int) {
        guard let index = pending.firstIndex(where: { $0.seq == seq }) else { return }
        // Output already came after it was sent (its echo beat the write's return): confirmed.
        if let output = lastOutputAt, output > pending[index].sentAt {
            pending.remove(at: index)
            return
        }
        pending[index].written = true
    }

    /// Its write threw: it certainly didn't arrive; it moves to `ambiguous` too (the user decides).
    mutating func failed(_ seq: Int) {
        guard let index = pending.firstIndex(where: { $0.seq == seq }) else { return }
        appendAmbiguous([pending.remove(at: index)])
    }

    /// Output arrived: confirms (removes) every pending entry that is `written` and was sent before `at`.
    mutating func outputArrived(at: ContinuousClock.Instant) {
        lastOutputAt = at
        pending.removeAll { $0.written && $0.sentAt < at }
    }

    /// The channel ended: every pending entry moves to `ambiguous` (appended, order kept).
    mutating func channelEnded() {
        let moved = pending
        pending = []
        appendAmbiguous(moved)
    }

    /// The ambiguous bytes concatenated in order, and clears `ambiguous` (the caller sends them).
    mutating func takeAmbiguous() -> Data {
        let bytes = ambiguousBytes
        ambiguous = []
        return bytes
    }

    mutating func discardAmbiguous() {
        ambiguous = []
    }

    /// How many keystrokes the banner should mention: count of ambiguous entries.
    var ambiguousCount: Int { ambiguous.count }

    /// A short printable preview of the ambiguous input for the banner.
    var ambiguousPreview: String {
        Self.preview(of: ambiguousBytes)
    }

    // MARK: - Private

    private var ambiguousBytes: Data {
        ambiguous.reduce(into: Data()) { $0.append($1.data) }
    }

    /// The person intentionally left (navigated away, switched to watching): nothing to ask about.
    mutating func forgetPending() {
        pending = []
    }

    private mutating func appendAmbiguous(_ entries: [Entry]) {
        ambiguous.append(contentsOf: entries)
        // Kept in typing order, whichever way each one became ambiguous: a resend replays it as typed.
        ambiguous.sort { $0.seq < $1.seq }
        if ambiguous.count > Self.maxEntries {
            ambiguous.removeFirst(ambiguous.count - Self.maxEntries)
        }
    }

    private static let previewLimit = 40

    /// Control bytes are shown as symbols, CSI/SS3 escape sequences collapse to a single ⎋,
    /// and output stops once it is clearly longer than the limit.
    private static func preview(of data: Data) -> String {
        let bytes = [UInt8](data)
        var out = ""
        var i = 0
        while i < bytes.count && out.count <= previewLimit {
            let c = bytes[i]
            switch c {
            case 0x0d, 0x0a:
                out += "⏎"
                i += 1
            case 0x7f:
                out += "⌫"
                i += 1
            case 0x1b:
                out += "⎋"
                i += 1
                if i < bytes.count, bytes[i] == 0x5b || bytes[i] == 0x4f {
                    // CSI ("[") or SS3 ("O"): skip parameters, intermediates and the final byte.
                    i += 1
                    while i < bytes.count, (0x20...0x3f).contains(bytes[i]) { i += 1 }
                    if i < bytes.count, (0x40...0x7e).contains(bytes[i]) { i += 1 }
                }
            case 0x00..<0x20:
                out += "^" + String(Character(Unicode.Scalar(c + 0x40)))
                i += 1
            case 0x20..<0x7f:
                out += String(Character(Unicode.Scalar(c)))
                i += 1
            default:
                // UTF-8 lead byte: take its continuation bytes so multi-byte characters stay whole.
                let need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1
                var end = i + 1
                while end < bytes.count, end - i < need, (0x80...0xBF).contains(bytes[end]) {
                    end += 1
                }
                out += String(decoding: bytes[i..<end], as: UTF8.self)
                i = end
            }
        }
        if out.count > previewLimit {
            return String(out.prefix(previewLimit - 1)) + "…"
        }
        return out
    }
}
