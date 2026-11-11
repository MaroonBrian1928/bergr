import HerdrKit
import SwiftUI

/// Effort levels as the agents' pickers name them.
enum EffortName {
    static func display(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": "Extra high"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

/// Changes a running agent's model and effort the way a person would, through the terminal:
/// Claude Code takes `/model <id>` and `/effort <level>`; Codex has only a picker, so this opens
/// it, reads its numbered lists off the screen and moves to the right rows.
@MainActor
enum ModelSwitcher {
    /// nil when it went through; otherwise what went wrong.
    static func apply(agent: ChatAgent, model: TerminalScreenModel, option: ChatFeed.ModelOption,
                      effort: String?) async -> String? {
        var result: String?
        await model.automate { result = await applyKeys(agent: agent, model: model, option: option, effort: effort) }
        return result
    }

    private static func applyKeys(agent: ChatAgent, model: TerminalScreenModel, option: ChatFeed.ModelOption,
                                  effort: String?) async -> String? {
        if model.watching { model.setWatching(false) }
        switch agent {
        case .claude:
            await typeLine("/model \(option.id)", into: model)
            if let effort {
                try? await Task.sleep(for: .milliseconds(500))
                await typeLine("/effort \(effort)", into: model)
            }
            return nil
        case .codex:
            await typeLine("/model", into: model)
            guard let models = await waitForChoices(titled: "Select Model", in: model),
                  let row = models.first(where: { names($0.label, option.name) }) else {
                return await giveUp(model, "Codex's model list didn't show \(option.name). Try again.")
            }
            await pick(row, from: models, in: model)
            model.press(.enter)
            let level = effort ?? option.defaultEffort ?? "medium"
            guard let efforts = await waitForChoices(titled: "Reasoning Level", in: model),
                  let effortRow = efforts.first(where: { names($0.label, EffortName.display(level)) }) else {
                return await giveUp(model, "Codex's effort list didn't show \(EffortName.display(level)).")
            }
            await pick(effortRow, from: efforts, in: model)
            // `s`: for this session only; Enter would make it the default for every session.
            model.type("s")
            return nil
        case .antigravity:
            // A list (no numbers) under "Switch Model" with `>` on the selected row, and effort
            // on a low · medium · high slider moved with ←/→; Enter applies both.
            await typeLine("/model", into: model)
            var rows: [(name: String, selected: Bool)] = []
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                let lines = model.frame.textLines
                guard let top = lines.lastIndex(where: { $0.contains("Switch Model") }) else { continue }
                rows = lines[top...].compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let selected = trimmed.hasPrefix(">")
                    let text = selected ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
                    return models(of: .antigravity).contains(where: { names(text, $0) || text.hasPrefix($0) })
                        ? (text, selected) : nil
                }
                if !rows.isEmpty { break }
            }
            guard let target = rows.firstIndex(where: { $0.name.hasPrefix(option.name) }),
                  let from = rows.firstIndex(where: \.selected) else {
                return await giveUp(model, "Antigravity's model list didn't show \(option.name). Try again.")
            }
            for _ in 0..<abs(target - from) {
                model.press(target > from ? .down : .up)
                try? await Task.sleep(for: .milliseconds(40))
            }
            if let effort, let wanted = AntigravityStatus.levels.firstIndex(of: effort) {
                let now = AntigravityStatus.read(model.frame.textLines)?.effort
                    .flatMap { AntigravityStatus.levels.firstIndex(of: $0) } ?? 1
                for _ in 0..<abs(wanted - now) {
                    model.press(wanted > now ? .right : .left)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            model.press(.enter)
            return nil
        }
    }

    private static func models(of agent: ChatAgent) -> [String] {
        ["Gemini 4 Argon", "Gemini 3.8 Flash", "Claude Opus 5.5", "Claude Sonnet 5.5", "GPT-OSS 120B"]
    }

    /// A row's label starts with the name, followed by nothing or space ("GPT-6-Sol (current)  …").
    private static func names(_ label: String, _ name: String) -> Bool {
        let label = label.lowercased(), name = name.lowercased()
        return label == name || label.hasPrefix(name + " ")
    }

    private static func typeLine(_ text: String, into model: TerminalScreenModel) async {
        model.type(text)
        try? await Task.sleep(for: .milliseconds(150))
        model.press(.enter)
    }

    /// The numbered choices once a screen with that title shows, or nil after about 3 seconds.
    private static func waitForChoices(titled title: String, in model: TerminalScreenModel) async -> [AnswerChoice]? {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            let lines = model.frame.textLines
            guard lines.contains(where: { $0.contains(title) }) else { continue }
            let choices = AnswerParser.choices(in: lines)
            if !choices.isEmpty { return choices }
        }
        return nil
    }

    private static func pick(_ row: AnswerChoice, from choices: [AnswerChoice], in model: TerminalScreenModel) async {
        let steps = AnswerParser.steps(to: row, in: choices)
        for _ in 0..<abs(steps) {
            model.press(steps > 0 ? .down : .up)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func giveUp(_ model: TerminalScreenModel, _ message: String) async -> String {
        model.press(.escape)
        try? await Task.sleep(for: .milliseconds(150))
        model.press(.escape)
        return message
    }
}

/// Permission modes, as each agent names them, and switching between them through the terminal:
/// Claude Code and Antigravity cycle with Shift+Tab (the status line names the current mode);
/// Codex has a `/permissions` picker (its status line names the current one too).
@MainActor
enum PermissionModes {
    static func modes(_ agent: ChatAgent) -> [String] {
        switch agent {
        case .claude: ["Auto", "Manual", "Accept edits", "Plan"]
        case .codex: ["Ask for approval", "Approve for me", "Full Access", "Read Only"]
        case .antigravity: ["Accept edits", "Auto", "Plan", "Default"]
        }
    }

    /// From the screen when its status line is there; else from what the agent's settings say
    /// (`saved`, e.g. Antigravity's "accept-edits"), since after reopening a chat the status
    /// line may not be on screen until the agent redraws.
    static func current(_ agent: ChatAgent, in lines: [String], saved: String? = nil) -> String? {
        if let onScreen = fromScreen(agent, lines) { return onScreen }
        switch saved?.lowercased() {
        case "accept-edits": return "Accept edits"
        case "auto": return "Auto"
        case "plan": return "Plan"
        case "default": return "Default"
        default: return nil
        }
    }

    private static func fromScreen(_ agent: ChatAgent, _ lines: [String]) -> String? {
        for line in lines.reversed() {
            let lower = line.lowercased()
            switch agent {
            case .claude:
                if lower.contains("auto mode on") { return "Auto" }
                if lower.contains("manual mode on") { return "Manual" }
                if lower.contains("accept edits on") { return "Accept edits" }
                if lower.contains("plan mode on") { return "Plan" }
            case .codex:
                guard line.contains(" · ") else { continue }
                if let mode = modes(.codex).first(where: { line.contains($0) }) { return mode }
            case .antigravity:
                // `accept-edits · Gemini 4 Argon · medium`; no mode word means the default mode.
                guard AntigravityStatus.read([line]) != nil else { continue }
                let first = line.split(separator: "·").first.map { $0.split(separator: " ").last.map(String.init) ?? "" } ?? ""
                switch first.lowercased() {
                case "accept-edits": return "Accept edits"
                case "auto": return "Auto"
                case "plan": return "Plan"
                default: return "Default"
                }
            }
        }
        return nil
    }

    /// nil when it went through; otherwise what went wrong.
    static func set(_ mode: String, agent: ChatAgent, model: TerminalScreenModel, saved: String? = nil) async -> String? {
        var result: String?
        await model.automate { result = await setKeys(mode, agent: agent, model: model, saved: saved) }
        return result
    }

    private static func setKeys(_ mode: String, agent: ChatAgent, model: TerminalScreenModel, saved: String?) async -> String? {
        if model.watching { model.setWatching(false) }
        let all = modes(agent)
        guard let target = all.firstIndex(of: mode) else { return nil }
        switch agent {
        case .claude, .antigravity:
            guard let now = current(agent, in: model.frame.textLines, saved: saved).flatMap({ all.firstIndex(of: $0) }) else {
                return "Couldn't tell which permission mode \(agent.displayName) is in. Check the terminal."
            }
            for _ in 0..<((target - now + all.count) % all.count) {
                model.press(.tab, modifiers: .shift)
                try? await Task.sleep(for: .milliseconds(250))
            }
            return nil
        case .codex:
            model.type("/permissions")
            try? await Task.sleep(for: .milliseconds(150))
            model.press(.enter)
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                let lines = model.frame.textLines
                guard lines.contains(where: { $0.contains("Permissions") }) else { continue }
                let choices = AnswerParser.choices(in: lines)
                guard let row = choices.first(where: { $0.label.hasPrefix(mode) }) else { continue }
                let steps = AnswerParser.steps(to: row, in: choices)
                for _ in 0..<abs(steps) {
                    model.press(steps > 0 ? .down : .up)
                    try? await Task.sleep(for: .milliseconds(40))
                }
                model.press(.enter)
                return nil
            }
            model.press(.escape)
            return "Codex didn't show its permissions list. Try again."
        }
    }
}

/// Antigravity records neither model nor effort in its files; its status line says both:
/// `accept-edits · Gemini 4 Argon · medium`.
enum AntigravityStatus {
    static let levels = ["low", "medium", "high"]

    static func read(_ lines: [String]) -> (model: String, effort: String?)? {
        for line in lines.reversed() {
            let parts = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let effort = parts.last.flatMap { levels.contains($0.lowercased()) ? $0.lowercased() : nil }
            let model = effort == nil ? parts[parts.count - 1] : parts[parts.count - 2]
            if model.contains("Gemini") || model.contains("Claude") || model.contains("GPT") { return (model, effort) }
        }
        return nil
    }
}

/// "Select model", like the Claude app: the models with the current one checked, and the effort.
struct ModelSheet: View {
    let models: [ChatFeed.ModelOption]
    let current: ChatFeed.ModelOption?
    let effort: String?
    let apply: (ChatFeed.ModelOption, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(models) { option in
                        Button {
                            // A new model keeps the effort if it has it, else takes its own default.
                            let keep = effort.flatMap { option.efforts.contains($0) ? $0 : nil }
                            apply(option, keep)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(option.name).font(.body)
                                        if let note = option.note {
                                            Text(note)
                                                .font(.caption.weight(.medium))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    if !option.description.isEmpty {
                                        Text(option.description).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if option.id == current?.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option.id == current?.id ? .isSelected : [])
                    }
                }
                if let current, !current.efforts.isEmpty {
                    Section {
                        NavigationLink {
                            List(current.efforts, id: \.self) { level in
                                Button {
                                    apply(current, level)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(EffortName.display(level))
                                        Spacer()
                                        if level == effort {
                                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .navigationTitle("Effort")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            LabeledContent("Effort", value: effort.map(EffortName.display) ?? "Default")
                        }
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
