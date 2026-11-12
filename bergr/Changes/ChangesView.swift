import HerdrKit
import SwiftUI

/// What the agent changed: git status and stat, the last test run, and a diff per file.
struct ChangesSheet: View {
    let items: [ChatFeed.Item]
    let toolOutput: [String: String]
    @State private var model: ChangesModel
    @Environment(\.dismiss) private var dismiss

    init(session: HostSession?, folder: String?, items: [ChatFeed.Item], toolOutput: [String: String]) {
        self.items = items
        self.toolOutput = toolOutput
        _model = State(initialValue: ChangesModel(folder: folder ?? "", lastReply: ChangesSummary.lastReply(in: items)) { [weak session] command in
            guard let session else { throw CocoaError(.fileNoSuchFile) }
            return try await session.commandOutput(command)
        })
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Reading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .notARepo:
                    ContentUnavailableView("Not a git repository", systemImage: "folder.badge.questionmark",
                                           description: Text(model.folder))
                case .failed(let message):
                    ContentUnavailableView("Couldn't read changes", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                case .loaded:
                    content
                }
            }
            .navigationTitle("Changes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: String.self) { FileDiffView(model: model, path: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .automatic) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                }
            }
        }
        .task { await model.load() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private var content: some View {
        let status = model.status
        let stat = model.stat
        let paths = Set(stat.files.map(\.path))
        return List {
            switch model.summary {
            case .none: EmptyView()
            case .writing:
                Section { Text("Summarising the change…").foregroundStyle(.secondary) }
            case .written(let text):
                Section { Text(text).font(.body) }
            }
            Section("Branch") {
                LabeledContent(status.branch ?? "unknown", value: status.upstream ?? "no upstream")
                if status.ahead > 0 || status.behind > 0 {
                    Text("\(status.ahead) ahead, \(status.behind) behind").foregroundStyle(.secondary)
                }
                if status.noCommits { Text("No commits yet").foregroundStyle(.secondary) }
            }
            Section {
                if stat.files.isEmpty && status.untrackedCount == 0 {
                    Text("No changes").foregroundStyle(.secondary)
                }
                ForEach(stat.files) { file in
                    NavigationLink(value: file.path) {
                        HStack {
                            Text(file.path).font(.system(.callout, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if file.binary { Text("binary").foregroundStyle(.secondary) } else {
                                Text("+\(file.plus)").foregroundStyle(.green)
                                Text("-\(file.minus)").foregroundStyle(.red)
                            }
                        }
                    }
                }
                // Changes the stat doesn't list (a rename without edits, a staged new file).
                ForEach(status.trackedChanges.filter { !paths.contains($0.path) }) { entry in
                    HStack {
                        Text(entry.path).font(.system(.callout, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(entry.label).foregroundStyle(.secondary).font(.caption)
                    }
                }
                if status.untrackedCount > 0 {
                    Label("\(status.untrackedCount) untracked", systemImage: "questionmark.folder").foregroundStyle(.secondary)
                }
            } header: {
                Text("Files" + (stat.files.isEmpty ? "" : "  +\(stat.insertions) -\(stat.deletions)"))
            }
            if let run = TestRun.last(in: items, output: toolOutput) {
                Section("Last test run") {
                    Label {
                        Text(run.command).font(.system(.callout, design: .monospaced))
                    } icon: {
                        switch run.verdict {
                        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        }
                    }
                    Text(run.verdict == .passed ? "Looks passed" : run.verdict == .failed ? "Looks failed" : "Result unclear")
                        .font(.caption).foregroundStyle(.secondary)
                    if !run.output.isEmpty {
                        Text(run.output).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct FileDiffView: View {
    let model: ChangesModel
    let path: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.diffs[path] {
                case .loaded(let diff):
                    if diff.isBinary { Text("Binary file").foregroundStyle(.secondary).padding() }
                    else if diff.hunks.isEmpty { Text("No textual changes").foregroundStyle(.secondary).padding() }
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        line(hunk.header, .hunk)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, l in line(l.text, l.kind) }
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary).padding()
                default:
                    ProgressView().padding()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle((path as NSString).lastPathComponent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.loadDiff(path) }
    }

    private func line(_ text: String, _ kind: GitParsing.DiffLine.Kind) -> some View {
        let (fg, bg): (Color, Color) = switch kind {
        case .add: (.green, .green.opacity(0.14))
        case .del: (.red, .red.opacity(0.14))
        case .hunk: (.blue, .blue.opacity(0.1))
        case .meta: (.secondary, .clear)
        case .context: (.primary, .clear)
        }
        return Text(text.isEmpty ? " " : text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(fg)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(bg)
    }
}
