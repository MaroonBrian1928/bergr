import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    @Environment(KeyLibrary.self) private var keys
    @State private var creating = false
    @State private var importing = false

    var body: some View {
        List {
            if let reason = keys.unavailableReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }
            if keys.keys.isEmpty {
                ContentUnavailableView {
                    Label("No keys", systemImage: "key")
                } description: {
                    Text("Create a key, then add its public key to ~/.ssh/authorized_keys on your machines.")
                } actions: {
                    Button("Create Key") { creating = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Import Key") { importing = true }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(keys.keys) { key in
                    NavigationLink(value: key) {
                        KeyRow(key: key)
                    }
                }
                .onDelete { offsets in
                    offsets.map { keys.keys[$0] }.forEach(keys.delete)
                }
                if !keys.keys.isEmpty {
                    Button {
                        creating = true
                    } label: {
                        AccentLabel(title: "New Key", systemImage: "plus")
                    }
                    Button {
                        importing = true
                    } label: {
                        AccentLabel(title: "Import Key", systemImage: "square.and.arrow.down")
                    }
                }
            } footer: {
                if !keys.keys.isEmpty {
                    Text("Add a key's public line to ~/.ssh/authorized_keys on each machine. Private keys never leave this device.")
                }
            }
        }
        .bergrTint()
        .navigationTitle("Keys")
        .navigationDestination(for: SSHKeyInfo.self) { KeyDetailView(key: $0) }
        .toolbar {
            Menu("Add Key", systemImage: "plus") {
                Button("New Key", systemImage: "plus") { creating = true }
                Button("Import Key", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .sheet(isPresented: $creating) { NewKeyView() }
        .sheet(isPresented: $importing) { ImportKeyView() }
    }
}

struct KeyRow: View {
    let key: SSHKeyInfo
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsIcon("key.fill", color: key.kind == .secureEnclave ? .green : key.kind == .imported ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.label).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(key.kind == .secureEnclave ? "Secure Enclave"
                            : key.kind == .imported ? "Imported · \(key.algorithm == .ed25519 ? "ed25519" : "ecdsa P-256")"
                            : "Software key (no Secure Enclave)")
                        if key.requiresBiometry {
                            Image(systemName: "faceid")
                            Text("Face ID")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(key.kind == .software ? Color.orange : Color.secondary)
                }
            }
            Text(key.authorizedKeysLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 20) {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Pasteboard.copy(key.authorizedKeysLine)
                    copied = true
                }
                ShareLink(item: key.authorizedKeysLine) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}

struct NewKeyView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State private var label = DeviceName.current
    @State private var requireBiometry = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $label)
                } footer: {
                    Text("Shown as the comment in authorized_keys.")
                }
                Section {
                    #if os(macOS)
                    Toggle("Require Touch ID or password", isOn: $requireBiometry)
                    #else
                    Toggle("Require Face ID", isOn: $requireBiometry)
                    #endif
                } footer: {
                    if keys.hasSecureEnclave {
                        Text("The private key is created inside the Secure Enclave and can never leave this device. "
                            + "Secure Enclave keys are ECDSA P-256 (ecdsa-sha2-nistp256).")
                    } else {
                        Text("This device has no Secure Enclave (the simulator?). A software key will be stored in the Keychain instead.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("New Key")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if keys.generate(label: label, requireBiometry: requireBiometry && keys.hasSecureEnclave) != nil {
                            dismiss()
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || keys.unavailableReason != nil)
                }
            }
            .alert("Couldn't create key", isPresented: .constant(keys.lastError != nil)) {
                Button("OK") { keys.lastError = nil }
            } message: {
                Text(keys.lastError ?? "")
            }
            .safeAreaInset(edge: .top) {
                if let reason = keys.unavailableReason {
                    Text(reason).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
            }
        }
    }
}

struct ImportKeyView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var label = ""
    @State private var error: String?
    @State private var choosingFile = false
    @State private var found: [DiscoveredKey] = []

    var body: some View {
        NavigationStack {
            Form {
                if !found.isEmpty {
                    Section {
                        ForEach(found) { item in
                            Button {
                                if case .importable = item.status {
                                    error = keys.importFile(item.url)
                                    if error == nil { dismiss() }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("~/.ssh/\(item.name)")
                                    switch item.status {
                                    case .importable(let algorithm, let comment):
                                        Text([algorithm == .ed25519 ? "ed25519" : "ecdsa P-256", comment]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.footnote).foregroundStyle(.secondary)
                                    case .unusable(let reason):
                                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled({ if case .importable = item.status { false } else { true } }())
                        }
                    } header: {
                        Text("Found in ~/.ssh")
                    } footer: {
                        Text("Tap a key to copy it into Bergr's Keychain. The original file stays where it is.")
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .frame(minHeight: 160)
                    Button("Choose File…", systemImage: "doc") { choosingFile = true }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Paste an unencrypted OpenSSH key (ed25519 or ECDSA P-256), or a P-256 PEM key. "
                        + "The key is stored in this device's Keychain only.")
                }
                Section {
                    TextField("Name", text: $label)
                } footer: {
                    Text("Shown as the comment in authorized_keys. Leave empty to use the key's own comment.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Import Key")
            .inlineNavigationTitle()
            .onAppear { found = keys.discoverSSHFolder() }
            #if os(macOS)
            .fileDialogDefaultDirectory(SSHFolder.defaultURL)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        error = keys.importKey(text: text, label: label)
                        if error == nil { dismiss() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || keys.unavailableReason != nil)
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), data.count < 100_000,
                       let string = String(data: data, encoding: .utf8) {
                        text = string
                        error = nil
                    } else {
                        error = "Couldn't read that file as a text key."
                    }
                case .failure(let failure):
                    error = failure.localizedDescription
                }
            }
        }
    }
}

struct KeyDetailView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    let key: SSHKeyInfo
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Text(key.authorizedKeysLine)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Pasteboard.copy(key.authorizedKeysLine)
                    copied = true
                }
                ShareLink(item: key.authorizedKeysLine) {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Public key")
            } footer: {
                Text("Append this line to ~/.ssh/authorized_keys on each machine.")
            }

            Section("Details") {
                LabeledContent("Fingerprint") {
                    Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Stored in", value: key.kind == .secureEnclave ? "Secure Enclave" : "Keychain (this device only)")
                LabeledContent("Face ID", value: key.requiresBiometry ? "Required" : "Not required")
                LabeledContent("Created", value: key.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button("Delete Key", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(key.label)
        .confirmationDialog("Delete “\(key.label)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                keys.delete(key)
                dismiss()
            }
        } message: {
            Text("The private key is deleted from this phone for good. Machines that only trust this key will refuse Bergr.")
        }
    }
}
