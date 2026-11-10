// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import CryptoKit
import Foundation

/// OpenSSH wire-format helpers for ECDSA P-256 public keys.
public enum OpenSSH {
    public static let ecdsaP256KeyType = "ecdsa-sha2-nistp256"

    /// The SSH public key blob: string(type) || string("nistp256") || string(Q).
    public static func publicKeyBlob(_ key: P256.Signing.PublicKey) -> Data {
        var blob = Data()
        appendString(Data(ecdsaP256KeyType.utf8), to: &blob)
        appendString(Data("nistp256".utf8), to: &blob)
        appendString(key.x963Representation, to: &blob)
        return blob
    }

    public static let ed25519KeyType = "ssh-ed25519"

    /// string("ssh-ed25519") || string(32-byte key).
    public static func publicKeyBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        var blob = Data()
        appendString(Data(ed25519KeyType.utf8), to: &blob)
        appendString(key.rawRepresentation, to: &blob)
        return blob
    }

    /// A line for `authorized_keys`: `ssh-ed25519 AAAA… comment`.
    public static func authorizedKeysLine(_ key: Curve25519.Signing.PublicKey, comment: String?) -> String {
        line(type: ed25519KeyType, blob: publicKeyBlob(key), comment: comment)
    }

    static func line(type: String, blob: Data, comment: String?) -> String {
        var line = "\(type) \(blob.base64EncodedString())"
        if let comment, !comment.isEmpty {
            line += " " + comment.replacingOccurrences(of: "\n", with: " ")
        }
        return line
    }

    /// A line for `authorized_keys`: `ecdsa-sha2-nistp256 AAAA… comment`.
    public static func authorizedKeysLine(_ key: P256.Signing.PublicKey, comment: String?) -> String {
        var line = "\(ecdsaP256KeyType) \(publicKeyBlob(key).base64EncodedString())"
        if let comment, !comment.isEmpty {
            // Comments may hold spaces, but not line breaks.
            line += " " + comment.replacingOccurrences(of: "\n", with: " ")
        }
        return line
    }

    /// `SHA256:…` as `ssh-keygen -l` prints it.
    public static func sha256Fingerprint(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Fingerprint of any OpenSSH public key line (`type base64 [comment]`), or nil if malformed.
    public static func sha256Fingerprint(publicKeyLine: String) -> String? {
        let parts = publicKeyLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return sha256Fingerprint(blob: blob)
    }

    private static func appendString(_ bytes: Data, to data: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
