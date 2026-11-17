import Foundation
import HerdrKit
import TerminalCore

/// The most urgent blocked agent, with its question and answers.
enum PromptBuilder {
    typealias Prompt = BergrActivityAttributes.Prompt

    /// Blocked agents with a numbered question first (those can be answered precisely), among
    /// those a permission prompt before a free-form question, then in the order given. An agent
    /// whose screen isn't known yet is skipped.
    static func prompt(machines: [LiveActivityMachine], screens: [String: [String]]) -> Prompt? {
        var best: (prompt: Prompt, rank: Int)?
        for machine in machines {
            for terminal in machine.terminals where terminal.isLive && terminal.status?.state == "blocked" {
                guard let lines = screens[LiveActivityController.screenKey(host: machine.host, terminal: terminal)]
                else { continue }
                let reading = PromptReading.read(lines: lines, statusTitle: terminal.status?.title)
                if reading.options.isEmpty { continue }
                let prompt = Prompt(
                    host: machine.host.uuidString, address: terminal.address, title: terminal.displayName,
                    question: reading.question, options: reading.options)
                let rank = (reading.numbered ? 2 : 0) + (terminal.status?.kind == "permission" ? 1 : 0)
                if best == nil || rank > best!.rank { best = (prompt, rank) }
            }
        }
        return best?.prompt
    }
}

extension LiveActivityController {
    /// Reads a blocked terminal's screen without taking its size or typing.
    static func readScreen(session: HostSession, terminal: Terminal) async -> [String]? {
        guard let capture = try? await ScreenCapture.open(session: session, terminal: terminal, observe: true)
        else { return nil }
        let lines = await capture.settledLines()
        await capture.close()
        return lines
    }

    /// A tap on an answer button: re-reads the screen and answers only if it still asks the
    /// same question. Never answers a prompt that has changed.
    func answer(_ request: AnswerRequest) async {
        defer { screenAnswered(host: request.host, address: request.address) }
        guard let host = UUID(uuidString: request.host), let session = sessions.existing(host),
              let terminal = session.terminal(request.address), terminal.isLive,
              terminal.status?.state == "blocked",
              let capture = try? await ScreenCapture.open(session: session, terminal: terminal, observe: false)
        else { return }
        let lines = await capture.settledLines()
        var decision = AnswerDecision.changed
        if let lines {
            // The status may have moved on while we attached.
            let status = session.terminal(request.address)?.status
            if status?.state == "blocked" {
                decision = AnswerPolicy.decide(
                    question: request.question, number: request.number, label: request.label, key: request.key,
                    lines: lines, statusTitle: status?.title)
            }
        }
        if case .send(let steps, let question, let answer) = decision {
            await capture.send(steps)
            Self.record(question: question, answer: answer, session: session, terminal: terminal, source: .intent)
        }
        await capture.close()
    }

    /// Puts the answer into the terminal's chat, if it has an agent chat.
    static func record(
        question: String, answer: String, session: HostSession, terminal: Terminal,
        source: ApprovalEntry.Source = .intent
    ) {
        AnswerRecorder.record(question: question, answer: answer, session: session, terminal: terminal, source: source)
    }
}
