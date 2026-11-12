#if os(macOS)
import Foundation
import SSHTransport
import SwiftUI

/// Lists the Host entries of this Mac's `~/.ssh/config`; one tap adds a machine that uses this
/// Mac's SSH. Entries already added are shown as such.
struct SSHConfigImportView: View {
    /// Called after a machine is added, so the editor it came from can close too.
    var onAdded: () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SSHConfigEntry] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    ContentUnavailableView("Can't read ~/.ssh/config", systemImage: "doc.questionmark",
                                           description: Text(loadError))
                } else if entries.isEmpty {
                    ContentUnavailableView("No machines in ~/.ssh/config", systemImage: "server.rack",
                                           description: Text("Add a Host entry there, or add a machine by hand."))
                } else {
                    Section {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    } footer: {
                        Text("Each entry signs in through this Mac's SSH, with its HostName, User and Port. Tap one to add it.")
                    }
                }
            }
            .navigationTitle("From SSH Config")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func entryRow(_ entry: SSHConfigEntry) -> some View {
        let added = hosts.hosts.contains { $0.name == entry.alias || $0.target.host == (entry.hostName ?? entry.alias) }
        return Button {
            hosts.save(Host.imported(entry, localUser: NSUserName()))
            onAdded()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.alias).font(.headline)
                    Text(SSHConfig.summary(entry))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if added {
                    Text("Added").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.circle").foregroundStyle(.tint)
                }
            }
            .frame(minHeight: PlatformMetrics.controlHeight)
        }
        .foregroundStyle(.primary)
        .disabled(added)
    }

    private func load() {
        guard entries.isEmpty, loadError == nil else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
        do {
            entries = SSHConfig.entries(try String(contentsOf: url, encoding: .utf8))
        } catch {
            loadError = "There is no readable file at ~/.ssh/config (\(error.localizedDescription))."
        }
    }
}
#endif
