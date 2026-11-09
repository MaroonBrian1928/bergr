import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end encryption for push alerts: the app makes one key, gives it to each machine with
/// the relay secret, and the machine's bergr-notify encrypts the alert text with it. The relay
/// and Apple only see `{"e": …}`; the Notification Service Extension decrypts it on the phone.
///
/// Format of `e` (base64): iv (16 bytes) ‖ AES-256-CBC/PKCS7 ciphertext ‖ HMAC-SHA256 (32 bytes)
/// over iv ‖ ciphertext. The key is 64 bytes: the first 32 encrypt, the last 32 authenticate.
/// The plaintext is JSON `{"title": …, "body": …}`. (CBC + HMAC because the machine side uses
/// the `openssl` command and Python's standard library, which have no AES-GCM.)
nonisolated enum PushAlertKey {
    static let defaultsKey = "bergr.push.alertKey"

    /// The key, made on first use and kept in the App Group, where the extension reads it.
    static func current() -> Data? {
        guard let id = BergrAppGroup.id, let defaults = UserDefaults(suiteName: id) else { return nil }
        if let key = defaults.data(forKey: defaultsKey), key.count == 64 { return key }
        var key = Data(count: 64)
        let ok = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) } == errSecSuccess
        guard ok else { return nil }
        defaults.set(key, forKey: defaultsKey)
        return key
    }

    /// The key without making one (for the extension).
    static func stored() -> Data? {
        guard let id = BergrAppGroup.id, let key = UserDefaults(suiteName: id)?.data(forKey: defaultsKey),
              key.count == 64 else { return nil }
        return key
    }

    struct Alert: Codable, Equatable {
        var title: String
        var body: String
    }

    /// Decrypts an `e` blob; nil if it was changed, made with another key, or isn't one.
    static func decrypt(_ blob: Data, key: Data) -> Alert? {
        guard key.count == 64, blob.count >= 16 + 16 + 32 else { return nil }
        let encKey = key.prefix(32), macKey = key.suffix(32)
        let signed = blob.prefix(blob.count - 32), mac = blob.suffix(32)
        let expected = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: macKey))
        guard Data(expected) == mac else { return nil }  // HMAC's == is constant-time
        let iv = signed.prefix(16), cipher = signed.dropFirst(16)
        guard let plain = cbc(CCOperation(kCCDecrypt), Data(cipher), key: Data(encKey), iv: Data(iv)) else { return nil }
        return try? JSONDecoder().decode(Alert.self, from: plain)
    }

    /// Encrypts like bergr-notify does (for tests and for symmetry).
    static func encrypt(_ alert: Alert, key: Data, iv: Data? = nil) -> Data? {
        guard key.count == 64, let plain = try? JSONEncoder().encode(alert) else { return nil }
        var iv = iv ?? Data(count: 16)
        if iv.count != 16 { return nil }
        if iv == Data(count: 16) {
            _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        }
        guard let cipher = cbc(CCOperation(kCCEncrypt), plain, key: Data(key.prefix(32)), iv: iv) else { return nil }
        let signed = iv + cipher
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: key.suffix(32)))
        return signed + Data(mac)
    }

    private static func cbc(_ op: CCOperation, _ input: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, kCCKeySizeAES256, v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}
