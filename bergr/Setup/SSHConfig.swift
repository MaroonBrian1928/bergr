import Foundation
import SSHTransport

/// One concrete `Host` entry from an OpenSSH client config.
struct SSHConfigEntry: Equatable, Identifiable, Sendable {
    var id: String { alias }
    let alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
}

/// Reads the Host entries of an ssh_config. Wildcard and negated patterns are skipped (they set
/// defaults, not machines), `Match` blocks are ignored, and `Include` is not followed. A repeated
/// Host alias is one entry, and the first value of each option wins, as ssh does.
enum SSHConfig {
    static func entries(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: [Int] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let (keyword, value) = split(trimmed)
            let args = arguments(value)
            switch keyword.lowercased() {
            case "host":
                current = []
                for alias in args where isConcrete(alias) {
                    if let index = entries.firstIndex(where: { $0.alias == alias }) {
                        current.append(index)
                    } else {
                        entries.append(SSHConfigEntry(alias: alias))
                        current.append(entries.count - 1)
                    }
                }
            case "match":
                current = []
            case "hostname":
                for i in current where entries[i].hostName == nil { entries[i].hostName = args.first }
            case "user":
                for i in current where entries[i].user == nil { entries[i].user = args.first }
            case "port":
                for i in current where entries[i].port == nil { entries[i].port = args.first.flatMap { Int($0) } }
            case "identityfile":
                for i in current where entries[i].identityFile == nil { entries[i].identityFile = args.first }
            default:
                break // Include and every other option: a machine needs none of them.
            }
        }
        return entries
    }

    /// `user@hostname:port · ~/.ssh/key`, with the parts the entry sets.
    static func summary(_ entry: SSHConfigEntry) -> String {
        var address = entry.hostName ?? entry.alias
        if let user = entry.user { address = "\(user)@\(address)" }
        if let port = entry.port { address += ":\(port)" }
        return [address, entry.identityFile].compactMap { $0 }.joined(separator: " · ")
    }

    /// `Key value` or `Key=value`, with spaces around the `=` allowed.
    private static func split(_ line: String) -> (String, String) {
        let separators: Set<Character> = [" ", "\t", "="]
        guard let cut = line.firstIndex(where: { separators.contains($0) }) else { return (line, "") }
        let rest = line[cut...].drop(while: { separators.contains($0) })
        return (String(line[..<cut]), String(rest))
    }

    /// Whitespace-separated arguments, quotes removed; a trailing `# comment` ends the list.
    private static func arguments(_ value: String) -> [String] {
        var args: [String] = []
        for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let arg = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if arg.hasPrefix("#") { break }
            args.append(arg)
        }
        return args
    }

    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!".contains($0) })
    }
}

extension Host {
    /// A machine for an ssh_config entry. It signs in through this Mac's SSH (its config, known
    /// hosts and agent), so no Bergr key is needed.
    static func imported(_ entry: SSHConfigEntry, localUser: String) -> Host {
        Host(
            name: entry.alias,
            target: SSHTarget(host: entry.hostName ?? entry.alias, port: entry.port ?? 22,
                              username: entry.user ?? localUser),
            keyID: nil,
            systemSSH: true)
    }
}
