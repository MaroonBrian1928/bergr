import Foundation

/// Recognizes explicit names for this machine without DNS lookups or network access.
public enum LocalMachine {
    public static func matches(_ hostname: String, names: [String] = localNames) -> Bool {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let name = normalized(hostname)
        if ["localhost", "127.0.0.1", "::1"].contains(name) { return true }
        return names.contains {
            let own = normalized($0)
            guard !own.isEmpty else { return false }
            return name == own || name == (own.hasSuffix(".local") ? String(own.dropLast(6)) : own + ".local")
        }
    }

    public static var localNames: [String] {
        #if os(macOS)
        [ProcessInfo.processInfo.hostName, Host.current().name, Host.current().localizedName]
            .compactMap { $0 }
        #else
        []
        #endif
    }
}
