import HerdrKit
import SwiftUI

struct KeysView: View {
    @Environment(KeyLibrary.self) private var keys
    @State private var creating = false

    var body: some View {
        List {
            if keys.keys.isEmpty {
                ContentUnavailableView {
                    Label("No keys", systemImage: "key")
                } description: {
                    Text("Create a key, then add its public key to ~/.ssh/authorized_keys on your machines.")
                } actions: {
                    Button("Create Key") { creating = true }
                }
            }
            ForEach(keys.keys) { key in
                NavigationLink(value: key) {
                    KeyRow(key: key)
                }
            }
            .onDelete { offsets in
                offsets.map { keys.keys[$0] }.forEach(keys.delete)
            }
        }
        .navigationTitle("Keys")
        .navigationDestination(for: SSHKeyInfo.self) { KeyDetailView(key: $0) }
        .toolbar {
            Button("New Key", systemImage: "plus") { creating = true }
        }
        .sheet(isPresented: $creating) { NewKeyView() }
    }
}

struct KeyRow: View {
    let key: SSHKeyInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(key.label)
                if key.requiresBiometry {
                    Image(systemName: "faceid").foregroundStyle(.secondary)
                }
            }
            Text(key.kind == .secureEnclave ? "Secure Enclave" : "Software key (no Secure Enclave)")
                .font(.caption)
                .foregroundStyle(key.kind == .secureEnclave ? Color.secondary : Color.orange)
        }
    }
}

struct NewKeyView: View {
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    @State private var label = UIDevice.current.name
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
                    Toggle("Require Face ID", isOn: $requireBiometry)
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
            .navigationBarTitleDisplayMode(.inline)
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
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Could not create key", isPresented: .constant(keys.lastError != nil)) {
                Button("OK") { keys.lastError = nil }
            } message: {
                Text(keys.lastError ?? "")
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
                    UIPasteboard.general.string = key.authorizedKeysLine
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
                LabeledContent("Stored in", value: key.kind == .secureEnclave ? "Secure Enclave" : "Keychain")
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
            Text("The private key is destroyed. Machines that only trust this key will lock you out.")
        }
    }
}
