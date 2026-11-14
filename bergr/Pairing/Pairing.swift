import CryptoKit
import Foundation
import HerdrKit
import KeyStore

/// Pairing an iPhone from the Mac: the Mac shows a QR code with its machines, a one-time relay
/// token and an ephemeral X25519 key; the phone imports the machines and sends its SSH public key,
/// encrypted to that key, through the relay's mailbox; the Mac adds it to each machine's
/// `authorized_keys`. Only the phone's public key crosses; no private key leaves either device.
enum Pairing {
    static let version = 1
    /// How long a QR code (and its mailbox) is good for.
    static let lifetime: TimeInterval = 5 * 60
    static let pollInterval: Duration = .seconds(2)
}

enum PairingError: LocalizedError, Equatable {
    case notPairingCode
    case unsupportedVersion(Int)
    case invalid(String)
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .notPairingCode: "This isn't a Bergr pairing code."
        case .unsupportedVersion: "This code is from a newer Bergr. Update the app on both devices."
        case .invalid(let what): "The pairing code is damaged (\(what))."
        case .decryptionFailed: "The key from the iPhone couldn't be read."
        }
    }
}

struct PairingHost: Codable, Hashable, Sendable {
    var name: String
    var host: String
    var port: Int
    var user: String

    init(name: String, host: String, port: Int, user: String) {
        self.name = name
        self.host = host
        self.port = port
        self.user = user
    }

    init(_ host: Host) {
        self.init(name: host.name, host: host.target.host, port: host.target.port, user: host.target.username)
    }
}

/// What the QR code holds. No secrets but the token (hosts aren't secret).
struct PairingPayload: Codable, Equatable, Sendable {
    var v: Int
    var relay: String
    var token: String
    var macKey: String
    var hosts: [PairingHost]

    var relayURL: URL? { URL(string: relay) }

    var macPublicKey: Curve25519.KeyAgreement.PublicKey? {
        Base64URL.decode(macKey).flatMap { try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0) }
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    /// Parses and checks a scanned code.
    static func decode(_ text: String) throws -> PairingPayload {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = object["v"] as? Int
        else { throw PairingError.notPairingCode }
        guard v == Pairing.version else { throw PairingError.unsupportedVersion(v) }
        guard let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
            throw PairingError.invalid("format")
        }
        guard let url = payload.relayURL, url.scheme == "https", url.host() != nil else {
            throw PairingError.invalid("relay")
        }
        guard Base64URL.decode(payload.token)?.count == 16 else { throw PairingError.invalid("token") }
        guard payload.macPublicKey != nil else { throw PairingError.invalid("key") }
        for host in payload.hosts {
            guard !host.host.isEmpty, (1...65535).contains(host.port) else { throw PairingError.invalid("machine") }
        }
        return payload
    }
}

/// The Mac's side of one QR code: the ephemeral private key never leaves this object.
struct PairingOffer {
    let payload: PairingPayload
    let created: Date
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    init(relay: URL, hosts: [PairingHost], now: Date = .now) {
        var token = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, token.count, &token)
        let key = Curve25519.KeyAgreement.PrivateKey()
        privateKey = key
        created = now
        payload = PairingPayload(
            v: Pairing.version, relay: relay.absoluteString, token: Base64URL.encode(Data(token)),
            macKey: Base64URL.encode(key.publicKey.rawRepresentation), hosts: hosts)
    }

    var expires: Date { created.addingTimeInterval(Pairing.lifetime) }
    func isExpired(now: Date = .now) -> Bool { now >= expires }

    var mailboxURL: URL? { payload.relayURL?.appending(path: "pair/\(payload.token)") }

    /// The phone's public key line, from what it left in the mailbox.
    func open(_ sealed: String) throws -> String {
        let data = try PairingSeal.open(sealed, with: privateKey, token: payload.token)
        guard let line = String(data: data, encoding: .utf8) else { throw PairingError.decryptionFailed }
        return line
    }
}

/// X25519 (ephemeral sender key) + HKDF-SHA256 + ChaCha20-Poly1305. The token is authenticated
/// data, so a message can't be replayed into another pairing. Wire format, base64url:
/// sender public key (32) || nonce (12) || ciphertext || tag (16).
enum PairingSeal {
    private static let info = Data("bergr-pair-v1".utf8)

    static func seal(_ message: Data, to recipient: Curve25519.KeyAgreement.PublicKey, token: String) throws -> String {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try symmetricKey(ephemeral.sharedSecretFromKeyAgreement(with: recipient),
                                   sender: ephemeral.publicKey, recipient: recipient)
        let box = try ChaChaPoly.seal(message, using: key, authenticating: Data(token.utf8))
        return Base64URL.encode(ephemeral.publicKey.rawRepresentation + box.combined)
    }

