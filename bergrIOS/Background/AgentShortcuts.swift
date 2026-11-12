import AppIntents

extension NewSessionPrefill {
    /// From the queued "Start session" intent; nil when it names no agent Bergr knows.
    init?(_ item: PendingIntent) {
        guard case .newSession(let machine, let agent, let folder, let message) = item,
              let agent = ChatAgent(rawValue: agent)
        else { return nil }
        self.init(machine: machine, agent: agent, folder: folder, message: message)
    }
}

/// The Siri and Shortcuts phrases. App-only: the widget extension compiles the intents but not this.
nonisolated struct AgentShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatNeedsMeIntent(),
            phrases: ["What needs me in \(.applicationName)", "What needs me in \(.applicationName) agents"],
            shortTitle: "What needs me",
            systemImageName: "exclamationmark.bubble")
        AppShortcut(
            intent: SendToAgentIntent(),
            phrases: ["Send to an agent in \(.applicationName)", "Message an agent in \(.applicationName)"],
            shortTitle: "Send to agent",
            systemImageName: "paperplane")
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: ["Start a session in \(.applicationName)", "Start an agent in \(.applicationName)"],
            shortTitle: "Start session",
            systemImageName: "plus.circle")
    }
}
