import Foundation

/// A private key file found in a folder such as `~/.ssh`.
public struct DiscoveredKey: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Parses; can be imported.
        case importable(SSHKeyAlgorithm, comment: String?)
        /// Looks like a key but can't be imported (passphrase, RSA, ...): the reason, in words.
        case unusable(String)
    }

    public var id: URL { url }
    public let url: URL
    public let status: Status

    public var name: String { url.lastPathComponent }
}

/// Lists the private keys in a folder (not their contents).
public enum SSHFolder {
    /// Files that are never private keys.
    static let skipped: Set<String> = [
        "config", "known_hosts", "known_hosts.old", "authorized_keys", "environment", "rc",
    ]

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Plain files that start with a PEM/OpenSSH private-key header, sorted by name. Public keys,
    /// `config`, `known_hosts`, dotfiles, directories and files over 100 kB are left out; a key
    /// that can't be imported is listed with the reason. Never throws: a missing folder is empty.
    public static func discover(in folder: URL = defaultURL) -> [DiscoveredKey] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [DiscoveredKey] = []
        for name in names.sorted() {
            guard !name.hasPrefix("."), !name.hasSuffix(".pub"), !skipped.contains(name) else { continue }
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0, size < 100_000,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  text.contains("-----BEGIN"), text.contains("PRIVATE KEY-----")
            else { continue }
            do {
                let key = try PrivateKeyImporter.parse(text)
                let algorithm: SSHKeyAlgorithm
                switch key.material {
                case .ed25519: algorithm = .ed25519
                case .p256: algorithm = .p256
                }
                found.append(DiscoveredKey(url: url, status: .importable(algorithm, comment: key.comment)))
            } catch {
                found.append(DiscoveredKey(url: url, status: .unusable(error.localizedDescription)))
            }
        }
        return found
    }

    /// Reads one key file's text for import.
    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count < 100_000, let text = String(data: data, encoding: .utf8) else {
            throw KeyImportError.notAKey
        }
        return text
    }
}
