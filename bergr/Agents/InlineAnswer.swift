import Foundation
import HerdrKit

/// Yes / No answered straight from an agent's row in the list, through the same path as the
/// notification buttons (`AnswerNotificationPolicy`), so the same-prompt re-check and the
/// dangerous-command guard apply.
enum InlineAnswer {
    enum Outcome: Equatable { case sent, changed, failed }

    /// The buttons to show for this row: nothing unless it is blocked on a Yes / No. A dangerous
    /// command gets none. With the screen's `lines`, a numbered menu with Yes / No choices counts too.
    static func options(status: TerminalStatus?, lines: [String]? = nil) -> [String] {
        guard status?.state == "blocked" else { return [] }
        if let lines {
            let reading = PromptReading.read(lines: lines, statusTitle: status?.title)
            if reading.numbered {
                guard DangerousCommand.check(([reading.question] + AnswerParser.context(in: lines)).joined(separator: "\n")) == nil
                else { return [] }
                let labels = reading.options.map { $0.label.lowercased() }
                return ["Yes", "No"].filter { word in labels.contains { $0.hasPrefix(word.lowercased()) } }
            }
        }
        return AgentNotifier.question(for: status)?.options ?? []
    }

    /// The request the row's button stands for (`index` into `options`).
    static func request(host: UUID, terminal: Terminal, index: Int) -> AnswerNotificationRequest? {
        guard let question = AgentNotifier.question(for: terminal.status), question.options.indices.contains(index)
        else { return nil }
        return AnswerNotificationRequest(host: host, address: terminal.address, question: question, index: index)
    }

    /// Connects, re-checks the prompt, presses the answer and records it as the answer card does.
    @MainActor
    static func perform(
        _ request: AnswerNotificationRequest,
        connect: (UUID, String) async -> AnswerFlow.Screen?,
        record: (_ question: String, _ answer: String, _ source: ApprovalEntry.Source) -> Void
    ) async -> Outcome {
        guard let screen = await connect(request.host, request.address) else { return .failed }
        guard case .send(let steps, let question, let answer) =
                AnswerNotificationPolicy.decide(request, status: screen.status, lines: screen.lines)
        else {
            await screen.close()
            return .changed
        }
        await screen.send(steps)
        record(question, answer, .card)
        await screen.close()
        return .sent
    }
}
