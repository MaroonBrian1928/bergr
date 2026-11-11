import SwiftUI

extension ChatFeed.Usage {
    /// `claude-opus-5-5` → "Opus 5.5"; other names as they are.
    var modelName: String? {
        guard let model else { return nil }
        if model.hasPrefix("gpt-") {
            // gpt-6.1-sol → GPT-6.1 Sol
            let parts = model.dropFirst("gpt-".count).split(separator: "-").map(String.init)
            guard let version = parts.first else { return model }
            return (["GPT-" + version] + parts.dropFirst().map(\.capitalized)).joined(separator: " ")
        }
        guard model.hasPrefix("claude-") else { return model }
        var parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() } // a date
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

/// How full the context is, as a small ring for the title bar.
struct UsageRing: View {
    let fraction: Double
    let palette: ChatPalette

    private var tint: Color { fraction >= 0.85 ? .red : fraction >= 0.6 ? .orange : .blue }

    var body: some View {
        ZStack {
            Circle().stroke(palette.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent used")
    }
}

/// Context and plan usage, like the Claude app's Usage sheet.
struct UsageSheet: View {
    /// Nil when the agent's files have no numbers yet (Claude without the status line).
    let usage: ChatFeed.Usage?
    let agent: ChatAgent
    /// The machine's name, and the setup run on it over the app's own connection.
    var machine: String? = nil
    var setUp: (() async throws -> [String])? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var setupState: SetupState = .idle
    enum SetupState: Equatable { case idle, running, done([String]), failed(String) }

    /// Claude saves its context window and plan limits only through a status line that writes
    /// them down; without it the sheet offers to have Claude set that up on the machine.
    private var needsSetup: Bool {
        agent == .claude && (usage?.session == nil && usage?.weekly == nil || usage?.limit == nil)
    }

    var body: some View {
        NavigationStack {
            List {
                if let usage, usage.used > 0 || usage.limit != nil { Section("Context") {
                    meter(title: "Context window", fraction: usage.fraction ?? 0,
                          detail: usage.limit.map { "\(Self.tokens(usage.used)) of \(Self.tokens($0)) tokens" }
                            ?? "\(Self.tokens(usage.used)) tokens")
                } }
                if let usage, usage.session != nil || usage.weekly != nil {
                    Section("Plan usage") {
                        if let session = usage.session { window("Current session", session) }
                        if let weekly = usage.weekly { window("Weekly", weekly) }
                    }
                } else if needsSetup {
                    setupSection
                } else {
                    Section("Plan usage") {
                        Text("\(agent.displayName) doesn't save its plan usage on the machine. The \(agent.displayName) app shows it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let usage, let name = usage.modelName {
                    Section("Model") {
                        LabeledContent("Model", value: name)
                        if let effort = usage.effort { LabeledContent("Effort", value: effort.capitalized) }
                    }
                }
            }
            .navigationTitle("Usage")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 520)
        #else
        .presentationDetents([.medium, .large])
        #endif
        // Solid, so the conversation behind doesn't show through and dim the numbers.
        .presentationBackground(Color.groupedBackground)
    }

    private var setupSection: some View {
        Section {
            switch setupState {
            case .done(let lines):
                Label("Set up. Usage shows after Claude's next reply.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ForEach(lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            default:
                if let setUp {
                    Button {
                        setupState = .running
                        Task {
                            do { setupState = .done(try await setUp()) } catch {
                                setupState = .failed(error.localizedDescription)
                            }
                        }
                    } label: {
                        HStack {
                            Label("Set Up on \(machine ?? "This Machine")", systemImage: "wrench.and.screwdriver")
                            Spacer()
                            if setupState == .running { ProgressView() }
                        }
                    }
                    .disabled(setupState == .running)
                }
                if case .failed(let message) = setupState {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                }
                Button(copied ? "Copied" : "Copy Setup Prompt", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Pasteboard.copy(UsageSetup.prompt)
                    copied = true
                }
            }
        } header: {
            Text("Plan usage")
        } footer: {
            if case .done = setupState { EmptyView() } else {
                Text("Claude Code only shares its context size and plan limits with a status line. "
                    + "Setting up saves a small one in ~/.claude and adds it to settings.json, keeping any status "
                    + "line you have and the rest of the file as it is (a backup is kept). Or copy a prompt for Claude.")
            }
        }
    }

    private func meter(title: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))% used").foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: fraction)
                .tint(fraction >= 0.85 ? .red : .blue)
            Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func window(_ title: String, _ window: ChatFeed.Usage.Window) -> some View {
        meter(title: title, fraction: window.percent / 100,
              detail: window.resetsAt.map { "Resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? "")
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? (Double(n) / 1000).formatted(.number.precision(.fractionLength(n >= 100_000 ? 0 : 1))) + "K" : "\(n)"
    }
}

/// The model and effort in the reply bar; tapping it opens the model sheet where the agent has one.
struct ModelChip: View {
    let usage: ChatFeed.Usage?
    let effort: String?
    let agent: ChatAgent
    let palette: ChatPalette
    let enabled: Bool
    let open: (() -> Void)?

    /// The model and effort as the screen shows them, for agents whose files don't say (Antigravity).
    var shown: (model: String, effort: String?)?
    /// The terminal to read `shown` from (Antigravity), read here so only the chip redraws with it.
    var screen: TerminalScreenModel?
    /// How full the context is (0…1), shown as a small gauge at the front of the chip; nil hides it.
    var context: Double? = nil

    private var label: String {
        // What the screen shows is live; the agent's settings (in `usage`) fill in until it does.
        if let shown = shown ?? screen.flatMap({ AntigravityStatus.read($0.frame.textLines) }) {
            return shown.model + (shown.effort.map { " · " + EffortName.display($0) } ?? "")
        }
        guard let name = usage?.modelName else { return agent.displayName }
        return name + ((usage?.effort ?? effort).map { " · " + EffortName.display($0) } ?? "")
    }

    var body: some View {
        if let open {
            Button(action: open) { chip(chevron: true) }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel("Model: \(label)")
                .accessibilityHint("Changes the model and effort")
        } else {
            chip(chevron: false).accessibilityLabel("Model: \(label)")
        }
    }

    private func chip(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            if let context {
                UsageRing(fraction: context, palette: palette)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Context \(Int((context * 100).rounded())) percent full")
            }
            Text(label).lineLimit(1)
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(palette.text.opacity(0.8))
        .contentTransition(.interpolate)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        // The agent's name gives way to its model once the helper reads it: grow, don't snap.
        .animation(.smooth(duration: 0.3), value: label)
        .background(palette.bubble, in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Capsule())
    }
}

/// The prompt that has Claude install Bergr's status line on its machine.
enum UsageSetup {
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "statusline-herdr", withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    static var prompt: String {
        """
        Please set up a Claude Code status line on this machine so the Bergr app can show my context and plan usage.

        1. Save this script as ~/.claude/statusline-herdr.py:

        ```python
        \(script.trimmingCharacters(in: .whitespacesAndNewlines))
        ```

        2. In ~/.claude/settings.json, set "statusLine" to {"type": "command", "command": "python3 ~/.claude/statusline-herdr.py"}. \
        If a statusLine is already set, keep it running: write its command to ~/.claude/statusline-herdr.json as \
        {"chain": "<that command>"} (the script runs it and shows its output).

        3. Check it: pipe a sample JSON with session_id, context_window.context_window_size and rate_limits into the \
        script, and confirm ~/.cache/herdr-chat/claude-limits.json and ~/.cache/herdr-chat/ctx/<session_id>.json appear. \
        Then delete the files the sample made.

        Edit settings.json in place: add or replace only the "statusLine" entry and keep everything else byte for \
        byte (no reformatting, no escaped characters, keep a backup). I'm asking for this change to Claude Code's \
        settings myself; if a permission check blocks it, ask me to approve it instead of stopping.

        Change nothing else, and tell me what you changed.
        """
    }
}
