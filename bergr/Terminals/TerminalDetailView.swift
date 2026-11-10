// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import HerdrKit
import SwiftUI

/// Everything known about one terminal, live: shown as the info popover, or
/// in place of the screen once the terminal has finished.
struct TerminalDetailView: View {
    let session: HostSession
    let address: String

    var body: some View {
        if let terminal = session.terminal(address) {
            List {
                Section {
                    HStack(spacing: 12) {
                        StatusDot(state: terminal.isLive ? terminal.status?.state : "finished")
                        VStack(alignment: .leading) {
                            Text(statusTitle(terminal)).font(.headline)
                            if let message = statusMessage(terminal) {
                                Text(message).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if let progress = terminal.status?.progress, terminal.isLive {
                        ProgressView(value: Double(min(progress, 100)), total: 100)
                    }
                }

                Section("Terminal") {
                    LabeledContent("Address", value: terminal.address)
                    if let title = terminal.title, !title.isEmpty {
                        LabeledContent("Title", value: title)
                    }
                    if let foreground = terminal.foreground {
                        LabeledContent("Running", value: foreground.argv.joined(separator: " "))
                        LabeledContent("Folder", value: Terminal.abbreviate(foreground.cwd))
                    } else {
                        LabeledContent("Folder", value: Terminal.abbreviate(terminal.cwd))
                    }
                    LabeledContent("Started as", value: terminal.argv.joined(separator: " "))
                    LabeledContent("Size", value: "\(terminal.cols) × \(terminal.rows)")
                    if terminal.createdMs > 0 {
                        LabeledContent("Started") {
                            Text(Date(timeIntervalSince1970: Double(terminal.createdMs) / 1000), style: .relative)
                                + Text(" ago")
                        }
                    }
                    if let parent = terminal.parent {
                        LabeledContent("Started by", value: parent)
                    }
                }

                if !terminal.labels.isEmpty {
                    Section("Labels") {
                        ForEach(terminal.labels.sorted(by: { $0.key < $1.key }), id: \.key) { label in
                            LabeledContent(label.key, value: label.value)
                        }
                    }
                }

            }
            .navigationTitle(terminal.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .textSelection(.enabled)
        } else {
            ContentUnavailableView(
                "Terminal is gone", systemImage: "xmark.circle",
                description: Text("\(address) was removed on the machine."))
        }
    }

    private func statusTitle(_ terminal: Terminal) -> String {
        guard terminal.isLive else {
            return terminal.exitCode.map { "Finished · exit \($0)" } ?? "Finished (\(terminal.reason ?? "ended"))"
        }
        guard let status = terminal.status else { return "No status reported" }
        switch status.state {
        case "blocked": return status.kind.map { "Needs you · \($0)" } ?? "Needs you"
        default: return terminal.agentState?.title ?? status.state.capitalized
        }
    }

    private func statusMessage(_ terminal: Terminal) -> String? {
        guard terminal.isLive, let status = terminal.status else { return nil }
        let parts = [status.app, status.title, status.msg].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
