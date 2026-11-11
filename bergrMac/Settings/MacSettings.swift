import KeyStore
import SwiftUI

/// Native settings panes: each tab has exactly one root view.
struct MacSettings: View {
    let sessions: SessionStore
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @State private var showingLicenses = false
    @State private var editing: Host?
    @State private var creatingKey = false
    @State private var importingKey = false
    @State private var keyToDelete: SSHKeyInfo?
    @AppStorage(QuietAgents.key) private var hideAfter = QuietAgents.defaultSeconds
    @AppStorage(Delivery.notificationsKey) private var notifications = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @AppStorage(TerminalFont.storageKey) private var font = TerminalFont.jetBrainsMono
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize

    var body: some View {
        TabView {
            Form {
                Section("Agents") {
                    Picker("Hide finished agents after", selection: $hideAfter) {
                        ForEach(QuietAgents.choices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                    }
                }
                Section("About Bergr") {
                    LabeledContent("Version", value: SettingsView.version)
                    Link("Source Code", destination: URL(string: "https://github.com/MaroonBrian1928/bergr")!)
                    Button("Open-Source Licenses…") { showingLicenses = true }
                }
            }
            .modifier(SettingsPane())
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Machines") {
                    ForEach(hosts.hosts) { host in
                        Button { editing = host } label: {
                            MachineRow(host: host, session: sessions.existing(host.id))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Add Machine…", systemImage: "plus") { editing = Host.new(key: keys.keys.last?.id) }
                }
                // Inline, like a Mac settings pane: the keys themselves, with their actions on the
                // row and Create / Import buttons that open sheets (no drill-down screen).
                Section {
                    if let reason = keys.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    ForEach(keys.keys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.label)
                                Text(key.kind == .secureEnclave ? "Secure Enclave" : key.kind == .imported ? "Imported" : "On this Mac").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Copy Public Key") { Pasteboard.copy(key.authorizedKeysLine) }
                            Button(role: .destructive) { keyToDelete = key } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete Key")
                        }
                    }
                    HStack {
                        Button("Create Key…") { creatingKey = true }
                        Button("Import Key…") { importingKey = true }
                    }
                    .disabled(keys.unavailableReason != nil)
                } header: {
                    Text("SSH Keys")
                } footer: {
                    Text("Private keys stay on this Mac.")
                }
            }
            .modifier(SettingsPane())
            .tabItem { Label("Machines & Keys", systemImage: "server.rack") }
            .sheet(isPresented: $creatingKey) { NewKeyView() }
            .sheet(isPresented: $importingKey) { ImportKeyView() }
            .confirmationDialog("Delete \(keyToDelete?.label ?? "key")?", isPresented: Binding(
                get: { keyToDelete != nil }, set: { if !$0 { keyToDelete = nil } })) {
                Button("Delete", role: .destructive) { if let key = keyToDelete { keys.delete(key) } }
            } message: {
                Text("Machines that only accept this key won't let Bergr in anymore.")
            }

            Form {
                Section {
                    Toggle("Notify when an agent needs you or finishes", isOn: $notifications)
                        .onChange(of: notifications) { Delivery.apply() }
                } footer: {
                    Text("Bergr keeps watching your machines while it is running. Alerts respect your macOS notification settings and Focus.")
                }
            }
            .modifier(SettingsPane())
            .tabItem { Label("Notifications", systemImage: "bell") }

            Form {
                Section("Application") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Chat and Terminal") {
                    Picker("Light Theme", selection: $lightTheme) {
                        ForEach(TerminalTheme.lightThemes) { Text($0.name).tag($0.id) }
                    }
                    Picker("Dark Theme", selection: $darkTheme) {
                        ForEach(TerminalTheme.darkThemes) { Text($0.name).tag($0.id) }
                    }
                    Picker("Font", selection: $font) {
                        ForEach(TerminalFont.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Font size: \(fontSize.formatted()) pt", value: $fontSize, in: 7...28)
                }
            }
            .modifier(SettingsPane())
            .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }

            Form { TerminalSettingsView() }
                .modifier(SettingsPane())
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        // Width only: each tab is as tall as its content, like a Mac settings window.
        .frame(width: 600)
        .sheet(isPresented: $showingLicenses) { MacLicensesSheet() }
        .sheet(item: $editing) { HostEditor(host: $0).frame(width: 620, height: 640) }
    }
}

private struct SettingsPane: ViewModifier {
    func body(content: Content) -> some View {
        content.formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: License.ID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(License.all, selection: $selection) { license in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(license.name)
                        Text(license.license).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(license.id)
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                if let license = License.all.first(where: { $0.id == selection }) {
                    LicenseView(license: license).frame(minWidth: 360)
                } else {
                    ContentUnavailableView("Select a License", systemImage: "doc.text")
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 780, height: 560)
        .onAppear { selection = License.all.first?.id }
    }
}
