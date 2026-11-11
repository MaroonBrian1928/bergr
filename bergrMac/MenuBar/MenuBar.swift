import AppKit
import HerdrKit
import SwiftUI

/// The menu-bar item: an icon and, when agents work or wait, their numbers ("2 · 1!"). It is
/// always on screen, so it also keeps the app's background duties: connecting every machine (so
/// counts are live with no window open), reconnecting after sleep, opening a tapped alert's
/// agent, and bringing the main window back from the Dock.
struct MenuBarLabel: View {
    let sessions: SessionStore
    let delegate: MacAppDelegate
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    private let router = NotificationRouter.shared

    var body: some View {
        let counts = AgentCounts(sessions: sessions)
        let title = AgentRoster.menuBarTitle(counts)
        HStack(spacing: 4) {
            Image(systemName: counts.needsYou > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill"
                                                  : "bubble.left.and.text.bubble.right")
            if !title.isEmpty { Text(title) }
        }
        .accessibilityLabel("Bergr")
        .accessibilityValue(counts.needsYou + counts.working == 0
            ? "No agents need you"
            : "\(counts.working) working, \(counts.needsYou) need you")
        .task {
            delegate.reopen = { openWindow(id: "main") }
            connectAll()
        }
        .onChange(of: hosts.hosts) { _, current in
            // Edited or deleted machines get a fresh session.
            for host in current where sessions.existing(host.id).map({ $0.host != host }) ?? false {
                sessions.remove(host.id)
            }
            for id in sessions.ids where !current.contains(where: { $0.id == id }) { sessions.remove(id) }
            connectAll()
        }
        .onChange(of: appearance, initial: true) { _, appearance in appearance.apply() }
        // The Mac keeps its connections while asleep only until the network drops: reconnect on wake.
        .task {
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                for host in hosts.hosts {
                    let session = sessions.session(for: host)
                    if session.state != .connected { session.retry(keys: keys) }
                }
            }
        }
        // A tapped alert opens its agent's window (also when the tap launched the app).
        .onChange(of: router.pending?.address, initial: true) {
            guard let target = router.pending else { return }
            router.pending = nil
            openWindow(value: AgentRef(host: target.host, address: target.address))
            NSApp.activate()
        }
    }

    private func connectAll() {
        for host in hosts.hosts {
            let session = sessions.session(for: host)
            if !session.isActive { session.start(keys: keys) }
        }
    }
}

/// The popover: agents that need you or work; a click opens the agent's window.
struct MenuBarContent: View {
    let sessions: SessionStore
    @Environment(HostStore.self) private var hosts
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var entries: [AgentEntry] {
        AgentRoster.attention(hosts.hosts.map { host in
            .init(id: host.id, name: host.name, terminals: sessions.existing(host.id)?.terminals ?? [])
        })
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 2) {
            if entries.isEmpty {
                Text("No agents need you or are working.")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ForEach(entries) { entry in
                    Button {
                        openWindow(value: entry.ref)
                        NSApp.activate()
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entry.state == .working ? Color.blue : Color.orange)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.title).lineLimit(1)
                                Text("\(entry.machine) · \(entry.state == .working ? "working" : "needs you")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().padding(.vertical, 4)
            Button("Open Bergr") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            Button("Settings…") {
                openSettings()
                NSApp.activate()
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            Button("Quit Bergr") { NSApp.terminate(nil) }
                .buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: 300)
    }
}
