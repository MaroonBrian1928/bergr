import Foundation
import Observation

/// How long a keystroke takes to show up as terminal output, and how much output is waiting to be drawn.
///
/// A sample opens on the first key of a burst and closes on the next output. Keys that never get an
/// echo are dropped once the open sample is older than `staleAfter`, so they don't skew the numbers.
nonisolated struct InputLatency: Sendable {
    static let window = 64
    static let staleAfter: Duration = .seconds(5)

    private var openedAt: ContinuousClock.Instant?
    private var pendingBytes = 0

    init() {}

    /// Output-to-keystroke durations, oldest first, at most `window`.
    private(set) var samples: [Duration] = []

    /// A keystroke was sent. Starts a sample only if none is open, or the open one is stale (dropped, not counted).
    mutating func sent(at now: ContinuousClock.Instant) {
        if let openedAt, now - openedAt <= Self.staleAfter { return }
        openedAt = now
    }

    /// Output arrived: closes the open sample, if any.
    mutating func outputArrived(at now: ContinuousClock.Instant) {
        guard let start = openedAt else { return }
        openedAt = nil
        // A reply long after the key (a background job's output, not its echo) isn't a latency.
        guard now - start <= Self.staleAfter else { return }
        samples.append(now - start)
        if samples.count > Self.window {
            samples.removeFirst(samples.count - Self.window)
        }
    }

    var median: Duration? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Nearest-rank 95th percentile.
    var p95: Duration? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = (95 * sorted.count + 99) / 100
        return sorted[max(rank, 1) - 1]
    }

    /// Output bytes received since the last draw.
    private(set) var queuedBytes = 0
    /// The most `queuedBytes` has been at once.
    private(set) var peakQueuedBytes = 0

    mutating func received(bytes: Int) {
        queuedBytes += bytes
        peakQueuedBytes = max(peakQueuedBytes, queuedBytes)
    }

    mutating func rendered() {
        queuedBytes = 0
    }
}

extension Duration {
    /// Milliseconds below one second ("80 ms"), otherwise seconds with one decimal ("1.4 s").
    var latencyText: String {
        let parts = components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        if seconds < 0.9995 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}

/// Latest latency numbers per terminal, for Diagnostics. Logs to `AuthTrail` once when a terminal turns slow.
@MainActor @Observable
final class TerminalStats {
    static let shared = TerminalStats()

    struct Summary: Equatable, Sendable {
        var label: String
        var median: Duration?
        var p95: Duration?
        var samples: Int
        var peakQueuedBytes: Int
    }

    private(set) var terminals: [String: Summary] = [:]
    /// Number of "slow" lines written to `AuthTrail` (readable by tests).
    private(set) var slowLogs = 0
    @ObservationIgnored private var slowKeys: Set<String> = []

    /// `key` is the caller's "<host uuid>|<address>".
    func update(key: String, label: String, latency: InputLatency) {
        terminals[key] = Summary(
            label: label,
            median: latency.median,
            p95: latency.p95,
            samples: latency.samples.count,
            peakQueuedBytes: latency.peakQueuedBytes
        )
        guard let p95 = latency.p95 else { return }
        if slowKeys.contains(key) {
            if p95 < .milliseconds(500) { slowKeys.remove(key) }
        } else if p95 > .seconds(1), latency.samples.count >= 8 {
            slowKeys.insert(key)
            slowLogs += 1
            AuthTrail.note("Terminal: \(label) slow, p95 \(p95.latencyText) over \(latency.samples.count) keys")
        }
    }

    func remove(key: String) {
        terminals[key] = nil
        slowKeys.remove(key)
    }
}
