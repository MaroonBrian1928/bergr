import Foundation

/// Races work against a time limit and returns at the limit even if the work never answers (a
/// task group would wait for it): a request on a quietly dead line hangs forever.
enum Deadline {
    /// Whether `work` finished without throwing within `limit`.
    static func answers(within limit: Duration, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        let gate = Gate()
        return await withCheckedContinuation { continuation in
            let task = Task {
                let ok = (try? await work()) != nil
                gate.finish(continuation, ok)
            }
            Task {
                try? await Task.sleep(for: limit)
                if gate.finish(continuation, false) { task.cancel() }
            }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        @discardableResult
        func finish(_ continuation: CheckedContinuation<Bool, Never>, _ value: Bool) -> Bool {
            let first = lock.withLock { () -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { continuation.resume(returning: value) }
            return first
        }
    }
}
