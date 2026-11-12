import Foundation
import HerdrKit
import SwiftUI

/// One earlier conversation of an agent in a folder, as `recent-sessions.py` lists it.
struct RecentSession: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// Last modified, seconds since 1970.
    let mtime: Double
    let count: Int

    var date: Date { Date(timeIntervalSince1970: mtime) }
}

/// Lists and resumes earlier conversations (Claude Code, Codex) on a machine.
enum RecentSessions {
    static let script: String? = Bundle.main.url(forResource: "recent-sessions", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The program's arguments to continue conversation `id`; nil when the agent can't resume or
    /// the id isn't a plain id (it reaches a command line, so nothing else is let through).
    static func resumeArgv(agent: ChatAgent, path: String, id: String) -> [String]? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        switch agent {
        case .claude: return [path, "--resume", id]
        case .codex: return [path, "resume", id]
        case .antigravity: return nil
        }
    }

    /// The same as one shell line, every word quoted.
    static func shellLine(_ argv: [String]) -> String {
        argv.map { word in
            word.isEmpty || word.contains(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || "/._-+=:@,".contains($0))) })
                ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" : word
        }.joined(separator: " ")
    }

    /// The command (stage 1 of the chat helper's launch: it execs the first line of stdin, so the
    /// folder and the script never pass through shell parsing) and that line.
    static func launch(script: String, agent: ChatAgent, folder: String, windows: Bool) throws -> (command: String, input: Data) {
        let payload = try JSONSerialization.data(withJSONObject: ["argv": ["recent-sessions.py", agent.rawValue, folder]])
        let line = "import base64,json;D=json.loads(base64.b64decode('\(payload.base64EncodedString())'));"
            + "exec(base64.b64decode('\(Data(script.utf8).base64EncodedString())'))"
        let stage1 = "S=__import__('sys');exec(S.stdin.buffer.readline())"
        let command = windows
            ? "cmd /d /s /c \"set PATH=%LOCALAPPDATA%\\Programs\\Python\\Python313;%PATH%&& python.exe -I -u -c \(stage1)\""
            : "python3 -I -u -c \"\(stage1)\""
        return (command, Data((line + "\n").utf8))
    }

    static func decode(_ output: String) -> [RecentSession] {
        // The last line that parses: a login banner may come first.
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            if let list = try? JSONDecoder().decode([RecentSession].self, from: Data(line.utf8)) { return list }
        }
        return []
    }

    static func list(session: HostSession, agent: ChatAgent, folder: String) async throws -> [RecentSession] {
        guard let script, agent == .claude || agent == .codex else { return [] }
        let plan = try launch(script: script, agent: agent, folder: folder, windows: session.isWindowsHost)
        return decode(try await session.commandOutput(plan.command, input: plan.input))
    }

    /// "2h" style age for a row.
    static func age(_ session: RecentSession, now: Date = .now) -> String {
        Terminal.shortAge(session.date, now: now)
    }
}

/// End and Restart for one agent terminal, shared by the chat's menu and the agent rows.
@MainActor @Observable
final class AgentLifecycle {
    enum Action: Equatable { case end, restart }
    var confirming: Action?
    var error: String?

    /// Interrupts the agent (Esc), then kills its terminal.
    func end(session: HostSession, terminal: Terminal, interrupt: (() -> Void)?) {
        confirming = nil
        Task {
            do {
                if let interrupt, terminal.agentState == .working {
                    interrupt()
                    try await Task.sleep(for: .milliseconds(400))
                }
                try await session.kill(terminal.address)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Kills the terminal and starts the same agent in the same folder, resuming its conversation.
    func restart(session: HostSession, terminal: Terminal, agent: ChatAgent, conversationID: String?) {
        confirming = nil
        Task {
            do {
                let folder = terminal.foreground?.cwd ?? terminal.cwd
                let output = try await session.commandOutput(NewSession.locateCommand)
                guard let path = NewSession.parseLocated(output).first(where: { $0.agent == agent })?.path else {
                    throw LifecycleError("\(agent.displayName) isn't on this machine's PATH.")
                }
                var id = conversationID
                if id == nil {
                    // From a list row the conversation isn't known: the folder's newest one.
                    id = try await RecentSessions.list(session: session, agent: agent, folder: folder).first?.id
                }
                guard let id, let argv = RecentSessions.resumeArgv(agent: agent, path: path, id: id) else {
                    throw LifecycleError("There's no conversation to resume.")
                }
                var request = RunRequest(argv: argv)
                if let p = NewSession.parsePath(output) { request.env?["PATH"] = p }
                request.cwd = folder
                var labels = [Terminal.seenLabel: "0"]
                labels[HerdrAppLayout.spaceLabel] = terminal.labels[HerdrAppLayout.spaceLabel] ?? HerdrAppLayout.newSpaceID()
                request.labels = labels
                try await session.kill(terminal.address)
                _ = try await session.run(request)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    struct LifecycleError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

extension View {
    /// The confirmation and error dialogs for `AgentLifecycle`.
    func agentLifecycleDialogs(
        _ lifecycle: AgentLifecycle, name: String, end: @escaping () -> Void, restart: @escaping () -> Void
    ) -> some View {
        modifier(LifecycleDialogs(lifecycle: lifecycle, name: name, end: end, restart: restart))
    }
}

private struct LifecycleDialogs: ViewModifier {
    @Bindable var lifecycle: AgentLifecycle
    let name: String
    let end: () -> Void
    let restart: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                lifecycle.confirming == .restart ? "Restart \(name)?" : "End \(name)?",
                isPresented: Binding(get: { lifecycle.confirming != nil }, set: { if !$0 { lifecycle.confirming = nil } }),
                titleVisibility: .visible
            ) {
                if lifecycle.confirming == .restart {
                    Button("Restart", role: .destructive, action: restart)
                } else {
                    Button("End Session", role: .destructive, action: end)
                }
                Button("Cancel", role: .cancel) { lifecycle.confirming = nil }
            } message: {
                Text(lifecycle.confirming == .restart
                     ? "Ends this terminal and starts the agent again, resuming the same conversation."
                     : "Interrupts the agent, then ends its terminal. The conversation stays on the machine to resume.")
            }
            .alert("Couldn't complete that action", isPresented: Binding(get: { lifecycle.error != nil }, set: { if !$0 { lifecycle.error = nil } })) {
                Button("OK") { lifecycle.error = nil }
            } message: {
                Text(lifecycle.error ?? "")
            }
    }
}

/// The recent conversations in the New Session sheet.
struct RecentSessionsSection: View {
    let sessions: [RecentSession]
    let loading: Bool
    let resume: (RecentSession) -> Void

    var body: some View {
        if loading || !sessions.isEmpty {
            Section {
                if loading && sessions.isEmpty {
                    HStack(spacing: 8) { ProgressView(); Text("Looking for earlier conversations…").foregroundStyle(.secondary) }
                }
                ForEach(sessions) { s in
                    Button { resume(s) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title.isEmpty ? "Untitled conversation" : s.title)
                                    .foregroundStyle(.primary).lineLimit(2)
                                Text("\(s.count) message\(s.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(RecentSessions.age(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .macPlainButton()
                }
            } header: {
                Text("Recent conversations")
            } footer: {
                Text("Tap one to continue it in this folder.")
            }
        }
    }
}
