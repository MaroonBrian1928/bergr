import Foundation
@testable import bergr

/// Tests that change the "hide quiet agents" setting run one at a time: it's one global value,
/// and Swift Testing runs suites in parallel (two tests writing it made each other fail).
enum QuietAgentsSetting {
    private static let lock = NSLock()

    static func with<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let saved = UserDefaults.standard.object(forKey: QuietAgents.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: QuietAgents.key) }
            else { UserDefaults.standard.removeObject(forKey: QuietAgents.key) }
        }
        return try body()
    }
}
