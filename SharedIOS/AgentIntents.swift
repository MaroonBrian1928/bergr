import AppIntents
import Foundation

/// Which agents the intents and widgets see, and in what order: from the snapshot the widget reads,
/// so it needs no connection and no app launch.
nonisolated enum AgentCatalog {
    typealias Row = BergrActivityAttributes.Row

    /// Needs-you rows first, then the rest in the snapshot's own order (working, then done).
    static func sorted(_ rows: [Row]) -> [Row] {
        rows.enumerated()
            .sorted { a, b in
                let x = a.element.needsYou ? 0 : 1
                let y = b.element.needsYou ? 0 : 1
                return x == y ? a.offset < b.offset : x < y
            }
            .map(\.element)
    }

    /// Rows whose agent, machine or status contains the text (case and diacritics ignored).
    static func matching(_ text: String, in rows: [Row]) -> [Row] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            [row.title, row.machine, row.status].contains { $0.localizedStandardContains(query) }
        }
    }

    /// Rows blocked or in error, as the snapshot lists them (at most the snapshot's few).
    static func needingYou(_ snapshot: AgentsSnapshot) -> [Row] {
        sorted(snapshot.rows).filter(\.needsYou)
    }

    /// The text "What needs me" says: who needs you, and how many more the snapshot doesn't list.
    static func needsYouText(_ snapshot: AgentsSnapshot) -> String {
        let listed = needingYou(snapshot)
        guard snapshot.needsYou > 0, !listed.isEmpty else {
            return snapshot.working > 0
                ? "Nothing needs you. \(snapshot.working) working."
                : "Nothing needs you."
        }
        let names = listed.map { "\($0.title) on \($0.machine)" }.joined(separator: ", ")
        let head = snapshot.needsYou == 1 ? "1 agent needs you: " : "\(snapshot.needsYou) agents need you: "
        let more = snapshot.needsYou - listed.count
        return head + names + (more > 0 ? ", and \(more) more" : "") + "."
    }

    /// The spoken "What needs me": the on-device model's sentence about the listed rows, or
    /// `needsYouText` when nothing needs you, the model is unavailable, or it takes longer than `timeout`.
    /// Nothing needing you makes no model call.
    static func needsYouSpeech(_ snapshot: AgentsSnapshot, writer: OnDeviceTextWriting,
                               timeout: Duration = .seconds(2)) async -> String {
        let fallback = needsYouText(snapshot)
        let listed = needingYou(snapshot)
        guard snapshot.needsYou > 0, !listed.isEmpty else { return fallback }
        let lines = listed.map { row in
            "- agent \(row.title) (\(row.kind)) on machine \(row.machine), status: \(row.status.isEmpty ? "none" : row.status)"
        }
        let unlisted = snapshot.needsYou - listed.count
        let prompt = """
        \(snapshot.needsYou) agent\(snapshot.needsYou == 1 ? " needs" : "s need") the user. Listed:
        \(lines.joined(separator: "\n"))
        \(unlisted > 0 ? "Not listed: \(unlisted) more." : "Every one is listed.")
        """
        let instructions = """
        You write what a phone's voice assistant says when asked what needs the user. Answer in one or two \
        plain sentences, with no lists, markdown or quotes. Name each listed agent with its machine, and say \
        what it is blocked on or what went wrong, using only the given status. Mention any unlisted ones as a count.
        """
        return await writer.write(instructions: instructions, prompt: prompt, timeout: timeout) ?? fallback
    }
}

/// An agent on one machine, for "Send to agent" and the agent entity queries.
nonisolated struct AgentEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentEntityQuery()

    /// `host|address`: stable for as long as the terminal lives.
    let id: String
    let title: String
    let machine: String
    let status: String
    let needsYou: Bool
    let host: String
    let address: String

    init(row: BergrActivityAttributes.Row) {
        id = "\(row.host)|\(row.address)"
        title = row.title
        machine = row.machine
        status = row.status
        needsYou = row.needsYou
        host = row.host
        address = row.address
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(machine)\(status.isEmpty ? "" : " · \(status)")")
    }
}

