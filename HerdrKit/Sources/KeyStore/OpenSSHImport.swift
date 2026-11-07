import CryptoKit
import Foundation

/// A private key read from text the user pasted or picked.
public struct ImportedPrivateKey: Sendable {
    public enum Material: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
    }
    public let material: Material
    public let comment: String?
}

public enum KeyImportError: Error, LocalizedError, Equatable {
    case empty
    case notAKey
    case passphrase
    case rsa
    case unsupported(String)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .empty: "Paste a private key or choose a file."
        case .notAKey: "This doesn't look like a private key. Expected text starting with “-----BEGIN OPENSSH PRIVATE KEY-----”."
        case .passphrase:
            "This key has a passphrase. Remove it with `ssh-keygen -p -f <file>` and import again, or create a new key in Bergr."
        case .rsa: "RSA keys are not supported. Use an ed25519 or ECDSA P-256 key, or create a new key in Bergr."
        case .unsupported(let what): "Unsupported key type: \(what). Bergr supports ed25519 and ECDSA P-256."
        case .malformed: "The key data is damaged or incomplete."
        }
    }
}

/// Parses unencrypted OpenSSH and PEM private keys.
public enum PrivateKeyImporter {
    public static func parse(_ text: String) throws -> ImportedPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyImportError.empty }
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") { return try parseOpenSSH(trimmed) }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw KeyImportError.rsa }
        if trimmed.contains("ENCRYPTED PRIVATE KEY") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
            throw KeyImportError.passphrase
        }
        if trimmed.contains("BEGIN EC PRIVATE KEY") || trimmed.contains("BEGIN PRIVATE KEY") {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
                return ImportedPrivateKey(material: .p256(key), comment: nil)
            }
            // PKCS#8 may also wrap RSA or another curve.
            throw KeyImportError.unsupported("PEM key (only P-256 is supported)")
        }
        throw KeyImportError.notAKey
    }

    private static func parseOpenSSH(_ text: String) throws -> ImportedPrivateKey {
        let body = text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw KeyImportError.malformed }
        var r = Reader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard try r.bytes(magic.count) == magic else { throw KeyImportError.notAKey }
        let cipher = try r.string()
        let kdf = try r.string()
        _ = try r.blob()  // kdf options
        guard try r.uint32() == 1 else { throw KeyImportError.unsupported("file with several keys") }
        let publicBlob = try r.blob()
        if cipher != "none" || kdf != "none" {
            // Type is visible in the public blob; refuse RSA before talking about passphrases.
            var p = Reader(publicBlob)
            if (try? p.string()) == "ssh-rsa" { throw KeyImportError.rsa }
            throw KeyImportError.passphrase
        }
        var pr = Reader(try r.blob())
        let check1 = try pr.uint32()
        guard check1 == (try pr.uint32()) else { throw KeyImportError.malformed }
        let type = try pr.string()
        switch type {
        case "ssh-ed25519":
            _ = try pr.blob()  // public
            let priv = try pr.blob()
            guard priv.count == 64 else { throw KeyImportError.malformed }
            let comment = try pr.string()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: priv.prefix(32))
            return ImportedPrivateKey(material: .ed25519(key), comment: clean(comment))
        case "ecdsa-sha2-nistp256":
            _ = try pr.string()  // curve name
            _ = try pr.blob()  // Q
            var d = try pr.blob()
            while d.first == 0 { d.removeFirst() }  // mpint sign byte
            guard d.count <= 32 else { throw KeyImportError.malformed }
            d = Data(repeating: 0, count: 32 - d.count) + d
            let comment = try pr.string()
            let key = try P256.Signing.PrivateKey(rawRepresentation: d)
            return ImportedPrivateKey(material: .p256(key), comment: clean(comment))
        case "ssh-rsa":
            throw KeyImportError.rsa
        default:
            throw KeyImportError.unsupported(type)
        }
    }

    private static func clean(_ comment: String) -> String? {
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : c
    }

    private struct Reader {
        private let data: Data
        private var offset: Int
        init(_ data: Data) { self.data = Data(data); offset = 0 }

        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, offset + n <= data.count else { throw KeyImportError.malformed }
            defer { offset += n }
            return data.subdata(in: offset..<offset + n)
        }
        mutating func uint32() throws -> UInt32 {
            try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func blob() throws -> Data { try bytes(Int(try uint32())) }
        mutating func string() throws -> String {
            String(decoding: try blob(), as: UTF8.self)
        }
    }
}
