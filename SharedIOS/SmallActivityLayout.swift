import Foundation

/// What the small Live Activity family (Apple Watch Smart Stack) shows. Pure, so it is testable;
/// the view in BergrLiveActivity only draws it.
nonisolated enum SmallActivityLayout: Equatable {
    /// Nothing to answer: the most urgent agent and a one-line status.
    case status(name: String, line: String)
    /// A question with Yes / No. Either may be missing when the screen offers no such choice.
    case answer(prompt: BergrActivityAttributes.Prompt, yes: BergrActivityAttributes.Option?, no: BergrActivityAttributes.Option?)
    /// A question that has no safe wrist answer (dangerous command, or no Yes / No): no buttons.
    case openOnPhone(name: String, question: String)

    static func make(_ state: BergrActivityAttributes.ContentState) -> SmallActivityLayout {
        guard let prompt = state.prompt else {
            guard let top = state.rows.first else {
                let line = state.working > 0 ? "\(state.working) working" : "\(state.done) ready"
                return .status(name: "Agents", line: line)
            }
            return .status(name: top.title, line: top.status.isEmpty ? top.machine : top.status)
        }
        // A dangerous command never gets an answer button; the chat asks for a confirmation.
        if DangerousCommand.check(prompt.question) != nil {
            return .openOnPhone(name: prompt.title, question: prompt.question)
        }
        let yes = prompt.options.first { $0.key == "y" || ($0.number > 0 && $0.label.hasPrefix("Yes")) }
        let no = prompt.options.first { $0.key == "n" || ($0.number > 0 && $0.label.hasPrefix("No")) }
        if yes == nil && no == nil { return .openOnPhone(name: prompt.title, question: prompt.question) }
        return .answer(prompt: prompt, yes: yes, no: no)
    }
}
