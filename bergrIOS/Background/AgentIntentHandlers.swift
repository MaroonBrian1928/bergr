import Foundation
import HerdrKit

extension IntentSendOutcome {
    init(_ outcome: AnswerFlow.ReplyOutcome) {
        switch outcome {
        case .sent: self = .sent
        case .savedAsDraft: self = .waitingOnQuestion
        case .openedChat: self = .unreachable
        }
    }
}

/// The app side of the Siri intents: sends through the same reply path as a notification's Reply,
/// and reads an agent's last message from its chat feed.
@MainActor
enum AgentIntentHandlers {
    static func install(sessions: SessionStore, hosts: HostStore, keys: KeyLibrary, flow: AnswerFlow) {
        AgentIntentBridge.send = { host, address, text in
            let outcome = await flow.reply(ReplyNotificationRequest(host: host, address: address, text: text))
            if outcome == .openedChat {
                // Couldn't connect: keep the message in the chat's draft instead of losing it.
                let key = "\(host.uuidString)|\(address)"
                let kept = ReplyDrafts.text(for: key)
                ReplyDrafts.set(kept.isEmpty ? text : kept + "\n" + text, for: key)
            }
            return IntentSendOutcome(outcome)
        }
        let connect = AnswerFlow.connected(sessions: sessions, hosts: hosts, keys: keys, timeout: .seconds(10))
        AgentIntentBridge.latestMessage = { host, address in
            guard let (session, terminal) = await connect(host, address),
                  let agent = ChatAgent.detect(terminal) else { return nil }
            let front = terminal.foreground.flatMap { fg in
                ChatAgent.detect(name: fg.name, argv: fg.argv) == agent ? fg : nil
            }
            let feed = session.chatFeed(
                address: address, agent: agent, pid: front?.pid ?? 0, cwd: front?.cwd ?? terminal.cwd,
                sessionHint: ChatAgent.sessionHint(argv: front?.argv ?? terminal.foreground?.argv ?? []))
            let start = ContinuousClock.now
            while !feed.caughtUp, ContinuousClock.now - start < .seconds(8) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            return feed.items.reversed().lazy.compactMap { item -> String? in
                if case .assistant(let text, _) = item.kind { return text }
                return nil
            }.first
        }
    }
}
