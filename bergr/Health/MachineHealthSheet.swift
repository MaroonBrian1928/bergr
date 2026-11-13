import SwiftUI

/// What a machine's health line opens: the current numbers and its busiest processes, read when the
/// sheet opens. Nothing is stored.
struct MachineHealthSheet: View {
    let health: MachineHealth?
    let failure: String?
    let source: any MachineHealthSource
    @Environment(\.dismiss) private var dismiss
    @State private var processes: [MachineProcess]?
    @State private var processError: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if let health {
                    Section("Now") {
                        ForEach(Array(health.parts.enumerated()), id: \.offset) { _, part in
                            Text(part.text).foregroundStyle(part.warning ? Color.orange : Color.primary)
                        }
                    }
                } else {
                    Section("Health unavailable") {
                        Text(failure ?? "No reading yet.").foregroundStyle(.secondary)
                    }
                }
                Section("Busiest processes") {
                    if loading {
                        ProgressView()
                    } else if let processes, !processes.isEmpty {
                        ForEach(processes) { process in
                            HStack {
                                Text(process.name).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f%% cpu · %.1f%% mem", process.cpu, process.memory))
                                    .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    } else if let processError {
                        Text(processError).foregroundStyle(.secondary)
                    } else {
                        Text(source.isWindowsMachine ? "Not available on Windows." : "No processes listed.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(source.healthName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
        .task {
            do { processes = try await MachineHealthMonitor.shared.topProcesses(source) }
            catch { processError = error.localizedDescription }
            loading = false
        }
    }
}
