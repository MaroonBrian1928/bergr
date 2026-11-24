import KeyStore
import SwiftUI
import UniformTypeIdentifiers

/// App-wide settings, and what Bergr is.
struct SettingsView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @State private var editing: Host?
    @State private var importing = false
    @State private var importResult: String?
    /// Live connection state for the machine rows (nil: no status shown).
    var sessions: SessionStore?
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    /// Shake the phone to open Diagnostics (see ShakeToDiagnostics).
    @AppStorage(EchoPredictor.settingKey) private var predictTyping = false
    @AppStorage("bergr.shakeForDiagnostics") private var shakeForDiagnostics = true
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    @State private var keepAlive = KeepAlive.shared
    @AppStorage(LiveActivityKeys.push) private var liveActivityPush = false
    @AppStorage(QuietAgents.key) private var hideAfter = QuietAgents.defaultSeconds
    @AppStorage(LinkedMachines.showKey) private var showLinked = true
    @AppStorage(LinkedMachines.hiddenKey) private var hiddenLinked = ""
    private var liveActivityHistory: [String] {
        UserDefaults.standard.stringArray(forKey: LiveActivityKeys.history) ?? []
    }
    @AppStorage(LiveActivityKeys.content) private var liveActivityContent = "counts"
    @AppStorage(Delivery.notificationsKey) private var notifications = false

    /// "Updates come from": Bergr itself (kept running) or the helpers.
    private var stayRunning: Binding<Bool> {
        Binding(get: { keepAlive.enabled }, set: { keepAlive.enabled = $0; Delivery.apply() })
    }

    /// A Notifications or Live Activity switch: stores it, then registers the helpers to match.
    private func deliverySwitch(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; Delivery.apply() })
    }
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

    private func importMachines(_ result: Result<URL, Error>) -> String {
        guard case .success(let url) = result else { return "Couldn't open the file." }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(MachinesExport.self, from: data) else {
            return "That file isn't a Bergr machines export."
        }
        let n = export.apply(to: hosts, knownKeys: Set(keys.keys.map(\.id)), fallbackKey: keys.keys.last?.id)
        return n == 0 ? "Nothing new in that file." : n == 1 ? "Imported 1 machine." : "Imported \(n) machines."
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
                if hosts.hosts.contains(where: { !$0.isDemo && !$0.isLocal }) {
                    ShareLink(item: MachinesExport.make(hosts: hosts.hosts),
                              preview: SharePreview("Bergr Machines")) {
                        AccentLabel(title: "Export Machines", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    importing = true
                } label: {
                    AccentLabel(title: "Import Machines", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Machines")
            } footer: {
                Text(importResult ?? "Machines running herdr-core that Bergr connects to over SSH. Swipe a machine to delete it. An export holds the machines and their host keys, never a private key: on another phone, add that phone's key to your machines.")
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                importResult = importMachines(result)
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
                NavigationLink {
                    UsageScreen(sessions: sessions)
                } label: {
                    Label {
                        Text("Usage")
                    } icon: {
                        SettingsIcon("gauge.with.dots.needle.50percent", color: .teal)
                    }
                    .frame(minHeight: 44)
                }
            } footer: {
                Text("Context and plan usage of the agents running on your machines, across machines.")
            }

            Section {
                Picker(selection: $hideAfter) {
                    ForEach(QuietAgents.choices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                } label: {
                    Label {
                        Text("Hide finished agents after")
                    } icon: {
                        SettingsIcon("clock.fill", color: .orange)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            } footer: {
                Text("Finished and idle agents untouched for longer don't count on the Lock Screen and widget, and fold away under Older in the list. Agents that need you or are working always show.")
            }

            Section {
                Toggle(isOn: $showLinked) {
                    Label {
                        Text("Show machines linked through another")
                    } icon: {
                        SettingsIcon("point.3.connected.trianglepath.dotted", color: .cyan)
                    }
                }
                .frame(minHeight: 44)
                if !hiddenLinked.isEmpty {
                    Button("Show Hidden Linked Machines (\(LinkedMachines.hidden(hiddenLinked).count))") {
                        hiddenLinked = ""
                    }
                    .frame(minHeight: 44)
                }
            } footer: {
                Text("A machine another machine's core is linked to shows under it as \"via\" that machine. Turn this off, or long-press one machine's heading to hide just it, when you've also added those machines directly.")
            }

            #if os(iOS)
            // When Bergr isn't open: where updates come from, then what you get (either source).
            Section {
                Picker(selection: stayRunning) {
                    Text("Helpers on your computers").tag(false)
                    Text("Bergr stays running").tag(true)
                } label: {
                    Label {
                        Text("Updates come from")
                    } icon: {
                        SettingsIcon("arrow.down.circle.fill", color: .blue)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
            } header: {
                Text("When Bergr isn't open")
            } footer: {
                Text(keepAlive.enabled
                     ? "Bergr keeps running in the background and watches your computers itself. Agents' questions appear on the Lock Screen with buttons to answer them. Uses more battery, and needs \"Always\" location access to keep running. Bergr never stores or sends your location."
                     : "A small helper on each computer tells your phone what its agents are doing. Easy on the battery. When an agent asks for permission, the notification has buttons that open Bergr and answer it. Questions with more choices open the chat.")
            }
            #endif

            Section {
                Toggle(isOn: deliverySwitch($notifications)) {
                    Label {
                        Text("Notifications")
                    } icon: {
                        SettingsIcon("bell.badge.fill", color: .red)
                    }
                }
                .frame(minHeight: 44)
                #if os(iOS)
                Toggle(isOn: deliverySwitch($liveActivityPush)) {
                    Label {
                        Text("Live Activity")
                    } icon: {
                        SettingsIcon("platter.filled.top.iphone", color: .indigo)
                    }
                }
                .frame(minHeight: 44)
                if liveActivityPush, !keepAlive.enabled {
                    Picker(selection: $liveActivityContent) {
                        Text("Numbers only").tag("counts")
                        Text("Numbers and names").tag("full")
                    } label: {
                        Label {
                            Text("Show")
                        } icon: {
                            SettingsIcon("list.bullet.rectangle.fill", color: .blue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                }
                if liveActivityPush, !liveActivityHistory.isEmpty {
                    DisclosureGroup("Recent") {
                        ForEach(liveActivityHistory.reversed(), id: \.self) { line in
                            Text(line).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                }
                #endif
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    #if os(iOS)
                    Text("Notifications: when an agent needs you or finishes. Live Activity: how many agents need you, are working or are done.")
                    if liveActivityPush, !keepAlive.enabled, liveActivityContent == "full" {
                        Text("Names and status can be read by Apple and Bergr's push service on the way.")
                    }
                    #else
                    Text("Notifications: when an agent needs you or finishes.")
                    #endif
                }
            }

            if notifications { NotificationPrefsSection() }

            if push.enabled, let sessions {
                Section {
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
                } header: {
                    Text("Helpers")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Only this phone can read what the helpers send.")
                        Text("A helper set to direct mode in push.json sends straight to Apple: its alerts have no answer buttons and their text isn't encrypted.")
                        if let error = push.lastError { Text(error).foregroundStyle(.red) }
                    }
                }
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
                        SettingsIcon("textformat.size", color: .gray)
                    }
                }
                .frame(minHeight: 44)
                Toggle(isOn: $predictTyping) {
                    Label {
                        Text("Predict Typing on Slow Connections")
                    } icon: {
                        SettingsIcon("keyboard.badge.ellipsis", color: .green)
                    }
                }
                .frame(minHeight: 44)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The terminal uses the light or dark theme to match the appearance. Pinch a terminal to change the size there too.\n\nPredict Typing shows what you type at a shell prompt before the machine echoes it, underlined, on connections slower than 120 ms. Never at password prompts or in full-screen programs.")
            }

            Section {
                NavigationLink {
                    ApprovalsView()
                } label: {
                    Label {
                        Text("Approvals")
                    } icon: {
                        SettingsIcon("checkmark.shield.fill", color: .blue)
                    }
                    .frame(minHeight: 44)
                }
                NavigationLink {
                    AuthTrailView()
                } label: {
                    Label {
                        Text("Diagnostics")
                    } icon: {
                        SettingsIcon("waveform.path.ecg", color: .red)
                    }
                    .frame(minHeight: 44)
                }
                #if os(iOS)
                // Last in its section: a switch row's separator doesn't line up with the titles.
                Toggle(isOn: $shakeForDiagnostics) {
                    Label {
                        Text("Shake for Diagnostics")
                    } icon: {
                        SettingsIcon("iphone.radiowaves.left.and.right", color: .red)
                    }
                }
                .frame(minHeight: 44)
                #endif
            } header: {
                Text("Help")
            } footer: {
                #if os(iOS)
                Text("Shake your phone anywhere in Bergr to open Diagnostics and report a problem.")
                #else
                Text("Diagnostics keeps recent connection and Face ID events, and sends a problem report.")
                #endif
            }

            Section {
                NavigationLink {
                    TipJarView()
                } label: {
                    Label {
                        Text("Support Bergr")
                    } icon: {
                        SettingsIcon("heart.fill", color: .pink)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("support-bergr")
            }

            Section {
                LabeledContent {
                    Text(Self.version)
                } label: {
                    Label {
                        Text("Version")
                    } icon: {
                        SettingsIcon("info.circle.fill", color: .gray)
                    }
                }
                .frame(minHeight: 44)
                Link(destination: Self.sourceCode) {
                    LabeledContent {
                        // Leaves the app: the arrow says so, as in Apple's own lists.
                        Image(systemName: "arrow.up.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    } label: {
                        Label {
                            Text("Source Code")
                        } icon: {
                            SettingsIcon("chevron.left.forwardslash.chevron.right", color: .gray)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .tint(.primary)
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
        .inlineNavigationTitle()
        .sheet(item: $editing) { HostEditor(host: $0, setupSession: sessions?.existing($0.id)) }
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
        .font(fonts.regularFont)
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
        .inlineNavigationTitle()
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
