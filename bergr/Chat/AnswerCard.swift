import HerdrKit
import SwiftUI

struct AnswerChoice: Equatable, Sendable {
    let number: Int
    let label: String
    let selected: Bool
    /// The option's description on the lines under it (Claude's questions), if any.
    var detail: String = ""
}

enum AnswerParser {
    /// Claude Code signed out on the machine ("Login expired · Please run /login",
    /// "Not logged in · Run /login"): herdr-core reports it as blocked, but there's no question.
    static func needsLogin(in lines: [String]) -> Bool {
        lines.contains { $0.contains("run /login") || $0.contains("Run /login") }
    }

    /// Where Claude Code's /login is, from its screen (it shows a method menu first, which the
    /// numbered-choice card answers).
    enum LoginStep: Equatable {
        /// The sign-in link is up and Claude waits for the code from the browser.
        case pasteCode(url: URL?)
        /// Signed in; Enter continues.
        case succeeded
    }

    static func loginStep(in lines: [String]) -> LoginStep? {
        // Only what's at the bottom counts: once Claude is back at its prompt, "Login successful"
        // stays visible higher up for a while and must not keep the card up.
        let filled = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = Array(filled.suffix(6))
        if tail.contains(where: { $0.contains("Press Enter to continue") || $0.contains("Login successful") }) {
            return .succeeded
        }
        guard tail.contains(where: { $0.localizedCaseInsensitiveContains("paste code") }) else { return nil }
        return .pasteCode(url: signInURL(in: Array(filled.suffix(30))))
    }

    /// The sign-in URL, joined back together where the terminal wrapped it over several rows.
    static func signInURL(in lines: [String]) -> URL? {
        guard let start = lines.firstIndex(where: { $0.contains("https://") }) else { return nil }
        var text = String(lines[start][lines[start].range(of: "https://")!.lowerBound...])
            .trimmingCharacters(in: .whitespaces)
        for line in lines[(start + 1)...] {
            let part = line.trimmingCharacters(in: .whitespaces)
            if part.isEmpty || part.contains(" ") || part.lowercased().hasPrefix("paste") { break }
            text += part
        }
        return URL(string: text)
    }

    /// /login is on screen (its method menu, the code prompt or the success note), whatever
    /// herdr-core says the agent's state is.
    static func inLogin(_ lines: [String]) -> Bool {
        if loginStep(in: lines) != nil || rewindOpen(lines) { return true }
        // The cheap text check first: this runs on every terminal redraw, and parsing choices
        // across the whole screen each keystroke made typing lag.
        let recent = Array(lines.suffix(30))
        return recent.contains { $0.localizedCaseInsensitiveContains("login method") } && !choices(in: recent).isEmpty
    }

    /// Claude's Rewind menu (Esc twice) is open: "Rewind" … "Esc to cancel".
    static func rewindOpen(_ lines: [String]) -> Bool {
        let recent = lines.suffix(20).map { $0.trimmingCharacters(in: .whitespaces) }
        return recent.contains("Rewind") && recent.contains { $0.hasPrefix("Esc to cancel") }
    }

    private static let menuFooters = ["esc to close", "esc to cancel", "esc to go back", "esc back", "esc exit"]

    /// A slash-command menu (/model, /resume, /mcp, /config, /permissions ...) is open: one of its
    /// footers is in the last few non-empty lines. A cheap text check, run on every redraw.
    static func menuOpen(_ lines: [String]) -> Bool { menuFooterIndex(lines) != nil }

    private static func menuFooterIndex(_ lines: [String]) -> Int? {
        var seen = 0
        var i = lines.count - 1
        // Only the bottom two lines: a menu's footer is its last line (Claude may print a hint
        // line under it); anything higher is the agent's own output.
        while i >= 0, seen < 2 {
            let line = lines[i]
            if !line.allSatisfy(\.isWhitespace) {
                seen += 1
                if menuFooters.contains(where: { line.localizedCaseInsensitiveContains($0) }) { return i }
            }
            i -= 1
        }
        return nil
    }

    /// The open menu's title: the first line of the block (up to the previous blank line) above its footer.
    static func menuTitle(_ lines: [String]) -> String? {
        guard let footer = menuFooterIndex(lines) else { return nil }
        var title: String?
        var i = footer - 1
        var n = 0
        while i >= 0, n < 12 {
            let line = clean(lines[i])
            if line.isEmpty { if title != nil { break } } else { title = line; n += 1 }
            i -= 1
        }
        return title
    }

