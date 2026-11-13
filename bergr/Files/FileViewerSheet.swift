import SwiftUI

/// A read-only look at a file on the agent's machine, scrolled to the line the agent named.
struct FileViewerSheet: View {
    let ref: FileRef
    let cwd: String
    /// Fills the reply field with the path (nil hides the button).
    var onAsk: ((String) -> Void)?
    @State private var state: Phase = .loading
    @Environment(\.dismiss) private var dismiss
    private let loader: FileLoader

    enum Phase: Equatable { case loading, loaded(FileLoader.Result) }

    init(ref: FileRef, cwd: String, session: HostSession?, onAsk: ((String) -> Void)? = nil) {
        self.ref = ref
        self.cwd = cwd
        self.onAsk = onAsk
        loader = FileLoader(windows: session?.isWindowsHost == true) { [weak session] command in
            guard let session else { throw CocoaError(.fileNoSuchFile) }
            return try await session.commandOutput(command)
        }
    }

    private var fullPath: String {
        FilePathDetector.resolve(ref.path, cwd: cwd, windows: loader.windows)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(.notFound):
                    ContentUnavailableView("File not found", systemImage: "doc.questionmark", description: Text(fullPath))
                case .loaded(.binary):
                    ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text(fullPath))
                case .loaded(.failed(let message)):
                    ContentUnavailableView("Couldn't read the file", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                case .loaded(.text(let lines, let truncated)):
                    FileLinesView(lines: lines, truncated: truncated, highlight: ref.line)
                }
            }
            .navigationTitle((ref.path as NSString).lastPathComponent)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .automatic) {
                    Button("Copy path", systemImage: "doc.on.doc") { Pasteboard.copy(fullPath) }
                    #if os(iOS)
                    ShareLink(item: fullPath)
                    #endif
                    if let onAsk {
                        Button("Ask agent about this file", systemImage: "text.bubble") {
                            onAsk(fullPath)
                            dismiss()
                        }
                    }
                }
            }
        }
        .task { state = .loaded(await loader.load(ref, cwd: cwd)) }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
}

/// The file's lines, monospaced with line numbers like the diff view, the named line highlighted.
private struct FileLinesView: View {
    let lines: [String]
    let truncated: Bool
    let highlight: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if truncated {
                        Text("Too large, showing first \(FileLoader.lineCap) lines")
                            .font(.footnote).foregroundStyle(.secondary).padding(8)
                    }
                    if lines.isEmpty { Text("Empty file").foregroundStyle(.secondary).padding() }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, text in
                        row(number: i + 1, text: text).id(i + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard let highlight, highlight >= 1 else { return }
                proxy.scrollTo(min(highlight, max(lines.count, 1)), anchor: .center)
            }
        }
    }

    private func row(number: Int, text: String) -> some View {
        let hit = number == highlight
        let width = String(max(lines.count, 1)).count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(number))
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(width) * 8 + 4, alignment: .trailing)
            Text(text.isEmpty ? " " : text)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .background(hit ? Color.yellow.opacity(0.25) : .clear)
    }
}