nonisolated struct AgentEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        AgentCatalog.sorted(AgentsSnapshot.load().rows).map(AgentEntity.init(row:))
            .filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        AgentCatalog.matching(string, in: AgentCatalog.sorted(AgentsSnapshot.load().rows)).map(AgentEntity.init(row:))
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        AgentCatalog.sorted(AgentsSnapshot.load().rows).map(AgentEntity.init(row:))
    }
}

/// "What needs me": the agents blocked or in error, as text and as the intent's spoken answer.
nonisolated struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What needs me"
    static let description = IntentDescription("Lists the agents in Bergr that are blocked or in error.")
    static let openAppWhenRun = false

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let text = await AgentCatalog.needsYouSpeech(AgentsSnapshot.load(), writer: OnDeviceText.shared)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Which agent kind a Bergr intent starts, as the Shortcuts picker offers it.
nonisolated enum AgentChoice: String, AppEnum, Sendable {
    case claude, codex, antigravity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent kind"
    static let caseDisplayRepresentations: [AgentChoice: DisplayRepresentation] = [
        .claude: "Claude Code", .codex: "Codex", .antigravity: "Antigravity",
    ]
}

/// "Send to agent": queued for the app, which opens the agent's chat with the text in its reply
/// draft (the existing reply path sends it).
nonisolated struct SendToAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to agent"
    static let description = IntentDescription("Sends a message to an agent in Bergr. Opens Bergr to deliver it.")
    static let openAppWhenRun = true

    @Parameter(title: "Agent", requestValueDialog: "Which agent?")
    var agent: AgentEntity

    @Parameter(title: "Message", requestValueDialog: "What should it say?")
    var message: String

    func perform() async throws -> some IntentResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result() }
        IntentQueue.enqueue(.message(host: agent.host, address: agent.address, text: text))
        return .result()
    }
}

/// "Start session": queued for the app, which opens New Session with these values filled in.
nonisolated struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start session"
    static let description = IntentDescription("Starts an agent in a folder on one of your machines. Opens Bergr's New Session.")
    static let openAppWhenRun = true

    @Parameter(title: "Machine", requestValueDialog: "Which machine?")
    var machine: String

    @Parameter(title: "Agent", requestValueDialog: "Which agent?")
    var agent: AgentChoice

    @Parameter(title: "Folder", default: "")
    var folder: String

    @Parameter(title: "First message", default: "")
    var message: String

    func perform() async throws -> some IntentResult {
        IntentQueue.enqueue(.newSession(
            machine: machine.trimmingCharacters(in: .whitespacesAndNewlines), agent: agent.rawValue,
            folder: folder.trimmingCharacters(in: .whitespacesAndNewlines), message: message))
        return .result()
    }
}

/// The Control Center control: opens Bergr at the agents that need you.
nonisolated struct OpenNeedsYouIntent: AppIntent {
    static let title: LocalizedStringResource = "Agents that need you"
    static let description = IntentDescription("Opens Bergr at the agents that need you.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        IntentQueue.enqueue(.openNeedsYou)
        return .result()
    }
}

/// What an intent asked the app to do once it opens. Kept in the App Group so an intent running in
/// the extension or the app reaches the same queue.
nonisolated enum PendingIntent: Codable, Equatable, Sendable {
    case message(host: String, address: String, text: String)
    case newSession(machine: String, agent: String, folder: String, message: String)
    case openNeedsYou
}

nonisolated enum IntentQueue {
    private static let key = "pending-intents"

    static var store: UserDefaults {
        BergrAppGroup.id.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    static func enqueue(_ item: PendingIntent, in store: UserDefaults = IntentQueue.store) {
        var items = read(store)
        items.append(item)
        if let data = try? JSONEncoder().encode(items) { store.set(data, forKey: key) }
    }

    /// Returns what is queued, in order, and empties the queue.
    static func take(from store: UserDefaults = IntentQueue.store) -> [PendingIntent] {
        let items = read(store)
        store.removeObject(forKey: key)
        return items
    }

    private static func read(_ store: UserDefaults) -> [PendingIntent] {
        guard let data = store.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingIntent].self, from: data)) ?? []
    }
}
