import KeyStore
import SwiftUI

/// Native settings panes: each tab has exactly one root view.
struct MacSettings: View {
    let sessions: SessionStore
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @State private var editing: Host?
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
                    NavigationLink("Open-Source Licenses") { LicensesView() }
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
                Section("SSH Keys") {
                    NavigationLink("Manage Keys (\(keys.keys.count))") { KeysView() }
                    Text("Private keys stay on this Mac.").foregroundStyle(.secondary)
                }
            }
            .modifier(SettingsPane())
            .tabItem { Label("Machines & Keys", systemImage: "server.rack") }

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
        .frame(width: 660, height: 540)
        .sheet(item: $editing) { HostEditor(host: $0).frame(width: 620, height: 640) }
    }
}

private struct SettingsPane: ViewModifier {
    func body(content: Content) -> some View {
        NavigationStack { content.formStyle(.grouped) }
            .padding(.top, 8)
    }
}
