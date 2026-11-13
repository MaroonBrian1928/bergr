import Foundation

/// How "finished" / "needs you" pushes group on the Lock Screen: one stack per machine, collapsing to
/// "3 more from <machine>". Pure, so the notification extension and tests share it.
nonisolated enum PushGrouping {
    /// Shown by iOS under a stack: "%u more from %@" (count, then the summary argument).
    static let summaryFormat = "%u more from %@"

    struct Result: Equatable {
        var thread: String
        var summaryArgument: String
    }

    /// The thread and summary argument for a push, from its userInfo (`host` is the machine's id)
    /// and the machine names the app saved. Nil without a host: the push keeps its own grouping.
    static func result(userInfo: [AnyHashable: Any], machines: [String: String]) -> Result? {
        guard let host = userInfo["host"] as? String, !host.isEmpty else { return nil }
        let name = machines[host]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(thread: host, summaryArgument: name.isEmpty ? "your machines" : name)
    }
}
