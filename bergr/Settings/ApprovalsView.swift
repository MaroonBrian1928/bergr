import SwiftUI

/// Settings → Approvals: what Bergr answered to permission prompts, newest first.
struct ApprovalsView: View {
    @State private var entries: [ApprovalEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No answers yet.").foregroundStyle(.secondary)
            }
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.answer).font(.headline)
                        if entry.dangerous {
                            Label("Dangerous", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.red)
                        }
                        Spacer()
                        Text(entry.date, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.question).font(.footnote).lineLimit(4)
                    Text([entry.agent, entry.machine, entry.source.rawValue].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Approvals")
        .onAppear { entries = ApprovalLog.load() }
        .toolbar {
            if !entries.isEmpty {
                Button("Clear", role: .destructive) { ApprovalLog.clear(); entries = [] }
            }
        }
    }
}