    static func open(_ text: String, with recipient: Curve25519.KeyAgreement.PrivateKey, token: String) throws -> Data {
        guard let data = Base64URL.decode(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count > 32 + 12 + 16,
              let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data.prefix(32))
        else { throw PairingError.decryptionFailed }
        do {
            let key = try symmetricKey(recipient.sharedSecretFromKeyAgreement(with: sender),
                                       sender: sender, recipient: recipient.publicKey)
            let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(32))
            return try ChaChaPoly.open(box, using: key, authenticating: Data(token.utf8))
        } catch {
            throw PairingError.decryptionFailed
        }
    }

    private static func symmetricKey(_ secret: SharedSecret, sender: Curve25519.KeyAgreement.PublicKey,
                                     recipient: Curve25519.KeyAgreement.PublicKey) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: sender.rawRepresentation + recipient.rawRepresentation,
                                       sharedInfo: info, outputByteCount: 32)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// A public key line that came from the phone, checked before it goes anywhere near a shell.
struct PairedKey: Equatable {
    let line: String
    let fingerprint: String
    let comment: String

    private static let types: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// nil unless it is one well-formed `type base64 [comment]` line whose comment has no quotes,
    /// backslashes or control characters.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2000, !trimmed.contains(where: \.isNewline) else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, Self.types.contains(parts[0]),
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
              let blob = Data(base64Encoded: parts[1]), blob.count >= 4
        else { return nil }
        // The blob starts with string(type): it must agree with the first field.
        let length = blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard blob.count >= 4 + length, String(decoding: blob.dropFirst(4).prefix(length), as: UTF8.self) == parts[0]
        else { return nil }
        // The comment is only a label: characters a shell could care about are dropped, not trusted.
        let raw = parts.count > 2 ? parts[2] : ""
        let kept = raw.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && !"'\\\"`$".unicodeScalars.contains($0)
        }
        let comment = String(String(String.UnicodeScalarView(kept)).prefix(100))
            .trimmingCharacters(in: .whitespaces)
        line = comment.isEmpty ? "\(parts[0]) \(parts[1])" : "\(parts[0]) \(parts[1]) \(comment)"
        fingerprint = OpenSSH.sha256Fingerprint(blob: blob)
        self.comment = comment
    }
}

/// Appending a key to a machine's `authorized_keys` through the system `ssh`. The script goes in
/// on stdin to `sh -s`, so it runs the same under any login shell.
enum AuthorizedKeysInstall {
    enum Outcome: Equatable {
        case added
        case alreadyPresent
        case skippedWindows
        case failed(String)

        var message: String {
            switch self {
            case .added: "Key added"
            case .alreadyPresent: "Already there"
            case .skippedWindows: "Skipped: Windows machine. Add the key by hand."
            case .failed(let why): why
            }
        }
    }

    static func arguments(for host: PairingHost) -> [String]? {
        let target = SSHTarget(host: host.host, port: host.port, username: host.user)
        guard var args = SystemSSHTest.arguments(for: target) else { return nil }
        args[args.count - 1] = "sh -s" // replaces the probe's `true`
        return args
    }

    /// Idempotent: does nothing if the exact line is present. Creates `~/.ssh` (700) and the file
    /// (600) only when missing; never changes existing permissions.
    static func script(for key: PairedKey) -> String {
        """
        set -e
        umask 077
        KEY='\(key.line)'
        [ -d "$HOME/.ssh" ] || mkdir -m 700 "$HOME/.ssh"
        F="$HOME/.ssh/authorized_keys"
        if [ ! -f "$F" ]; then : > "$F"; chmod 600 "$F"; fi
        if grep -qxF -- "$KEY" "$F"; then echo BERGR_PRESENT; exit 0; fi
        if [ -s "$F" ] && [ -n "$(tail -c 1 "$F")" ]; then echo >> "$F"; fi
        printf '%s\\n' "$KEY" >> "$F"
        echo BERGR_ADDED

        """
    }

    static func outcome(status: Int32, stdout: String, stderr: String) -> Outcome {
        if status == 0, stdout.contains("BERGR_ADDED") { return .added }
        if status == 0, stdout.contains("BERGR_PRESENT") { return .alreadyPresent }
        let lower = (stderr + stdout).lowercased()
        if lower.contains("is not recognized") { return .skippedWindows }
        switch SystemSSHTest.explain(status: status == 0 ? 1 : status, stderr: stderr) {
        case .failed(let why), .unavailable(let why): return .failed(why)
        case .works: return .failed("Unexpected reply from the machine.")
        }
    }

    #if os(macOS)
    static func run(_ key: PairedKey, on host: PairingHost) async -> Outcome {
        guard let arguments = arguments(for: host) else { return .failed("Invalid address.") }
        let script = Data(script(for: key).utf8)
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { finished in
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: outcome(status: finished.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(script)
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }
    #endif
}

/// The phone's side: send its public key to the Mac that showed the code.
enum PairingClient {
    static func request(line: String, payload: PairingPayload) throws -> URLRequest {
        guard let key = payload.macPublicKey, let relay = payload.relayURL else { throw PairingError.invalid("key") }
        let sealed = try PairingSeal.seal(Data(line.utf8), to: key, token: payload.token)
        var request = URLRequest(url: relay.appending(path: "pair/\(payload.token)"))
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "content-type")
        request.httpBody = Data(sealed.utf8)
        return request
    }

    static func send(line: String, payload: PairingPayload) async throws {
        let (_, response) = try await URLSession.shared.data(for: request(line: line, payload: payload))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return
        case 409: throw PairingError.invalid("this code was already used")
        default: throw PairingError.invalid("relay answered \(status)")
        }
    }
}
