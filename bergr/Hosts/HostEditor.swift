import HerdrKit
import SwiftUI

/// What was typed in the address field: `user@host`, `user@host:port` or just `host`.
struct ParsedAddress: Equatable {
    var user: String?
    var host: String
    var port: Int?
    /// A `:port` was typed but is not a number from 1 to 65535.
    var badPort = false
}

func parseAddress(_ text: String) -> ParsedAddress {
    var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = ParsedAddress(user: nil, host: "")
    if let at = rest.lastIndex(of: "@") {
        let user = rest[..<at].trimmingCharacters(in: .whitespaces)
        result.user = user.isEmpty ? nil : user
        rest = String(rest[rest.index(after: at)...])
    }
    // IPv6 in brackets: [::1]:22
    if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
        result.host = String(rest[rest.index(after: rest.startIndex)..<close])
        let tail = rest[rest.index(after: close)...]
        if tail.hasPrefix(":") { applyPort(String(tail.dropFirst()), to: &result) }
    } else if let colon = rest.lastIndex(of: ":"), rest.firstIndex(of: ":") == colon {
        result.host = rest[..<colon].trimmingCharacters(in: .whitespaces)
        applyPort(String(rest[rest.index(after: colon)...]), to: &result)
    } else {
        result.host = rest.trimmingCharacters(in: .whitespaces)
    }
    return result
}

private func applyPort(_ text: String, to result: inout ParsedAddress) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return }
    if let port = Int(trimmed), (1...65535).contains(port) { result.port = port } else { result.badPort = true }
}

/// The line to paste on the machine to allow a key in; single quotes in it are escaped.
func authorizeCommand(for line: String) -> String {
    "echo '\(line.replacingOccurrences(of: "'", with: "'\\''"))' >> ~/.ssh/authorized_keys"
}

