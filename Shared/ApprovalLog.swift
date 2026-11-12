import Foundation

/// One answer Bergr sent to a permission prompt.
nonisolated struct ApprovalEntry: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case card, notification, intent }

    var id = UUID()
    var date: Date
    var machine: String
    var agent: String
    var question: String
    var answer: String
    var source: Source
    var dangerous: Bool
}

/// The approvals log: a JSON file in the app group (Application Support without one), newest last,
/// the last 500 kept.
nonisolated enum ApprovalLog {
    static let limit = 500
    private static let lock = NSLock()

    static var defaultURL: URL {
        let base = BergrAppGroup.id.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("approvals.json")
    }

    static func load(from url: URL = defaultURL) -> [ApprovalEntry] {
        lock.lock(); defer { lock.unlock() }
        return read(url)
    }

    private static func read(_ url: URL) -> [ApprovalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ApprovalEntry].self, from: data)) ?? []
    }

    static func append(_ entry: ApprovalEntry, to url: URL = defaultURL) {
        lock.lock(); defer { lock.unlock() }
        var entries = read(url)
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear(at url: URL = defaultURL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Logs an answer; `dangerous` is worked out from the question.
    static func record(
        machine: String, agent: String, question: String, answer: String, source: ApprovalEntry.Source,
        to url: URL = defaultURL
    ) {
        append(ApprovalEntry(
            date: .now, machine: machine, agent: agent, question: question, answer: answer, source: source,
            dangerous: DangerousCommand.check(question) != nil), to: url)
    }
}
