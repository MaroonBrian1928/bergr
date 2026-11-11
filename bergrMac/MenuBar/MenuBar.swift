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
            // Bergr's own mark as a template image: it takes the menu bar's color like the system's.
            Image("MenuBarIcon")
            if !title.isEmpty { Text(title).monospacedDigit() }
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
        let needs = entries.filter { $0.state != .working }
        let working = entries.filter { $0.state == .working }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bergr").font(.headline)
                Spacer()
                Text(summary(needs: needs.count, working: working.count))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.secondary)
                    Text("All quiet").font(.subheadline.weight(.medium))
                    Text("No agent needs you or is working.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Needs You", needs)
                        section("Working", working)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Open Bergr") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut("o")
                Spacer()
                Menu {
                    Button("Settings…") { openSettings(); NSApp.activate() }
                    Divider()
                    Button("Quit Bergr") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private func summary(needs: Int, working: Int) -> String {
        switch (needs, working) {
        case (0, 0): return ""
        case (_, 0): return "\(needs) need\(needs == 1 ? "s" : "") you"
        case (0, _): return "\(working) working"
        default: return "\(needs) need\(needs == 1 ? "s" : "") you · \(working) working"
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AgentEntry]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            ForEach(items) { entry in
                MenuBarRow(entry: entry) {
                    openWindow(value: entry.ref)
                    NSApp.activate()
                }
            }
        }
    }
}

/// One agent in the popover: the native-looking hover highlight, the whole row clickable.
private struct MenuBarRow: View {
    let entry: AgentEntry
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle()
                    .fill(entry.state == .working ? Color.blue : Color.orange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).lineLimit(1)
                    Text(entry.machine).font(.caption).foregroundStyle(hovering ? .primary : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.accentColor.opacity(0.85) : .clear, in: .rect(cornerRadius: 6))
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
