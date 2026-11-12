import HerdrKit
import SwiftUI

/// The menu bar's commands. ⌘, (Settings) comes with the `Settings` scene.
struct MacCommands: SwiftUI.Commands {
    let sessions: SessionStore
    let hosts: HostStore
    let shell: MacShell

    @AppStorage("agents.grouping") private var grouping = ""

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.agentRef) private var current
    @FocusedValue(\.showAgent) private var showAgent
    @FocusedValue(\.openTerminal) private var openTerminal
    @FocusedValue(\.interruptAgent) private var interrupt

    /// Shows an agent: in the focused main window, else in its own window (which focuses it if
    /// it already has one).
    private func show(_ ref: AgentRef) {
        if let showAgent {
            showAgent(ref)
        } else {
            openWindow(value: ref)
        }
    }

    /// Every machine's live agents, as the agents list orders them.
    private var allAgents: [AgentRef] {
        hosts.hosts.flatMap { host in
            AgentsOrdering.ordered((sessions.existing(host.id)?.terminals ?? []).filter(\.isLive))
                .map { AgentRef(host: host.id, address: $0.address) }
        }
    }

    private func attention() -> [AgentRef] {
        AgentRoster.attention(hosts.hosts.map { host in
            .init(id: host.id, name: host.name, terminals: sessions.existing(host.id)?.terminals ?? [])
        }).filter { $0.state == .needsYou || $0.state == .error }.map(\.ref)
    }

    private func step(_ by: Int) {
        if let next = AgentRoster.step(from: current, in: attention(), by: by) { show(next) }
    }

    var body: some SwiftUI.Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") {
                shell.showingNewSession = true
                openWindow(id: "main")
            }
            .keyboardShortcut("n")
            Button("Add Machine…") {
                shell.showingAddMachine = true
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Window for Agent") { if let current { openWindow(value: current) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(current == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        }

        CommandGroup(after: .windowList) {
            Button("Usage") { openWindow(id: "usage") }
        }

        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Picker("Group Agents by", selection: Binding(get: { grouping.isEmpty ? "machine" : grouping }, set: { grouping = $0 })) {
                Text("Machine").tag("machine")
                Text("Attention").tag("attention")
            }
        }

        CommandMenu("Agent") {
            Button("Open in Terminal") {
                openTerminal?()
            }
            .keyboardShortcut("t")
            .disabled(current == nil)

            Button("Interrupt") { interrupt?() }
                .keyboardShortcut(".")
                .disabled(interrupt == nil)

            Divider()

            Button("Next Agent Needing You") { step(1) }
                .keyboardShortcut("]")
            Button("Previous Agent Needing You") { step(-1) }
                .keyboardShortcut("[")

            Divider()

            // ⌘1…⌘9: the agents in the list's order, like the iPad's keyboard shortcuts.
            ForEach(1...9, id: \.self) { number in
                Button("Open Agent \(number)") {
                    let agents = allAgents
                    if agents.indices.contains(number - 1) { show(agents[number - 1]) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
    }
}
