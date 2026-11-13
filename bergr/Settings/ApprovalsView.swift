import SwiftUI

/// Settings → Approvals: "always allow" rules, suggestions for new ones, and what Bergr answered to
/// permission prompts, newest first.
struct ApprovalsView: View {
    @State private var entries: [ApprovalEntry] = []
    private var store = ApprovalRuleStore.shared

    var body: some View {
        List {
            let suggestions = ApprovalRuleMatcher.suggestions(entries, rules: store.rules)
            if !suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("You approved `\(s.command)` \(s.count) times — always allow?")
                                .font(.footnote)
                            Text([s.scope.machineName, s.scope.cwd].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Always allow") {
                                store.add(scope: s.scope, command: s.command, prefix: false)
                            }
                            .font(.footnote.weight(.semibold))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                if store.rules.isEmpty {
                    Text("No rules. After you approve a command, Bergr offers to always allow it in that folder.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.prefix ? "`\(rule.command)` and longer" : "`\(rule.command)`")
                            .font(.callout.monospaced())
                        Text([machineName(rule.machine), rule.cwd, rule.agent].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.remove(store.rules[i].id) }
                }
            } header: {
                Text("Always allowed")
            } footer: {
                Text("The machine answers Yes to these by itself, even with Bergr closed. Never for dangerous commands or commands with ; & | $ ` > <.")
            }
            Section("Answers") {
                if entries.isEmpty {
                    Text("No answers yet.").foregroundStyle(.secondary)
                }
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.answer).font(.headline)
                            if entry.source == .rule {
                                Label("Auto", systemImage: "bolt.badge.checkmark")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                            }
                            if entry.dangerous {
                                Label("Dangerous", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
                            }
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.question).font(.footnote).lineLimit(4)
                        Text([entry.agent, entry.machine, entry.source == .rule ? "always-allow rule" : entry.source.rawValue]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
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

    private func machineName(_ id: String) -> String {
        entries.last { $0.hostID == id }?.machine ?? ""
    }
}
