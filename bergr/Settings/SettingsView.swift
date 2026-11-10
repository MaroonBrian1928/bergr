import KeyStore
import SwiftUI

/// App-wide settings, and what Bergr is.
struct SettingsView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @State private var editing: Host?
    /// Live connection state for the machine rows (nil: no status shown).
    var sessions: SessionStore?
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    @State private var keepAlive = KeepAlive.shared
    @AppStorage(LiveActivityController.pushKey) private var liveActivityPush = false
    @AppStorage(QuietAgents.key) private var hideAfter = QuietAgents.defaultSeconds
    @AppStorage(LiveActivityController.contentKey) private var liveActivityContent = "counts"
    @State private var push = PushRegistration.shared
    /// Adds the demo machine and shows it.
    var addDemo: () -> Void = {}

    private static let sourceCode = URL(string: "https://github.com/MaroonBrian1928/bergr")!

    /// A machine's helper line: its state, and which version it has (and which an update brings).
    private static func helperText(_ state: PushRegistration.HelperState?, installed: Int?) -> String {
        let bundled = PushRegistration.bundledVersion
        switch state {
        case .checking: return "checking…"
        case .failed(let reason): return "couldn't check: \(reason)"
        case .unsupported(let reason): return "push alerts aren't available — \(reason)"
        case .current: return installed.map { "helper \($0), up to date" } ?? "helper running"
        case .installing: return bundled.map { "installing helper \($0)…" } ?? "installing…"
        case .missing: return "not installed"
        case .outdated:
            switch (installed, bundled) {
            case let (i?, b?): return "helper \(i), update to \(b) available"
            case let (nil, b?): return "update to helper \(b) available"
            default: return "helper needs an update"
            }
        case nil: return "waiting to check…"
        }
    }

    var body: some View {
        form
            .modifier(PushPrompts(inSettings: true))
            .onAppear { push.settingsOpen = true }
            .onDisappear { push.settingsOpen = false }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(hosts.hosts) { host in
                    Button {
                        if !host.isDemo { editing = host }
                    } label: {
                        MachineRow(host: host, session: sessions?.existing(host.id))
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { hosts.delete(at: $0) }
                Button {
                    editing = Host.new(key: keys.keys.last?.id)
                } label: {
                    AccentLabel(title: "Add Machine", systemImage: "plus")
                }
            } header: {
                Text("Machines")
            } footer: {
                Text("Machines running herdr-core that Bergr connects to over SSH. Swipe a machine to delete it.")
            }

            Section {
                NavigationLink {
                    KeysView()
                } label: {
                    Label {
                        LabeledContent("Keys", value: keys.keys.count == 1 ? "1 key" : "\(keys.keys.count) keys")
                    } icon: {
                        SettingsIcon("key.fill", color: .gray)
                    }
                    .frame(minHeight: 44)
                }
            } footer: {
                Text("SSH keys that sign you in to your machines. Private keys stay on this device.")
            }

            Section {
                Picker(selection: $hideAfter) {
                    ForEach(QuietAgents.choices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                } label: {
                    Label {
                        Text("Hide finished agents after")
                    } icon: {
                        SettingsIcon("clock.arrow.circlepath", color: .gray)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            } footer: {
                Text("Finished and idle agents untouched for longer don't count on the Lock Screen and widget, and fold away under Older in the list. Agents that need you or are working always show.")
            }

            // In the order they depend on each other: alerts (the helper on each machine), the
            // Live Activity (sent the same way), and staying connected (the other way to get both).
            Section {
                Toggle(isOn: $push.enabled) {
                    Label {
                        Text("Push alerts")
                    } icon: {
                        SettingsIcon("app.badge.fill", color: .orange)
                    }
                }
                .frame(minHeight: 44)
                if push.enabled, let sessions {
                    ForEach(sessions.ids.compactMap { sessions.existing($0) }.filter { $0.state == .connected }, id: \.host.id) { session in
                        let state = push.helperState[session.host.id]
                        HStack {
                            Text("\(session.host.name): \(Self.helperText(state, installed: push.helperVersion[session.host.id]))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            if state == .missing || state == .outdated {
                                Button(state == .outdated ? "Update" : "Install") { push.installFromSettings(on: session) }
                                    .buttonStyle(.borderless)
                            } else if state == nil || { if case .failed = state { true } else { false } }() {
                                Button("Check") { Task { await push.checkHelper(on: session) } }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } header: {
                Text("When Bergr is closed")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get an alert when an agent needs you or finishes. A small helper on each machine sends them, encrypted so only this device can read them.")
                    if let error = push.lastError { Text(error).foregroundStyle(.red) }
                }
            }

            Section {
                Toggle(isOn: $liveActivityPush) {
                    Label {
                        Text("Live Activity")
                    } icon: {
                        SettingsIcon("platter.filled.top.iphone", color: .green)
                    }
                }
                .frame(minHeight: 44)
                .disabled(!push.enabled)
                if liveActivityPush, push.enabled {
                    Picker(selection: $liveActivityContent) {
                        Text("Counts").tag("counts")
                        Text("Counts and agent names").tag("full")
                    } label: {
                        Label {
                            Text("Show")
                        } icon: {
                            SettingsIcon("list.bullet", color: .gray)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                }
            } footer: {
                Text(!push.enabled
                     ? "Turn on push alerts to use this: the same helpers keep it up to date."
                     : liveActivityContent == "full"
                        ? "Agent names and status aren't encrypted: Apple and Bergr's push service can read them on the way to your Lock Screen."
                        : "How many agents need you, are working and are done, on your Lock Screen. Only the numbers leave your machines.")
            }

            Section {
                Toggle(isOn: $keepAlive.enabled) {
                    Label {
                        Text("Keep connected in background")
                    } icon: {
                        SettingsIcon("bell.badge.fill", color: .red)
                    }
                }
                .frame(minHeight: 44)
            } footer: {
                Text("Bergr stays connected and sends alerts and Live Activity updates itself, instantly and without the helpers. It uses more battery, and \"Always\" location access to keep running; your location is never stored or sent.")
            }

            Section {
                Picker(selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label {
                        Text("Appearance")
                    } icon: {
                        SettingsIcon("circle.lefthalf.filled", color: .indigo)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                TerminalPreview(
                    size: fontSize, family: fontFamily,
                    theme: TerminalTheme.current(colorScheme, light: lightTheme, dark: darkTheme))
                    .listRowInsets(EdgeInsets())
                NavigationLink {
                    ThemePicker(title: "Light Theme", themes: TerminalTheme.lightThemes, selection: $lightTheme)
                } label: {
                    Label {
                        LabeledContent("Light Theme", value: TerminalTheme.find(lightTheme, dark: false).name)
                    } icon: {
                        SettingsIcon("sun.max.fill", color: .orange)
                    }
                    .frame(minHeight: 44)
                }
                NavigationLink {
                    ThemePicker(title: "Dark Theme", themes: TerminalTheme.darkThemes, selection: $darkTheme)
                } label: {
                    Label {
                        LabeledContent("Dark Theme", value: TerminalTheme.find(darkTheme, dark: true).name)
                    } icon: {
                        SettingsIcon("moon.fill", color: .purple)
                    }
                    .frame(minHeight: 44)
                }
                Picker(selection: $fontFamily) {
                    ForEach(TerminalFont.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label {
                        Text("Font")
                    } icon: {
                        SettingsIcon("textformat", color: .blue)
                    }
                }
                .frame(minHeight: 44)
                Stepper(value: $fontSize, in: 7...28, step: 1) {
                    Label {
                        LabeledContent("Size", value: "\(fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                    } icon: {
                        SettingsIcon("textformat.size", color: .teal)
                    }
                }
                .frame(minHeight: 44)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The terminal uses the light or dark theme to match the appearance. Pinch a terminal to change the size there too.")
            }

            Section {
                LabeledContent("Version", value: Self.version)
                    .frame(minHeight: 44)
                Link(destination: Self.sourceCode) {
                    Label {
                        Text("Source Code").foregroundStyle(.primary)
                    } icon: {
                        SettingsIcon("chevron.left.forwardslash.chevron.right", color: .gray)
                    }
                    .frame(minHeight: 44)
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label {
                        Text("Open-Source Licenses")
                    } icon: {
                        SettingsIcon("doc.text.fill", color: .gray)
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("About")
            } footer: {
                Text(Self.trademarks)
            }
        }
        .bergrTint()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { HostEditor(host: $0) }
    }

    /// Bergr names the agents it works with; it isn't theirs.
    static let trademarks = "Claude and Claude Code are trademarks of Anthropic, PBC. Codex is a trademark of "
        + "OpenAI. Antigravity and Gemini are trademarks of Google LLC. Bergr is an independent app, not affiliated "
        + "with or endorsed by Anthropic, OpenAI or Google."

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A few lines in a theme and font, so changes show at once.
private struct TerminalPreview: View {
    let size: Double
    let family: TerminalFont
    let theme: TerminalTheme

    var body: some View {
        let fonts = Fonts(size: size, family: family)
        VStack(alignment: .leading, spacing: 0) {
            Self.line([("~/projects/shop-api ", theme.ansiColor(4)), ("❯ ", theme.ansiColor(5)), ("git log --oneline", nil)])
            Self.line([("a41c9e2 ", theme.ansiColor(3)), ("Add order totals endpoint", nil)])
            Self.line([("7d03b1f ", theme.ansiColor(3)), ("Cache product images", nil)])
            Self.line([("✓ ", theme.ansiColor(2)), ("48 passed ", nil), ("✗ ", theme.ansiColor(1)), ("0 failed", nil)])
        }
        .font(Font(fonts.regular))
        .foregroundStyle(theme.color(theme.foreground))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.color(theme.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(theme.name) in \(family.title)")
    }

    /// One line from colored pieces (nil: the theme's foreground).
    static func line(_ pieces: [(String, Color?)]) -> Text {
        var text = AttributedString()
        for (string, color) in pieces {
            var piece = AttributedString(string)
            if let color { piece.foregroundColor = color }
            text += piece
        }
        return Text(text)
    }
}

/// Every light (or dark) theme, each drawn in its own colors.
private struct ThemePicker: View {
    let title: String
    let themes: [TerminalTheme]
    @Binding var selection: String

    var body: some View {
        List(themes) { theme in
            Button {
                selection = theme.id
            } label: {
                HStack(spacing: 12) {
                    ThemeSwatch(theme: theme)
                    Text(theme.name).foregroundStyle(.primary)
                    Spacer()
                    if theme.id == selection {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
            }
            .accessibilityAddTraits(theme.id == selection ? .isSelected : [])
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A theme at a glance: its background with a prompt and the six main colors.
private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TerminalPreview.line([("❯ ", theme.ansiColor(5)), ("ls", nil)])
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color(theme.foreground))
            HStack(spacing: 3) {
                ForEach(1..<7) { index in
                    Circle().fill(theme.ansiColor(index)).frame(width: 7, height: 7)
                }
            }
        }
        .padding(8)
        .frame(width: 84, alignment: .leading)
        .background(theme.color(theme.background), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(HostStore())
        .environment(KeyLibrary())
}
