import Foundation
import HerdrKit

/// What a one-shot read of an agent's transcript found.
enum UsageProbeOutcome: Equatable {
    case usage(ChatFeed.Usage)
    /// The helper ran but the agent has no conversation or no usage numbers yet.
    case empty
    case failed
}

/// One agent terminal to read: what the chat helper needs to find its transcript.
struct UsageTarget: Identifiable {
    /// The same id as `UsageReading.id`: "<host id>/<terminal address>".
    let id: String
    let agent: ChatAgent
    let pid: Int32
    let cwd: String
    let sessionHint: String?
    /// The agent is mid-turn: only those are worth polling for the plan-limit alert.
    let working: Bool
    let session: HostSession?
}

enum UsageProbeError: Error { case noAnswer, helperMissing, unreachable }

/// Reads the latest usage of agents whose chat isn't open, with the helper's one-shot mode
/// (`agent-feed.py … once`, launched the same two-stage way as the chat itself), and remembers it.
/// The Usage screen and the 80% alerts both read from here.
@MainActor @Observable
final class UsageProbe {
    typealias Runner = @MainActor (UsageTarget) async throws -> ChatFeed.Usage?

    static let shared = UsageProbe()
    /// The alert poll's rhythm per agent.
    static let pollInterval: TimeInterval = 5 * 60
    /// The Usage screen re-reads on opening, but not when it was read this recently.
    static let screenAge: TimeInterval = 30

    private(set) var outcomes: [String: UsageProbeOutcome] = [:]
    @ObservationIgnored private var lastRead: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private let clock: () -> Date

    init(runner: @escaping Runner = UsageProbe.sshRunner, clock: @escaping () -> Date = { .now }) {
        self.runner = runner
        self.clock = clock
    }

    /// Reads the targets that are due: not read within `minAge` seconds and not being read now
    /// (and, with `onlyWorking`, mid-turn). Returns when all of them answered or failed.
    func refresh(_ targets: [UsageTarget], minAge: TimeInterval, onlyWorking: Bool = false) async {
        let now = clock()
        let due = targets.filter { target in
            guard !onlyWorking || target.working, !inFlight.contains(target.id) else { return false }
            guard let last = lastRead[target.id] else { return true }
            return now.timeIntervalSince(last) >= minAge
        }
        for target in due {
            lastRead[target.id] = now
            inFlight.insert(target.id)
        }
        await withTaskGroup(of: (String, UsageProbeOutcome).self) { group in
            for target in due {
                group.addTask { @MainActor in
                    do {
                        let usage = try await self.runner(target)
                        return (target.id, usage.map(UsageProbeOutcome.usage) ?? .empty)
                    } catch {
                        return (target.id, .failed)
                    }
                }
            }
            for await (id, outcome) in group {
                inFlight.remove(id)
                if outcomes[id] != outcome { outcomes[id] = outcome }
            }
        }
    }

    // MARK: Launch and parsing

    private static let script: String? = Bundle.main.url(forResource: "agent-feed", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The command and its stdin: stage 2's line, then the helper's source for a machine that has
    /// not cached it (the helper asks for it only then, so the extra line is otherwise unread).
    static func launch(script: String, target: UsageTarget, windows: Bool) throws -> (command: String, input: Data) {
        let plan = try ChatHelperLaunch.make(script: script, agent: target.agent.rawValue, pid: target.pid,
                                             cwd: target.cwd, sessionHint: target.sessionHint,
                                             windows: windows, once: true)
        return (plan.command, plan.input + plan.sourceLine)
    }

    /// The helper's answer: its last `usage` or `none` line (a login banner or the `need-source`
    /// request may come first). Nil means the agent has nothing yet; no such line throws.
    static func parse(_ output: String) throws -> ChatFeed.Usage? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let kind = event["t"] as? String else { continue }
            if kind == "none" { return nil }
            if let usage = ChatFeed.Usage(event: event) { return usage }
        }
        throw UsageProbeError.noAnswer
    }

    static let sshRunner: Runner = { target in
        guard let session = target.session else { throw UsageProbeError.unreachable }
        // The demo machine has no transcripts: nothing to read.
        if session.host.isDemo { return nil }
        guard session.canRunCommands else { throw UsageProbeError.unreachable }
        guard let script else { throw UsageProbeError.helperMissing }
        let plan = try launch(script: script, target: target, windows: session.isWindowsHost)
        return try parse(try await session.commandOutput(plan.command, input: plan.input, timeout: .seconds(15)))
    }
}
