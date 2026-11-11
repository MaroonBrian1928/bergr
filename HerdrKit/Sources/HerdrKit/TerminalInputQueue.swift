import Foundation

/// Serializes a terminal's automated input across all its viewers.
@MainActor
public final class TerminalInputQueue {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {}

    public func run(_ steps: @escaping @MainActor () async -> Void) async {
        let previous = tail
        generation += 1
        let current = generation
        let task = Task { @MainActor in
            await previous?.value
            await steps()
        }
        tail = task
        await task.value
        if generation == current { tail = nil }
    }
}
