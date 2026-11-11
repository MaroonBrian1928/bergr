import HerdrKit
import SwiftUI

/// The chat window's right-hand inspector: where the agent runs, its model, how full its context is,
/// the plan limits, the files it wrote, and its sub-agents. All of it read from the live feed.
struct ChatInspector: View {
    let feed: ChatFeed
    let agent: ChatAgent
    let terminal: Terminal?
    let machine: String

    var body: some View {
        Form {
            Section("Environment") {
                row("desktopcomputer", machine)
                if let cwd = terminal?.cwd { row("folder", Self.abbreviate(cwd)) }
                row("circle.fill", agent.displayName, trailing: stateText, tint: stateColor)
            }
            if let model = feed.usage?.model {
                Section("Model") {
                    row("sparkle", feed.models.first { $0.id == model }?.name ?? Self.modelName(model),
                        trailing: feed.chosenEffort ?? feed.usage?.effort)
                }
            }
            if let usage = feed.usage, let fraction = usage.fraction {
                Section("Context") {
                    meter("\(Self.tokens(usage.used)) of \(Self.tokens(usage.limit ?? 0))", fraction: fraction, tint: .blue)
                }
            }
            if let usage = feed.usage, usage.session != nil || usage.weekly != nil {
                Section("Usage") {
                    if let window = usage.session { limit("Current session", window) }
                    if let window = usage.weekly { limit("Weekly", window) }
                }
            }
            Section("Outputs") {
                let files = outputs
                if files.isEmpty {
                    Text("No files written yet").foregroundStyle(.secondary)
                } else {
                    ForEach(files, id: \.self) { path in
                        row("doc", (path as NSString).lastPathComponent)
                            .help(path)
                    }
                }
            }
            Section("Activity") {
                let running = feed.subagents.filter { $0.state == .running }
                if running.isEmpty {
                    Text("No sub-agents running").foregroundStyle(.secondary)
                } else {
                    ForEach(running) { sub in row("person.2", sub.name, trailing: "\(sub.steps) steps") }
                }
                row("hammer", "\(toolCalls) tool calls")
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
    }

    // MARK: Data

    private var stateText: String {
        switch terminal?.status?.state {
        case "working": "working"
        case "blocked": "needs you"
        case "done": "done"
        case "error": "error"
        default: "idle"
        }
    }

    private var stateColor: Color {
        switch terminal?.status?.state {
        case "working": .blue
        case "blocked", "error": .orange
        case "done": .green
        default: .secondary
        }
    }

    private var toolCalls: Int {
        feed.items.reduce(0) { count, item in if case .tool = item.kind { count + 1 } else { count } }
    }

    /// Files the agent wrote or edited, newest first, each once.
    private var outputs: [String] {
        let writers: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch", "write_file", "edit_file"]
        var seen = Set<String>()
        var files: [String] = []
        for item in feed.items.reversed() {
            guard case .tool(let name, let summary) = item.kind, writers.contains(name) else { continue }
            let path = summary.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !path.isEmpty, path.contains("/") || path.contains("."), seen.insert(path).inserted else { continue }
            files.append(path)
            if files.count == 8 { break }
        }
        return files
    }

    /// "claude-opus-5-5" → "Opus 5.5"; anything else as given.
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let name = parts.first, parts.count > 1, parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return id }
        return name.capitalized + " " + parts.dropFirst().joined(separator: ".")
    }

    static func abbreviate(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { return "~" + rest[slash...] }
            return "~"
        }
        return path
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1000 ? "\(n / 1000)K" : "\(n)"
    }

    // MARK: Rows

    private func row(_ symbol: String, _ title: String, trailing: String? = nil, tint: Color = .secondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func meter(_ title: String, fraction: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: fraction).tint(tint)
        }
    }

    private func limit(_ title: String, _ window: ChatFeed.Usage.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            meter(title, fraction: min(1, window.percent / 100), tint: .green)
            if let reset = window.resetsAt {
                Text("Resets \(reset, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
