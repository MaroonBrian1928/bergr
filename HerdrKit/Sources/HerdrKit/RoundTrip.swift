/// How long the line takes to answer, smoothed the way TCP does (RFC 6298).
public struct RoundTrip: Sendable, Equatable {
    public private(set) var smoothed: Duration
    public private(set) var variation: Duration

    public init(first sample: Duration) {
        smoothed = sample
        variation = sample / 2
    }

    public mutating func add(_ sample: Duration) {
        let error = smoothed > sample ? smoothed - sample : sample - smoothed
        variation = variation * 3 / 4 + error / 4
        smoothed = smoothed * 7 / 8 + sample / 8
    }

    /// How long to wait for an answer before calling the line dead.
    public var timeout: Duration { smoothed + variation * 4 }
}
