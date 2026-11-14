import Foundation

/// Runs the Setup checks on a connected machine and does each item's action.
@MainActor @Observable
final class MachineSetup {
    let session: HostSession
    private(set) var states: [SetupItem: CheckState] = [:]
    private(set) var agents: [AgentCLI: CheckState] = [:]
    private(set) var busy: SetupItem?
    private(set) var actionError: String?
    /// The Run buttons' progress and failures, by `repairID`.
    let repair = SetupRepair()
    /// The machine's OS, once a check has seen it.
    private(set) var hostOS: SetupCheck.HostOS?
    private var helperVersion: Int?

    init(session: HostSession) {
        self.session = session
    }

    var windows: Bool { session.isWindowsHost }

    /// The rows that apply to this machine, in order (sleep is not checked on Windows).
    var items: [SetupItem] { SetupItem.allCases.filter { $0 != .agents && !($0 == .sleep && windows) } }

    static func repairID(_ agent: AgentCLI) -> String { "agent.\(agent.rawValue)" }

    func check() async {
        guard session.state == .connected else { return }
        if windows { hostOS = .windows }
        states[.core] = SetupCheck.coreState(version: session.coreVersion)
        states[.git] = await gitState()
        states[.python] = await pythonState()
        if !windows { states[.sleep] = await sleepState() }
        for agent in AgentCLI.allCases { agents[agent] = await agentState(agent) }
        states[.push] = await pushState()
        if !windows, case .warning = states[.sleep],
           NotificationPrefs.load().keepAwake, let version = helperVersion, version >= SetupCheck.keepAwakeHelperVersion {
            states[.sleep] = .ready("Kept awake by Bergr while agents work")
        }
        states[.statusLine] = await statusLineState()
    }

    /// Install or set up one item, then check it again.
    func perform(_ item: SetupItem) async {
        guard busy == nil else { return }
        busy = item
        actionError = nil
        switch item {
        case .push:
            await PushRegistration.shared.install(on: session)
            actionError = PushRegistration.shared.lastError
            states[.push] = await pushState()
        case .statusLine:
            do {
                _ = try await session.setUpClaudeStatusLine()
            } catch {
                actionError = error.localizedDescription
            }
            states[.statusLine] = await statusLineState()
        case .core, .git, .python, .sleep, .agents:
            break
        }
        busy = nil
    }

    // MARK: Fixes

    /// What fixes this item or agent, if Bergr knows: a command to run, or one to copy.
    func fix(for item: SetupItem) -> SetupFix? {
        switch (item, states[item]) {
        case (.git, .missing?): SetupCheck.gitFix(os: hostOS)
        case (.sleep, .warning?): SetupCheck.sleepFix(os: hostOS)
        default: nil
        }
    }

    func fix(for agent: AgentCLI) -> SetupFix? {
        switch agents[agent] {
        case .missing?: SetupCheck.installFix(agent, windows: windows)
        case .warning?: SetupCheck.signInHint(agent).map { SetupFix(command: $0, runnable: false) }
        default: nil
        }
    }

    /// Installs an agent over the command channel, then checks it again.
    func install(_ agent: AgentCLI) async {
        guard session.state == .connected, let fix = SetupCheck.installFix(agent, windows: windows), fix.runnable else { return }
        await repair.run(Self.repairID(agent), fix: fix,
                         execute: { try await self.session.commandOutput($0, timeout: .seconds(300)) },
                         recheck: {
            let state = await self.agentState(agent)
            self.agents[agent] = state
            if case .missing = state { return false }
            return true
        })
    }

    // MARK: Checks

    private func pythonState() async -> CheckState {
        do {
            let output = try await run(SetupCheck.pythonCommand(windows: windows))
            if let version = SetupCheck.parsePython(output) { return .ready("Python \(version)") }
            return .missing("Not found. Install Python 3 on the machine, then check again.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A check's command output, tried twice: a channel can fail to open or close early once.
    private func run(_ command: String) async throws -> String {
        do {
            return try await session.commandOutput(command)
        } catch {
            try await Task.sleep(for: .milliseconds(300))
            return try await session.commandOutput(command)
        }
    }

    private func agentState(_ agent: AgentCLI) async -> CheckState {
        do {
            let output = try await run(SetupCheck.agentCommand(agent, windows: windows))
            let found = SetupCheck.parseAgent(output)
            guard found.installed else { return .missing("Not installed") }
            let version = found.version ?? "installed"
            // A failed probe leaves the agent as installed: only a clear "not signed in" warns.
            if let command = SetupCheck.signInCommand(agent, windows: windows),
               let probe = try? await run(command),
               SetupCheck.parseSignedIn(agent, output: probe) == false {
                return .warning("\(version). Not signed in. Run `\(SetupCheck.signInHint(agent) ?? agent.commands[0])` in a terminal on \(session.host.name).")
            }
            return .ready(version)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func gitState() async -> CheckState {
        do {
            let output = try await run(SetupCheck.gitCommand(windows: windows))
            if !windows { hostOS = SetupCheck.parseOS(output) ?? hostOS }
            if let version = SetupCheck.parseGit(output) { return .ready("git \(version)") }
            return .missing("Not installed. Changes needs it.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func sleepState() async -> CheckState {
        do {
            let output = try await run(SetupCheck.sleepCommand())
            if output.hasPrefix("darwin") { hostOS = .mac } else if output.hasPrefix("linux") { hostOS = .linux }
            return SetupCheck.sleepState(SetupCheck.parseSleep(output))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func pushState() async -> CheckState {
        guard let source = Bundle.main.url(forResource: "install-helper", withExtension: "py")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            return .failed("the installer is missing from the app")
        }
        do {
            let output = try await run(PushRegistration.installerCommand(installer: source, op: "status"))
            guard let status = SetupCheck.parseHelper(output) else { return .failed("no answer from the machine") }
            guard status.installed else { return .missing("Not installed. Push alerts need it.") }
            helperVersion = status.version
            if let version = status.version, let bundled = PushRegistration.bundledVersion, version < bundled {
                return .outdated("helper \(version), update to \(bundled) available")
            }
            return .ready(status.version.map { "helper \($0), up to date" } ?? "installed")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func statusLineState() async -> CheckState {
        do {
            let output = try await run(SetupCheck.statusLineCommand(windows: windows))
            return SetupCheck.parseStatusLine(output)
                ? .ready("Saved, and set in Claude Code's settings")
                : .missing("Shows Claude's context and plan usage in the chat.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