struct HostEditor: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State var host: Host
    @State private var address = ""
    @State private var port = ""
    @State private var session = ""
    @State private var showingNewKey = false
    #if os(macOS)
    @State private var showingImport = false
    #endif
    @State private var confirmDelete = false
    @State private var copied: String?
    @State private var test: HostSession?
    @State private var tested = false
    @State private var systemSSH: SystemSSHTest.Outcome?
    @State private var testingSystemSSH = false
    @State private var sshAttemptID = UUID()
    @State private var sshTask: Task<Void, Never>?
    #if os(macOS)
    @State private var sshProcess = SystemSSHTest.Attempt()
    #endif

    private var palette: ChatPalette { .of(scheme) }
    private var isExisting: Bool { hosts.hosts.contains { $0.id == host.id } }
    private var key: SSHKeyInfo? { keys.key(id: host.keyID) }
    private var portValue: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 22 }
        guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }
    /// Why Save is greyed out, in words; nil when it can save.
    private var saveHint: String? {
        if host.target.host.trimmed.isEmpty { return "Enter an address to save." }
        if host.isLocal { return nil }
        if host.target.username.trimmed.isEmpty { return "Enter a username (user@address) to save." }
        if portValue == nil { return "The port must be a number from 1 to 65535." }
        if host.keyID == nil && !host.usesSystemSSH { return "Pick or create a key to save." }
        return nil
    }

    private var canSave: Bool {
        !host.target.host.trimmed.isEmpty && (host.isLocal || (!host.target.username.trimmed.isEmpty && (host.usesSystemSSH || host.keyID != nil) && portValue != nil))
    }

    var body: some View {
        NavigationStack {
          // A test's outcome shows where you are looking: scrolled into view when it arrives.
          ScrollViewReader { proxy in
            Form {
                addressSection
                #if os(macOS)
                if !isExisting { importSection }
                #endif
                if let saveHint {
                    Section {} footer: {
                        Label(saveHint, systemImage: "info.circle").font(.footnote)
                    }
                }
                keySection
                if let key, !host.usesSystemSSH { authorizeSection(key) }
                testSection
                #if os(macOS)
                systemSSHSection
                #endif
                sessionSection
                if isExisting {
                    Section {
                        Button("Delete Machine", role: .destructive) { confirmDelete = true }
                            .frame(minHeight: PlatformMetrics.controlHeight)
                            .accessibilityIdentifier("delete-machine")
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .tint(palette.accent)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: test?.state) {
                withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo("test-result", anchor: .bottom) }
            }
            .onChange(of: test?.pendingHostKey?.fingerprint) {
                withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo("test-result", anchor: .bottom) }
            }
          }
            .navigationTitle(isExisting ? "Edit Machine" : "Add Machine")
            .inlineNavigationTitle()
            .onAppear(perform: load)
            .onDisappear { stopTest(); cancelSystemSSH() }
            .onChange(of: host.target) { cancelSystemSSH() }
            .onChange(of: port) { cancelSystemSSH() }
            #if os(macOS)
            .sheet(isPresented: $showingImport) { SSHConfigImportView { dismiss() } }
            #endif
            .sheet(isPresented: $showingNewKey, onDismiss: {
                if let newest = keys.keys.last, host.keyID == nil || !keys.keys.contains(where: { $0.id == host.keyID }) {
                    host.keyID = newest.id
                }
            }) { NewKeyView() }
            .confirmationDialog("Delete “\(host.name.trimmed.isEmpty ? host.target.host : host.name)”?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Machine", role: .destructive) {
                    if let index = hosts.hosts.firstIndex(where: { $0.id == host.id }) {
                        hosts.delete(at: IndexSet(integer: index))
                    }
                    dismiss()
                }
            } message: {
                Text("Bergr forgets this machine. Nothing changes on the machine itself.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
    }

    // MARK: Sections

    private var addressSection: some View {
        Group {
            Section {
                TextField("Address", text: $address, prompt: Text("me@192.168.1.20"))
                    .urlKeyboard()
                    .noAutocapitalization()
                    .autocorrectionDisabled()
                    .frame(minHeight: PlatformMetrics.controlHeight)
                    .accessibilityIdentifier("address-field")
                    .onChange(of: address) { _, text in applyAddress(text) }
                TextField("Name", text: $host.name, prompt: Text(host.target.host.isEmpty ? "My machine" : host.target.host))
                    .wordsAutocapitalization()
                    .frame(minHeight: PlatformMetrics.controlHeight)
            } header: {
                Text("Where it is")
            } footer: {
                Text("Type user@address, or user@address:port if SSH is not on port 22. Use the address you would give to ssh in a terminal. The name is only for you.")
            }
            Section {
                TextField("Username", text: $host.target.username, prompt: Text("me"))
                    .textContentType(.username)
                    .frame(minHeight: PlatformMetrics.controlHeight)
                TextField("Hostname", text: $host.target.host, prompt: Text("server.example.com"))
                    .urlKeyboard()
                    .frame(minHeight: PlatformMetrics.controlHeight)
                TextField("Port", text: $port, prompt: Text("22"))
                    .numberKeyboard()
                    .frame(minHeight: PlatformMetrics.controlHeight)
            } header: {
                Text("Address details")
            } footer: {
                if portValue == nil {
                    Text("The port must be a number from 1 to 65535.").foregroundStyle(.red)
                } else {
                    Text("Filled in from the address above. You can also edit them here.")
                }
            }
            .noAutocapitalization()
            .autocorrectionDisabled()
        }
    }

    #if os(macOS)
    private var importSection: some View {
        Section {
            Button("Import from ~/.ssh/config", systemImage: "square.and.arrow.down") { showingImport = true }
                .frame(minHeight: PlatformMetrics.controlHeight)
        } footer: {
            Text("Adds the machines in this Mac's SSH config in one tap each, with their HostName, User and Port.")
        }
    }
    #endif

    private var keySection: some View {
        Section {
            #if os(macOS)
            Toggle("Use this Mac's SSH", isOn: Binding(
                get: { host.usesSystemSSH }, set: { host.systemSSH = $0 }))
            #endif
            if !host.usesSystemSSH {
            Picker("Key", selection: $host.keyID) {
                Text("None").tag(UUID?.none)
                ForEach(keys.keys) { Text($0.label).tag(Optional($0.id)) }
            }
            .frame(minHeight: PlatformMetrics.controlHeight)
            Button("New Key…", systemImage: "plus.circle") { showingNewKey = true }
                .frame(minHeight: PlatformMetrics.controlHeight)
            }
        } header: {
            Text("Key")
        } footer: {
            if host.usesSystemSSH {
                Text("Uses this Mac's SSH config, known hosts and ssh-agent. Your private key stays with macOS; no import is needed. For a new host or a locked key, connect once in Terminal first.")
            } else {
            Text(keys.keys.isEmpty
                 ? "Bergr signs in with a key that stays on this phone. Create one to start."
                 : "Bergr signs in with this key. The private half never leaves this phone.")
            }
        }
    }

    private func authorizeSection(_ key: SSHKeyInfo) -> some View {
        let line = key.authorizedKeysLine
        let command = authorizeCommand(for: line)
        return Section {
            Text(line)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(.vertical, 4)
            HStack {
                copyButton("Copy Key", id: "key", text: line)
                Spacer()
                ShareLink(item: line) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
            }
            .frame(minHeight: PlatformMetrics.controlHeight)
            .buttonStyle(.borderless)
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(.vertical, 4)
            copyButton("Copy Command", id: "command", text: command)
                .frame(minHeight: PlatformMetrics.controlHeight)
                .buttonStyle(.borderless)
        } header: {
            Text("Let this phone in")
        } footer: {
            Text("Run the command on the machine, in a terminal there (or over a login you already have). It adds this key to ~/.ssh/authorized_keys, the list of keys that may sign in as that user. Without it the machine refuses Bergr.")
        }
    }

    private func copyButton(_ title: String, id: String, text: String) -> some View {
        Button(copied == id ? "Copied" : title, systemImage: copied == id ? "checkmark" : "doc.on.doc") {
            Pasteboard.copy(text)
            copied = id
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copied == id { copied = nil }
            }
        }
    }

    private var testSection: some View {
        Section {
            Button(action: runTest) {
                HStack {
                    if isTesting { ProgressView().padding(.trailing, 4) }
                    Text(isTesting ? "Testing…" : "Test Connection").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(!canSave || isTesting)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityIdentifier("test-connection")
            if let test { result(test) }
        } header: {
            Text("Test the connection")
        } footer: {
            Text("Tries to sign in and start herdr-core with what is above, without saving. You can save without testing, for example if the machine is off.")
        }
    }

    #if os(macOS)
    private var systemSSHSection: some View {
        Section {
            Button(testingSystemSSH ? "Testing…" : "Test System ssh") {
                testingSystemSSH = true
                systemSSH = nil
                var target = host.target
                target.port = portValue ?? 22
                let id = UUID()
                sshAttemptID = id
                let attempt = SystemSSHTest.Attempt()
                sshProcess = attempt
                sshTask = Task {
                    let outcome = await attempt.run(target)
                    guard !Task.isCancelled, sshAttemptID == id else { return }
                    systemSSH = outcome
                    testingSystemSSH = false
                }
            }
            .disabled(testingSystemSSH || host.target.host.trimmed.isEmpty)
            switch systemSSH {
            case .works: Label("ssh works without a prompt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let text), .unavailable(let text): Text(text).font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
            case nil: EmptyView()
            }
        } header: {
            Text("Open in terminal")
        } footer: {
            Text("Terminals open with the system ssh, which can't use Bergr's Secure Enclave key. "
                + "It needs its own key or ssh-agent login for this machine; copy Bergr's public key above to authorize it too.")
        }
    }
    #endif

    private func cancelSystemSSH() {
        sshAttemptID = UUID()
        sshTask?.cancel()
        sshTask = nil
        #if os(macOS)
        sshProcess.cancel()
        #endif
        testingSystemSSH = false
        systemSSH = nil
    }

    private var isTesting: Bool {
        guard let test else { return false }
        if test.pendingHostKey != nil { return true }
        if case .connecting = test.state { return true }
        return test.state == .idle && !tested
    }

    @ViewBuilder
    private func result(_ test: HostSession) -> some View {
        resultBody(test).id("test-result")
    }

    @ViewBuilder
    private func resultBody(_ test: HostSession) -> some View {
        if let offered = test.pendingHostKey {
            VStack(alignment: .leading, spacing: 8) {
                Label("Trust this machine?", systemImage: "questionmark.shield").font(.headline)
                Text("This is the first time Bergr connects to \(offered.host). Check that this fingerprint matches the machine (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub there).")
                    .font(.subheadline)
                Text(offered.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Trust") { test.answerHostKey(trust: true) }.buttonStyle(.borderedProminent)
                    Button("Don't Trust", role: .destructive) { test.answerHostKey(trust: false) }.buttonStyle(.bordered)
                }
                .frame(minHeight: PlatformMetrics.controlHeight)
            }
        } else {
            switch test.state {
            case .idle: EmptyView()
            case .connecting(let step):
                Text(step).foregroundStyle(.secondary)
            case .connected:
                Label("Connected — herdr-core \(test.coreVersion ?? "")".trimmed, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            case .failed(let message, _):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Can't connect", systemImage: "xmark.octagon.fill")
                        .font(.headline).foregroundStyle(.red)
                    Text(message).font(.subheadline).textSelection(.enabled)
                }
            }
        }
    }

    private var sessionSection: some View {
        Section {
            TextField("Session", text: $session, prompt: Text("default"))
                .noAutocapitalization()
                .autocorrectionDisabled()
                .frame(minHeight: PlatformMetrics.controlHeight)
        } header: {
            Text("herdr-core")
        } footer: {
            Text("Leave empty for the default session. herdr-core must be on PATH or in ~/.local/bin on the machine.")
        }
    }

    // MARK: Actions

    private func load() {
        guard address.isEmpty, port.isEmpty else { return }
        port = host.target.port == 22 ? "" : String(host.target.port)
        session = host.session ?? ""
        if !host.target.host.isEmpty {
            address = "\(host.target.username)@\(host.target.host)" + (host.target.port == 22 ? "" : ":\(host.target.port)")
        }
    }

    private func applyAddress(_ text: String) {
        let parsed = parseAddress(text)
        host.target.host = parsed.host
        if let user = parsed.user { host.target.username = user }
        if parsed.badPort { port = "?" } else { port = parsed.port.map(String.init) ?? "" }
    }

    private var draft: Host {
        var draft = host
        draft.target.host = host.target.host.trimmed
        draft.target.username = host.target.username.trimmed
        draft.target.port = portValue ?? 22
        let name = session.trimmed
        draft.session = name.isEmpty ? nil : name
        if draft.name.trimmed.isEmpty { draft.name = draft.target.host }
        return draft
    }

    private func save() {
        stopTest()
        hosts.save(draft)
        dismiss()
    }

    private func runTest() {
        stopTest()
        tested = false
        let new = HostSession(host: draft)
        test = new
        new.start(keys: keys)
        Task {
            // Wait for the answer, then stop so a failed test does not keep retrying.
            while test === new {
                try? await Task.sleep(for: .milliseconds(200))
                if new.pendingHostKey != nil { continue }
                switch new.state {
                case .connected, .failed:
                    tested = true
                    new.stop()
                    return
                default: continue
                }
            }
        }
    }

    private func stopTest() {
        test?.stop()
        test = nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
