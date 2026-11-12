import Foundation

/// Runs the Setup checks on a connected machine and does each item's action.
@MainActor @Observable
final class MachineSetup {
    let session: HostSession
    private(set) var states: [SetupItem: CheckState] = [:]
    private(set) var agents: [AgentCLI: CheckState] = [:]
    private(set) var busy: SetupItem?
    private(set) var actionError: String?

    init(session: HostSession) {
        self.session = session
    }

    var windows: Bool { session.isWindowsHost }

    func check() async {
        guard session.state == .connected else { return }
        states[.core] = .ready(session.coreVersion.map { "version \($0)" } ?? "running")
        states[.python] = await pythonState()
        for agent in AgentCLI.allCases { agents[agent] = await agentState(agent) }
        states[.push] = await pushState()
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
        case .core, .python, .agents:
            break
        }
        busy = nil
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
            return .ready(found.version ?? "installed")
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