    /// Whether the screen asks something Yes/No/numbered buttons can answer.
    static func isAsking(_ lines: [String]) -> Bool {
        if !choices(in: lines).isEmpty { return true }
        if needsLogin(in: lines) || loginStep(in: lines) != nil || rewindOpen(lines) { return false }
        return lines.contains { $0.contains("?") }
    }

    private static let borders: Set<Character> = Set("│┃║╭╮╰╯┌┐└┘─━═┆┊╎|")
    private static let markers: Set<Character> = Set("❯›>▶►→➤▸")

    /// A line without box-drawing borders or surrounding spaces.
    static func clean(_ line: String) -> String {
        var chars = Substring(line)
        while let f = chars.first, f.isWhitespace || borders.contains(f) { chars = chars.dropFirst() }
        while let l = chars.last, l.isWhitespace || borders.contains(l) { chars = chars.dropLast() }
        return String(chars)
    }

    private static func choice(_ line: String) -> AnswerChoice? {
        var text = Substring(clean(line))
        var selected = false
        if let f = text.first, markers.contains(f) {
            selected = true
            text = text.dropFirst().drop { $0.isWhitespace }
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let n = Int(digits) else { return nil }
        let rest = text.dropFirst(digits.count)
        guard rest.first == ".", rest.dropFirst().first?.isWhitespace == true else { return nil }
        let label = clean(String(rest.dropFirst()))
        guard !label.isEmpty else { return nil }
        return AnswerChoice(number: n, label: label, selected: selected)
    }

    private static func run(in lines: [String]) -> (start: Int, choices: [AnswerChoice])? {
        guard let bottom = lines.lastIndex(where: { choice($0) != nil }) else { return cursorMenu(in: lines) }
        var found: [AnswerChoice] = []
        var start = bottom
        var i = bottom
        // Lines between two choices continue the one above them: a long option wraps on a
        // narrow terminal ("2. Yes, and always allow … for" / "commands that start with 'ls'").
        // Lines indented to the label's column or deeper are the option's description instead
        // ("❯ 1. Relay to GitHub (Recommended)" / "     The relay files each report…").
        var wrapped: [(text: String, indent: Int)] = []
        // The last option's own continuation lines sit below it, up to a blank line or a rule.
        // Only its description (aligned with the label or deeper), never the prompt's key hints.
        let lastColumn = labelColumn(lines[bottom])
        var k = bottom + 1
        while k < lines.count, wrapped.count < 12 {
            let text = clean(lines[k])
            let indent = lines[k].prefix { $0 == " " || borders.contains($0) }.count
            guard !text.isEmpty, !isRule(lines[k]), indent >= lastColumn, choice(lines[k]) == nil,
                  !isKeyHint(text) else { break }
            wrapped.insert((text, indent), at: 0)
            k += 1
        }
        while i >= 0 {
            if let c = choice(lines[i]) {
                guard found.isEmpty || c.number == found[0].number - 1 else { break }
                let column = labelColumn(lines[i])
                let below = wrapped.reversed()
                let label = ([c.label] + below.filter { $0.indent < column }.map(\.text)).joined(separator: " ")
                let detail = below.filter { $0.indent >= column }.map(\.text).joined(separator: " ")
                found.insert(AnswerChoice(number: c.number, label: label, selected: c.selected, detail: detail), at: 0)
                wrapped = []
                start = i
                if c.number == 1 { break }
            } else {
                let text = clean(lines[i])
                // A rule inside the menu (Claude's questions put one above "4. Chat about this")
                // separates options; it doesn't end the list.
                if !found.isEmpty, text.isEmpty, wrapped.isEmpty,
                   lines[i].contains(where: { $0 == "─" || $0 == "━" }) {
                    i -= 1
                    continue
                }
                guard !found.isEmpty, !text.isEmpty, wrapped.count < 12 else { break }
                wrapped.append((text, lines[i].prefix { $0 == " " || borders.contains($0) }.count))
            }
            i -= 1
        }
        guard found.first?.number == 1 else { return nil }
        return (start, found)
    }

    /// Where a numbered option's label starts on its line ("❯ 1. Yes" → 5).
    private static func labelColumn(_ line: String) -> Int {
        guard let dot = line.firstIndex(of: ".") else { return 0 }
        let after = line[line.index(after: dot)...].prefix { $0 == " " }.count
        return line.distance(from: line.startIndex, to: dot) + 1 + after
    }

    /// The question's lines above the choices: a long question wraps on a narrow terminal
    /// ("Second Wind's app icon (page just opened): which" / "one ships?"), so it runs up to a
    /// blank line or a rule, at most three lines. `first` is its top line's index.
    private static func questionLines(in lines: [String]) -> (first: Int, text: [String])? {
        guard let start = run(in: lines)?.start else { return nil }
        var j = start - 1
        while j >= 0, clean(lines[j]).isEmpty, !isRule(lines[j]) { j -= 1 }
        var out: [String] = []
        while j >= 0, out.count < 3 {
            let text = clean(lines[j])
            if text.isEmpty || isRule(lines[j]) { break }
            out.insert(text, at: 0)
            j -= 1
        }
        return out.isEmpty ? nil : (j + 1, out)
    }

    /// A prompt's footer of key hints ("Enter to select · ↑/↓ to navigate · Esc to cancel"):
    /// hints joined by "·", or a line that starts with one. Not a description that mentions a key.
    private static func isKeyHint(_ text: String) -> Bool {
        let t = text.lowercased()
        let hint = ["esc to", "enter to", "↑/↓", "tab to", "ctrl+"]
        if t.contains("·") { return hint.contains { t.contains($0) } }
        return hint.contains { t.hasPrefix($0) }
    }

    private static func isRule(_ line: String) -> Bool { line.contains("──") || line.contains("━━") }

    /// A menu without numbers, picked with the arrow keys ("❯ Deny, and tell Claude what to do
    /// differently (esc)" / "  Allow for this session"): the line with the cursor and the options
    /// aligned with its label, above and below, up to a blank line. Numbered in order, so the card
    /// answers it like any other (arrows to the option, then Return). A lone "❯" line (an agent's
    /// own input prompt) isn't a menu: it takes at least two options.
    private static func cursorMenu(in lines: [String]) -> (start: Int, choices: [AnswerChoice])? {
        guard let at = lines.lastIndex(where: { line in
            let text = clean(line)
            guard let f = text.first, markers.contains(f) else { return false }
            return !text.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        // The label's column on the cursor line: the options below and above start there.
        let raw = lines[at]
        guard let marker = raw.firstIndex(where: { markers.contains($0) }),
              let labelStart = raw[raw.index(after: marker)...].firstIndex(where: { !$0.isWhitespace })
        else { return nil }
        let column = raw.distance(from: raw.startIndex, to: labelStart)
        func option(_ line: String) -> String? {
            let lead = line.prefix { $0 == " " }.count
            guard lead == column else { return nil }
            let text = clean(line)
            guard let f = text.first, !markers.contains(f), !borders.contains(f) else { return nil }
            return text
        }
        var above: [String] = []
        var i = at - 1
        while i >= 0, let text = option(lines[i]) { above.insert(text, at: 0); i -= 1 }
        var below: [String] = []
        var j = at + 1
        while j < lines.count, let text = option(lines[j]) { below.append(text); j += 1 }
        let selected = clean(String(raw[labelStart...]))
        let labels = above + [selected] + below
        guard labels.count >= 2, labels.count <= 9 else { return nil }
        let choices = labels.enumerated().map { n, label in
            AnswerChoice(number: n + 1, label: label, selected: n == above.count)
        }
        return (at - above.count, choices)
    }

    /// What is being asked about: the lines just above the question, back to a rule or a blank
    /// line ("Requesting permission for:" / "ls -la /home/x"), at most four, top first.
    static func context(in lines: [String]) -> [String] {
        guard let start = run(in: lines)?.start else { return [] }
        var j = (questionLines(in: lines)?.first ?? start) - 1 // above the question
        while j >= 0, clean(lines[j]).isEmpty { j -= 1 }       // and the gap above it
        var out: [String] = []
        while j >= 0, out.count < 4 {
            let text = clean(lines[j])
            if text.isEmpty || lines[j].contains("──") || lines[j].contains("━━") { break }
            out.insert(text, at: 0)
            j -= 1
        }
        return out
    }

    /// The bottom-most run of consecutive numbered choices (1., 2., …, starting at 1) on screen,
    /// with box-drawing borders and selection markers stripped; empty when there is none.
    static func choices(in lines: [String]) -> [AnswerChoice] { run(in: lines)?.choices ?? [] }

    /// The question above the choices, its wrapped lines joined, if any.
    static func question(in lines: [String]) -> String? {
        questionLines(in: lines)?.text.joined(separator: " ")
    }

    /// Whether the question a choice came from is still on screen: same number and same label.
    static func isStillShown(_ choice: AnswerChoice, in lines: [String]) -> Bool {
        choices(in: lines).contains { $0.number == choice.number && $0.label == choice.label }
    }

    /// Arrow presses from the selected row to the target: positive is down.
    static func steps(to choice: AnswerChoice, in current: [AnswerChoice]) -> Int {
        let from = current.firstIndex { $0.selected } ?? 0
        let to = current.firstIndex { $0.number == choice.number } ?? from
        return to - from
    }
}

extension ScreenFrame {
    /// The screen as plain text, one string per row.
    var textLines: [String] {
        lines.map { row in row.map { $0.text.isEmpty ? ($0.width == 0 ? "" : " ") : $0.text }.joined() }
    }
}

/// Replaces NeedsYouBar inside the chat. Falls back to NeedsYouBar's Yes/No/Return/Esc buttons
/// when no numbered choices are on screen.
struct AnswerCard: View {
    let status: TerminalStatus?
    let model: TerminalScreenModel
    let palette: ChatPalette
    /// Called with the question and the answer picked, so the chat can keep a record of it.
    var onAnswer: ((String, String) -> Void)?
    /// Where this prompt is (machine, folder, agent): with it, a Yes to a plain command offers
    /// "Always allow" afterwards.
    var scope: ApprovalScope?
    @Environment(\.colorScheme) private var scheme
    @State private var tapped = 0
    @State private var changed = false
    /// The number of a dangerous prompt's Yes that was tapped once and waits for a second tap.
    @State private var confirming: Int?
    /// The on-device explanation of the command it belongs to; kept per command, so a stale one
    /// never shows for a different command.
    @State private var explained: (command: String, text: String)?
    private let explainer = CommandExplainer(writer: OnDeviceText.shared)

    /// On a demo machine: the explanation is the demo's fixed sentence, not the model's.
    var demo = false

    init(status: TerminalStatus?, model: TerminalScreenModel, palette: ChatPalette,
         scope: ApprovalScope? = nil, demo: Bool = false, onAnswer: ((String, String) -> Void)? = nil) {
        self.demo = demo
        self.status = status
        self.model = model
        self.palette = palette
        self.scope = scope
        self.onAnswer = onAnswer
    }

    var body: some View {
        let lines = model.frame.textLines
        let choices = AnswerParser.choices(in: lines)
        // Only a question near the prompt counts: a "?" higher up is the conversation.
        let asked = lines.suffix(12).last(where: { $0.contains("?") }).map(AnswerParser.clean)
        // Claude Code and Codex ask with numbered menus that ignore y/n: if none was read, the
        // generic Yes/No buttons would answer nothing.
        let numberedOnly = ["claude-code", "codex"].contains(status?.app ?? "")
        if choices.isEmpty, AnswerParser.rewindOpen(lines) {
            rewindCard
        } else if choices.isEmpty, let step = AnswerParser.loginStep(in: lines) {
            LoginStepCard(step: step, model: model, palette: palette)
        } else if choices.isEmpty, AnswerParser.needsLogin(in: lines) || status?.kind == "auth" {
            loginCard
        } else if choices.isEmpty, let asked, !numberedOnly, let reason = DangerousCommand.check(asked) {
            // The generic Yes/No buttons are no place to approve this one.
            notice(title: "Dangerous: \(reason)",
                   detail: "\(asked)\nOpen the terminal (top right) to answer this one.", danger: true,
                   explanation: explanation(for: asked))
                .task(id: asked) { await explain(asked) }
        } else if choices.isEmpty, let asked, !numberedOnly {
            NeedsYouBar(status: status, model: model, dark: scheme == .dark) { answer in
                onAnswer?(asked, answer)
            }
        } else if choices.isEmpty {
            // Blocked, but nothing on screen to answer: Yes/No would only type letters into the
            // agent's input. Say so instead, and point at the terminal.
            notice(title: status?.title ?? asked ?? "Waiting for you",
                   detail: [status?.msg, "Bergr couldn't read the choices. Open the terminal (top right) to answer."]
                       .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        } else {
            card(choices, question: AnswerParser.question(in: lines), context: AnswerParser.context(in: lines))
        }
    }

    /// Claude's login on the machine expired: one button runs /login (clearing anything typed first).
    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude is signed out on this machine", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("Its login expired, so it can't answer. Sign in again from here: pick the account type, open the link, and paste the code back.")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
            Button {
                if model.watching { model.setWatching(false) }
                tapped += 1
                Task { @MainActor in
                    // Close whatever menu is open (Rewind, say) so the keys reach the prompt, then
                    // clear the line and run /login. One Esc only: two would open Rewind.
                    await model.automate {
                        model.press(.escape)
                        try? await Task.sleep(for: .milliseconds(400))
                        model.press(.letter("u"), modifiers: .control)
                        model.type("/login")
                        try? await Task.sleep(for: .milliseconds(150))
                        model.press(.enter)
                    }
                }
            } label: {
                Text("Run /login")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
    }

    /// Claude's Rewind menu is open (Esc pressed twice); one tap closes it.
    private var rewindCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Rewind is open", systemImage: "clock.arrow.circlepath")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("Claude's rewind menu opened (Esc pressed twice). Close it to type again, or open the terminal to pick a message to rewind to.")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
            Button {
                model.press(.escape)
                tapped += 1
            } label: {
                Text("Close Rewind")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
    }

    /// What the on-device model says the command would do, for the command shown now (nil until
    /// it answers, and when it can't).
    private func explanation(for command: String) -> String? {
        guard let explained, explained.command == command else { return nil }
        return explained.text
    }

    private func explain(_ command: String) async {
        let text = demo ? DemoChat.explanation(for: command) : await explainer.explain(command)
        explained = text.map { (command: command, text: $0) }
    }

    private func notice(title: String, detail: String, danger: Bool = false, explanation: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: danger ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(danger ? Color.red : palette.text)
            if let explanation {
                Text(explanation).font(.footnote).foregroundStyle(palette.text)
            }
            Text(detail).font(.footnote).foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func card(_ choices: [AnswerChoice], question: String?, context: [String]) -> some View {
        let commandText = ([question ?? ""] + context).joined(separator: "\n")
        let danger = DangerousCommand.check(commandText)
        return VStack(alignment: .leading, spacing: 8) {
            if let danger {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Dangerous: \(danger)", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.red)
                    if let explanation = explanation(for: commandText) {
                        Text(explanation)
                            .font(.footnote)
                            .foregroundStyle(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 4)
            }
            // What is being approved, so "Yes" is never a blind answer.
            if !context.isEmpty {
                Text(context.joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .foregroundStyle(palette.text)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(question ?? status?.title ?? "Waiting for you")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(5)
                .padding(.horizontal, 4)
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                let primary = index == 0 && choice.label.lowercased().hasPrefix("yes")
                let risky = danger != nil && choice.label.lowercased().hasPrefix("yes")
                let confirm = risky && confirming == choice.number
                Button {
                    // A dangerous command's Yes takes a second tap.
                    if risky, confirming != choice.number {
                        confirming = choice.number
                        tapped += 1
                    } else {
                        confirming = nil
                        select(choice)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("\(choice.number)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(primary ? Color.white.opacity(0.75) : palette.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(confirm ? "Tap again to confirm: \(choice.label)" : choice.label)
                                .font(.callout)
                            if !choice.detail.isEmpty {
                                Text(choice.detail)
                                    .font(.footnote)
                                    .opacity(0.7)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(risky ? Color.white : primary ? palette.onAccent : palette.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: PlatformMetrics.controlHeight)
                    .background(risky ? Color.red.opacity(confirm ? 1 : 0.7) : primary ? palette.accent : palette.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
            }
            HStack {
                if changed {
                    Text("The question changed").font(.footnote).foregroundStyle(palette.secondary)
                }
                Spacer()
                Button {
                    if model.watching { model.setWatching(false) }
                    onAnswer?(AnswerParser.question(in: model.frame.textLines) ?? status?.title ?? "Question", "Canceled (esc)")
                    model.press(.escape)
                    tapped += 1
                } label: {
                    Text("esc").font(.callout.monospaced()).padding(.horizontal, 12).frame(minHeight: PlatformMetrics.controlHeight)
                }
                .buttonStyle(PressStyle())
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("Escape")
            }
        }
        .padding(12)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        .task(id: danger == nil ? nil : commandText) {
            guard danger != nil else { return }
            await explain(commandText)
        }
    }

    private func select(_ choice: AnswerChoice) {
        tapped += 1
        let lines = model.frame.textLines
        guard AnswerParser.isStillShown(choice, in: lines) else {
            changed = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                changed = false
            }
            return
        }
        if model.watching { model.setWatching(false) }
        if choice.number == 1, choice.label == "Yes", let scope,
           let command = ApprovalRuleMatcher.promptCommand(lines: lines, cols: model.frame.cols, agent: status?.app) {
            AlwaysAllowOffers.shared.offer(command: command, scope: scope)
        }
        let context = AnswerParser.context(in: lines)
        let question = ([AnswerParser.question(in: lines)].compactMap { $0 } + context.suffix(1)).joined(separator: " — ")
        onAnswer?(question.isEmpty ? (status?.title ?? "Question") : question, choice.label)
        let steps = AnswerParser.steps(to: choice, in: AnswerParser.choices(in: lines))
        Task { @MainActor in
            await model.automate {
                for _ in 0..<abs(steps) { model.press(steps > 0 ? .down : .up) }
                model.press(.enter)
            }
        }
    }
}

/// Claude Code's /login, finished from the chat: open the sign-in page, paste the code it gives.
struct LoginStepCard: View {
    let step: AnswerParser.LoginStep
    let model: TerminalScreenModel
    let palette: ChatPalette
    @State private var code = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch step {
            case .pasteCode(let url):
                Label("Sign in to Claude", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("Open the sign-in page, approve, then paste the code it shows here.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                if let url {
                    Button { openURL(url) } label: {
                        Label("Open Sign-In Page", systemImage: "safari")
                            .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                    }
                    .buttonStyle(.bordered)
                }
                HStack(spacing: 8) {
                    TextField("Paste code", text: $code)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .padding(.horizontal, 12)
                        .frame(minHeight: PlatformMetrics.controlHeight)
                        .background(palette.bubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        if let pasted = Pasteboard.string { code = pasted }
                    } label: {
                        Image(systemName: "doc.on.clipboard").frame(width: PlatformMetrics.controlHeight, height: PlatformMetrics.controlHeight)
                    }
                    .macPlainButton()
                    .accessibilityLabel("Paste")
                }
                Button {
                    if model.watching { model.setWatching(false) }
                    let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    code = ""
                    Task { @MainActor in
                        // Let the paste land before Enter, or the prompt can take Enter first.
                        await model.automate {
                            model.paste(text)
                            try? await Task.sleep(for: .milliseconds(300))
                            model.press(.enter)
                        }
                    }
                } label: {
                    Text("Sign In")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .succeeded:
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                Button {
                    model.press(.enter)
                } label: {
                    Text("Continue")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The "Always allow" offer after a Yes to a plain command, kept for a few seconds after the card
/// goes away (the prompt is answered, so the card itself hides).
@MainActor @Observable
final class AlwaysAllowOffers {
    static let shared = AlwaysAllowOffers()
    struct Offer: Equatable {
        let command: String
        let scope: ApprovalScope
        let id = UUID()
    }
    private(set) var current: Offer?

    func offer(command: String, scope: ApprovalScope) {
        let covered = ApprovalRuleStore.shared.rules.contains {
            ApprovalRuleMatcher.matches($0, machine: scope.machine, cwd: scope.cwd, agent: scope.agent, command: command)
        }
        guard !covered else { return }
        let offer = Offer(command: command, scope: scope)
        current = offer
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            if self.current == offer { self.current = nil }
        }
    }

    func dismiss() { current = nil }
}

/// "Always allow `npm test` here": one tap makes the rule; the menu picks a shorter prefix instead.
struct AlwaysAllowBanner: View {
    let offer: AlwaysAllowOffers.Offer
    let palette: ChatPalette

    var body: some View {
        HStack(spacing: 8) {
            Button {
                ApprovalRuleStore.shared.add(scope: offer.scope, command: offer.command, prefix: false)
                AlwaysAllowOffers.shared.dismiss()
            } label: {
                Text("Always allow `\(offer.command)` here")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(palette.text)
            Menu {
                ForEach(ApprovalRuleMatcher.prefixes(of: offer.command), id: \.self) { prefix in
                    Button {
                        ApprovalRuleStore.shared.add(scope: offer.scope, command: prefix, prefix: true)
                        AlwaysAllowOffers.shared.dismiss()
                    } label: {
                        Text("Commands starting with \(prefix)")
                        if let warning = ApprovalRuleMatcher.prefixWarning(prefix) { Text(LocalizedStringKey(warning)) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel("Allow a prefix")
            Button { AlwaysAllowOffers.shared.dismiss() } label: {
                Image(systemName: "xmark").frame(minWidth: 32, minHeight: 32)
            }
            .macPlainButton()
            .foregroundStyle(palette.secondary)
            .accessibilityLabel("Not now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
