import HerdrKit
import SwiftUI

/// Pure helpers for the New Session sheet.
enum NewSession {
    /// The command each agent's CLI goes by.
    static func command(_ agent: ChatAgent) -> String {
        switch agent {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
    }

    /// Finds each agent's CLI as the user's terminal would. A login shell alone isn't enough:
    /// on Linux PATH is usually set in .zshrc or .bashrc, which only an interactive shell reads.
    /// So it asks an interactive login shell for its PATH (marked, since an interactive shell may
    /// print a greeting), adds the usual install folders (npm, bun, volta, nvm, Homebrew), then
    /// looks. Prints `PATH<TAB>…` and one `name<TAB>/path` line per agent found.
    static let locateCommand = #"""
    sh -c 'p=$("${SHELL:-/bin/sh}" -lic "printf \"\n__BERGR_PATH__%s\n\" \"\$PATH\"" </dev/null 2>/dev/null | sed -n "s/^__BERGR_PATH__//p" | tail -n 1)
    n=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -n 1)
    PATH="$p:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.volta/bin:$n:/opt/homebrew/bin:/usr/local/bin:$PATH"
    printf "PATH\t%s\n" "$PATH"
    for c in claude codex agy; do f=$(command -v "$c" 2>/dev/null) && printf "%s\t%s\n" "$c" "$f"; done'
    """#

    /// The PATH `locateCommand` used, so an agent started from a script (`#!/usr/bin/env node`)
    /// finds its runtime too, wherever herdr-core itself was started from.
    static func parsePath(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("PATH\t") {
            let path = line.dropFirst(5).split(separator: ":").filter { !$0.isEmpty }
            var seen = Set<Substring>()
            return path.filter { seen.insert($0).inserted }.joined(separator: ":")
        }
        return nil
    }

    /// The agents found by `locateCommand`, with their full paths, in a fixed order.
    static func parseLocated(_ output: String) -> [(agent: ChatAgent, path: String)] {
        var found: [ChatAgent: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("/"),
                  let agent = [ChatAgent.claude, .codex, .antigravity].first(where: { command($0) == parts[0] })
            else { continue }
            found[agent] = parts[1]
        }
        return [ChatAgent.claude, .codex, .antigravity].compactMap { a in found[a].map { (a, $0) } }
    }

    /// The folders the machine's agents work in, most recently active first, without repeats.
    static func recentFolders(_ terminals: [Terminal], limit: Int = 6) -> [String] {
        let agents = terminals
            .filter { $0.isAgent && !$0.address.contains("/") }
            .sorted { ($0.statusMs ?? $0.createdMs) > ($1.statusMs ?? $1.createdMs) }
        var seen = Set<String>()
        var folders: [String] = []
        for t in agents {
            let cwd = t.foreground?.cwd ?? t.cwd
            guard !cwd.isEmpty, seen.insert(cwd).inserted else { continue }
            folders.append(cwd)
            if folders.count == limit { break }
        }
        return folders
    }

    /// `~/src/app` for a folder under home, else the path as is.
    static func display(_ folder: String, home: String?) -> String {
        guard let home, folder == home || folder.hasPrefix(home + "/") else { return folder }
        return "~" + folder.dropFirst(home.count)
    }

    /// What herdr-core runs: the agent, with the first message as its prompt when there is one.
    static func argv(path: String, message: String) -> [String] {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? [path] : [path, message]
    }
}

/// Starts Claude Code, Codex or Antigravity in a folder on one of the machines, then opens it.
struct NewSessionView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    let sessions: SessionStore
    /// The machine to start on, when started from one machine's list.
    var preferredHost: Host.ID?
    /// Called with the new terminal, to open its chat.
    let onStarted: (_ host: Host.ID, _ address: String) -> Void

    @State private var hostID: Host.ID?
    @State private var located: [Host.ID: [(agent: ChatAgent, path: String)]] = [:]
    @State private var searchPath: [Host.ID: String] = [:]
    @State private var locateFailed: [Host.ID: String] = [:]
    @State private var agent: ChatAgent?
    @State private var folder = ""
    @State private var message = ""
    @State private var starting = false
    @State private var error: String?

    /// Machines a session can start on: connected, and real (the demo can't run agents).
    private var machines: [Host] {
        hosts.hosts.filter { host in
            let session = sessions.session(for: host)
            return session.canRunCommands && session.state == .connected
        }
    }

    private var session: HostSession? {
        machines.first { $0.id == hostID }.map { sessions.session(for: $0) }
    }

    private var agents: [(agent: ChatAgent, path: String)]? { hostID.flatMap { located[$0] } }

    var body: some View {
        NavigationStack {
            Form {
                if machines.isEmpty {
                    Section {
                        Text("No machine is connected. Add one, or wait for yours to connect, then try again.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if machines.count > 1 {
                        Section {
                            Picker("Machine", selection: $hostID) {
                                ForEach(machines) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                    agentSection
                    if let session {
                        folderSection(session)
                    }
                    Section {
                        TextField("First message", text: $message, prompt: Text("Optional"), axis: .vertical)
                            .lineLimit(2...6)
                    } footer: {
                        Text("Sent as soon as the agent starts. Leave it empty to start with a blank conversation.")
                    }
                    if let error {
                        Section {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") { Task { await start() } }
                            .disabled(agent == nil || session == nil)
                    }
                }
            }
            .onAppear {
                if hostID == nil {
                    hostID = machines.first { $0.id == preferredHost }?.id ?? machines.first?.id
                }
            }
            .task(id: hostID) { await locate() }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        Section {
            if let agents {
                if agents.isEmpty {
                    Text("Claude Code, Codex and Antigravity aren't installed on this machine (none of claude, codex or agy is on its PATH).")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Agent", selection: $agent) {
                        ForEach(agents, id: \.agent) { found in
                            Text(found.agent == .claude ? "Claude Code" : found.agent.displayName)
                                .tag(Optional(found.agent))
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if let hostID, let failed = locateFailed[hostID] {
                HStack {
                    Text("Couldn't check which agents are installed: \(failed)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await locate() } }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding the agents on this machine…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func folderSection(_ session: HostSession) -> some View {
        let recent = NewSession.recentFolders(session.terminals)
        return Section {
            TextField("Folder", text: $folder, prompt: Text(session.homeFolder.map { NewSession.display($0, home: $0) } ?? "Home folder"))
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(recent, id: \.self) { path in
                Button {
                    folder = path
                } label: {
                    HStack {
                        Text(NewSession.display(path, home: session.homeFolder))
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        if folder == path {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Folder")
        } footer: {
            Text(recent.isEmpty ? "Empty starts in the home folder." : "Recent folders of this machine's agents. Empty starts in the home folder.")
        }
    }

    private func locate() async {
        guard let hostID, located[hostID] == nil, let session else { return }
        locateFailed[hostID] = nil
        do {
            let output = try await session.commandOutput(NewSession.locateCommand)
            let found = NewSession.parseLocated(output)
            searchPath[hostID] = NewSession.parsePath(output)
            located[hostID] = found
            if agent == nil || !found.contains(where: { $0.agent == agent }) { agent = found.first?.agent }
        } catch {
            locateFailed[hostID] = error.localizedDescription
        }
    }

    private func start() async {
        guard let hostID, let session, let agent,
              let path = agents?.first(where: { $0.agent == agent })?.path else { return }
        starting = true
        defer { starting = false }
        error = nil
        var request = RunRequest(argv: NewSession.argv(path: path, message: message))
        if let path = searchPath[hostID] { request.env?["PATH"] = path }
        let folder = folder.trimmingCharacters(in: .whitespaces)
        if folder.hasPrefix("~"), let home = session.homeFolder {
            request.cwd = home + folder.dropFirst()
        } else {
            request.cwd = folder.isEmpty ? session.homeFolder : folder
        }
        // Shown in herdr-app as a space of its own, like a terminal started there; nothing has
        // finished yet, so it starts read.
        request.labels = [Terminal.seenLabel: "0", HerdrAppLayout.spaceLabel: HerdrAppLayout.newSpaceID()]
        do {
            let terminal = try await session.run(request)
            dismiss()
            onStarted(hostID, terminal.address)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
