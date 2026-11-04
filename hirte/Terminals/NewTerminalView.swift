import HerdrKit
import SwiftUI

/// Where a new terminal should go, e.g. "New Terminal Here" on a space.
struct NewTerminalContext: Identifiable {
    var space: HerdrAppLayout.Space?
    var folder: String?
    var id: String { space?.id ?? "none" }
}

/// Starts a shell, a command or an agent template on the machine.
struct NewTerminalView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case shell, command, agent
        var id: Self { self }
        var title: String {
            switch self {
            case .shell: "Shell"
            case .command: "Command"
            case .agent: "Agent"
            }
        }
    }

    /// Where herdr-app shows the new terminal.
    enum Placement: Hashable {
        case newSpace
        case space(String)
        /// No `herdr.space` label: herdr-app never shows it (like `hc run --bg`).
        case hidden
    }

    let session: HostSession
    let context: NewTerminalContext
    /// Called with the new terminal's address.
    let onStarted: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = Kind.shell
    @State private var command = ""
    @State private var templates: [TemplateInfo] = []
    @State private var template: String?
    @State private var task = ""
    @State private var folder = ""
    @State private var name = ""
    @State private var placement = Placement.newSpace
    @State private var machine: String?
    @State private var keep = true
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start", selection: $kind) {
                        ForEach(availableKinds) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch kind {
                case .shell:
                    EmptyView()
                case .command:
                    Section {
                        TextField("Command", text: $command, prompt: Text("npm run dev"), axis: .vertical)
                            .font(.body.monospaced())
                    } footer: {
                        Text("Runs through the machine's shell, so pipes and && work.")
                    }
                case .agent:
                    Section {
                        Picker("Template", selection: $template) {
                            ForEach(templates.filter { $0.error == nil }) { t in
                                Text(t.name).tag(Optional(t.name))
                            }
                        }
                        TextField("Task", text: $task, prompt: Text("Review src/x.rs. Read-only."), axis: .vertical)
                            .lineLimit(3...8)
                    } footer: {
                        if let selected = templates.first(where: { $0.name == template }) {
                            Text("\(selected.description)\n\(selected.command)")
                        }
                    }
                }

                Section {
                    TextField("Folder", text: $folder, prompt: Text(session.homeFolder ?? "home folder"))
                        .font(.body.monospaced())
                    TextField("Name", text: $name, prompt: Text("optional"))
                    if !session.machines.isEmpty {
                        Picker("Machine", selection: $machine) {
                            Text(session.coreName ?? "This machine").tag(String?.none)
                            ForEach(session.machines.filter { $0.state == "connected" }) { m in
                                Text(m.name).tag(Optional(m.name))
                            }
                        }
                    }
                } footer: {
                    if !name.isEmpty && !HerdrCore.isValidTerminalName(name) {
                        Text("Names use a–z, 0–9, - _ . (up to 32), start with a letter or digit, and can't look like an address such as t7.")
                            .foregroundStyle(.red)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                if machine == nil {
                    Section {
                        Picker("herdr-app", selection: $placement) {
                            Text("New space").tag(Placement.newSpace)
                            ForEach(session.layout?.spaces ?? []) { space in
                                Text("New tab in \(spaceTitle(space))").tag(Placement.space(space.id))
                            }
                            Text("Not in herdr-app").tag(Placement.hidden)
                        }
                    } footer: {
                        switch placement {
                        case .newSpace:
                            Text("herdr-app opens a new space for it, named after its folder.")
                        case .space:
                            Text("herdr-app adds it to that space as a new tab.")
                        case .hidden:
                            Text("Runs in the background: herdr-app does not show it (like `hc run --bg`). You can add it later.")
                        }
                    }
                }

                Section {
                    Toggle("Keep", isOn: $keep)
                } footer: {
                    Text("If its program is lost (a crash or reboot), start a fresh shell in its folder. The command itself is never run again.")
                }
            }
            .navigationTitle("New Terminal")
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
                            .disabled(!canStart)
                    }
                }
            }
            .alert("Could not start", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task {
                folder = context.folder ?? ""
                if let space = context.space { placement = .space(space.id) }
                templates = await session.templates()
                template = templates.first { $0.error == nil }?.name
            }
            .onChange(of: kind) { _, kind in
                // A shell is worth keeping; a one-off command or agent usually is not.
                keep = kind == .shell
            }
        }
    }

    private var availableKinds: [Kind] {
        templates.contains { $0.error == nil } ? Kind.allCases : [.shell, .command]
    }

    private var canStart: Bool {
        guard !starting, name.isEmpty || HerdrCore.isValidTerminalName(name) else { return false }
        switch kind {
        case .shell: return true
        case .command: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .agent: return template != nil
        }
    }

    private func spaceTitle(_ space: HerdrAppLayout.Space) -> String {
        space.name.isEmpty ? (space.folder.split(separator: "/").last.map(String.init) ?? space.id) : space.name
    }

    private func start() async {
        starting = true
        defer { starting = false }
        var request = RunRequest(keep: keep, on: machine)
        switch kind {
        case .shell: break
        case .command: request.line = command
        case .agent:
            guard let template else { return }
            let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            request.argv = task.isEmpty ? [template] : [template, task]
        }
        let folder = folder.trimmingCharacters(in: .whitespaces)
        request.cwd = folder.isEmpty ? (machine == nil ? session.homeFolder : nil) : folder
        request.name = name.isEmpty ? nil : name
        if machine == nil {
            switch placement {
            case .newSpace: request.labels = [HerdrAppLayout.spaceLabel: HerdrAppLayout.newSpaceID()]
            case .space(let id): request.labels = [HerdrAppLayout.spaceLabel: id]
            case .hidden: break
            }
        }
        do {
            let terminal = try await session.run(request)
            dismiss()
            onStarted(terminal.address)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
