import Foundation

/// A message the push helper types into an agent's terminal at a set time (helper 24+), e.g.
/// "continue" when a plan limit resets. The helper runs on the machine, so it goes out with the
/// phone asleep and Bergr closed; it alerts when it did.
nonisolated enum ScheduledSend {
    static let minHelperVersion = 24
    static let defaultText = "continue"

    struct Entry: Codable, Equatable {
        var id: String
        var address: String
        var at: Double
        var text: String
    }

    /// When to send for a window that's used up: a minute after it resets (the agent's provider
    /// may take a moment to let it through).
    static func sendTime(resetsAt: Date) -> Date { resetsAt.addingTimeInterval(60) }

    /// When the agent can go on, if a plan window is used up: the latest reset among the full ones
    /// (a weekly limit outlasts the session one). Nil when none is full.
    static func limitingReset(session: ChatFeed.Usage.Window?, weekly: ChatFeed.Usage.Window?,
                              now: Date = .now) -> Date? {
        [session, weekly].compactMap { $0 }
            .filter { $0.percent >= 100 }
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .max()
    }

    /// The reset time in an agent's own "out of usage" message, e.g. Claude's "You've hit your
    /// 5-hour limit · resets 11pm (America/Chicago)" or "… resets 3:30pm", or Codex's "… try again
    /// at 3:05 PM": the next such time after `now`, in the named time zone if there is one.
    static func resetFromMessage(_ text: String, now: Date = .now) -> Date? {
        let lower = text.lowercased()
        guard lower.contains("limit") || lower.contains("usage") else { return nil }
        guard let m = text.firstMatch(of: /(?i)(?:resets?|try again)(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)(?:\s*\(([A-Za-z_]+\/[A-Za-z_]+)\))?/)
        else { return nil }
        guard var hour = Int(m.output.1), (1...12).contains(hour) else { return nil }
        let minute = m.output.2.flatMap { Int($0) } ?? 0
        let pm = m.output.3.lowercased().hasPrefix("p")
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        var calendar = Calendar(identifier: .gregorian)
        if let zone = m.output.4.flatMap({ TimeZone(identifier: String($0)) }) { calendar.timeZone = zone }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }

    /// Adds `entry` to scheduled.json beside push.json (the helper's folder), replacing an earlier
    /// one for the same terminal; or, with `remove`, takes the terminal's entry out. Prints the list.
    static let script = """
    import json, os, sys, base64
    arg = json.loads(base64.b64decode(sys.argv[1]))
    local = os.environ.get("LOCALAPPDATA")
    home = os.path.join(os.path.expanduser("~"), ".config", "bergr")
    folder = os.path.join(local, "bergr") if os.name == "nt" and local and not os.path.exists(os.path.join(home, "push.json")) else home
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "scheduled.json")
    try:
        items = json.load(open(path, encoding="utf-8"))
        items = items if isinstance(items, list) else []
    except Exception:
        items = []
    entry = arg.get("entry")
    address = (entry or {}).get("address") or arg.get("remove")
    items = [i for i in items if isinstance(i, dict) and i.get("address") != address]
    if entry:
        items.append(entry)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(items, f)
    os.replace(tmp, path)
    print(json.dumps(items))
    """

    static func command(entry: Entry? = nil, remove address: String? = nil,
                        windows: Bool) -> PushRegistration.RemoteCommand {
        var arg: [String: Any] = [:]
        if let entry, let data = try? JSONEncoder().encode(entry),
           let object = try? JSONSerialization.jsonObject(with: data) { arg["entry"] = object }
        if let address { arg["remove"] = address }
        let data = (try? JSONSerialization.data(withJSONObject: arg, options: [.sortedKeys])) ?? Data()
        return PushRegistration.pythonCommand(code: script, argument: data.base64EncodedString(), windows: windows)
    }

    /// The entry for `address` in the printed list, if any.
    static func pending(in output: String, address: String) -> Entry? {
        let line = output.split(separator: "\n").last.map(String.init) ?? ""
        let entries = (try? JSONDecoder().decode([Entry].self, from: Data(line.utf8))) ?? []
        return entries.first { $0.address == address }
    }
}
