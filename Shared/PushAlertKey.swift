import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end encryption for push alerts: the app makes one key, gives it to each machine with
/// the relay secret, and the machine's bergr-notify encrypts the alert text with it. The relay
/// and Apple only see `{"e": …}`; the Notification Service Extension decrypts it on the phone.
///
/// Format of `e` (base64), version 2 (what bergr-notify makes now, standard library only):
/// 0x02 ‖ nonce (16) ‖ ciphertext ‖ tag (32). enc = HMAC-SHA256(key, "bergr-enc"), mac =
/// HMAC-SHA256(key, "bergr-mac"), with the whole 64-byte key; keystream block i =
/// HMAC-SHA256(enc, nonce ‖ uint32be(i)); ciphertext = plaintext XOR keystream; tag =
/// HMAC-SHA256(mac, 0x02 ‖ nonce ‖ ciphertext).
/// Version 1 (older helpers, still opened): iv (16) ‖ AES-256-CBC/PKCS7 ciphertext ‖ HMAC-SHA256
/// over iv ‖ ciphertext; the first 32 key bytes encrypt, the last 32 authenticate. It has no
/// version byte, so a blob starting with 0x02 is tried as v2 first, then as v1.
/// The plaintext is JSON `{"title": …, "body": …}`, plus `"q": {"title", "options", "keys"}` for a question.
nonisolated enum PushAlertKey {
    /// Where the key used to live (App Group defaults). Read once to migrate, then deleted.
    static let defaultsKey = "bergr.push.alertKey"
    static let keychainService = "dev.bergr.push.alertKey"

    /// The key, made on first use and kept in the keychain, in the App Group's access group: iOS
    /// treats an App Group id as a keychain access group, so the app and the extension share the
    /// item without a keychain-access-groups entitlement (which would also change the default
    /// group the Secure Enclave keys live in).
    static func current() -> Data? {
        if let key = keychainKey() { return key }
        let defaults = BergrAppGroup.id.flatMap { UserDefaults(suiteName: $0) }
        if let key = defaults?.data(forKey: defaultsKey), key.count == 64 {
            // Kept in defaults too until the extension is confirmed to read the keychain item on a
            // device: losing the key there would break every alert silently.
            _ = storeInKeychain(key)
            return key
        }
        var key = Data(count: 64)
        let ok = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 64, $0.baseAddress!) } == errSecSuccess
        guard ok else { return nil }
        if !storeInKeychain(key) {
            // No usable keychain (an unsigned build): keep the old place rather than lose the key.
            guard let defaults else { return nil }
            defaults.set(key, forKey: defaultsKey)
        }
        return key
    }

    /// The key without making one (for the extension). Falls back to the old defaults copy until
    /// the app has migrated it.
    static func stored() -> Data? {
        if let key = keychainKey() { return key }
        guard let id = BergrAppGroup.id, let key = UserDefaults(suiteName: id)?.data(forKey: defaultsKey),
              key.count == 64 else { return nil }
        return key
    }

    private static func keychainQuery() -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #else
        if let group = BergrAppGroup.id { query[kSecAttrAccessGroup as String] = group }
        #endif
        return query
    }

    private static func keychainKey() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let key = out as? Data, key.count == 64 else { return nil }
        return key
    }

    private static func storeInKeychain(_ key: Data) -> Bool {
        var query = keychainQuery()
        query[kSecValueData as String] = key
        // After first unlock: the extension runs while the phone is locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    struct Alert: Codable, Equatable {
        var title: String
        var body: String
        /// The question of a blocked agent, when the helper knows it (answer buttons).
        var q: AnswerQuestion?
    }

    /// Decrypts an `e` blob; nil if it was changed, made with another key, or isn't one.
    static func decrypt(_ blob: Data, key: Data) -> Alert? {
        guard key.count == 64 else { return nil }
        if blob.first == 2, let alert = decryptV2(blob, key: key) { return alert }
        return decryptV1(blob, key: key)
    }

    static func decryptV2(_ blob: Data, key: Data) -> Alert? {
        guard key.count == 64, blob.count >= 1 + 16 + 32, blob.first == 2 else { return nil }
        let (enc, mac) = derivedKeys(key)
        let signed = blob.prefix(blob.count - 32), tag = blob.suffix(32)
        // isValidAuthenticationCode compares in constant time.
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: signed, using: mac) else { return nil }
        let nonce = Data(signed.dropFirst().prefix(16)), cipher = Data(signed.dropFirst(17))
        return try? JSONDecoder().decode(Alert.self, from: xor(cipher, keystream: enc, nonce: nonce))
    }

    private static func decryptV1(_ blob: Data, key: Data) -> Alert? {
        guard blob.count >= 16 + 16 + 32 else { return nil }
        let encKey = key.prefix(32), macKey = key.suffix(32)
        let signed = blob.prefix(blob.count - 32), mac = blob.suffix(32)
        let expected = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: macKey))
        guard Data(expected) == mac else { return nil }  // HMAC's == is constant-time
        let iv = signed.prefix(16), cipher = signed.dropFirst(16)
        guard let plain = cbc(CCOperation(kCCDecrypt), Data(cipher), key: Data(encKey), iv: Data(iv)) else { return nil }
        return try? JSONDecoder().decode(Alert.self, from: plain)
    }

    /// Encrypts (v2) like bergr-notify does (for tests and for symmetry).
    static func encrypt(_ alert: Alert, key: Data, nonce: Data? = nil) -> Data? {
        guard key.count == 64, let plain = try? JSONEncoder().encode(alert) else { return nil }
        var nonce = nonce ?? Data(count: 16)
        if nonce.count != 16 { return nil }
        if nonce == Data(count: 16) {
            _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        }
        let (enc, mac) = derivedKeys(key)
        let signed = Data([2]) + nonce + xor(plain, keystream: enc, nonce: nonce)
        return signed + Data(HMAC<SHA256>.authenticationCode(for: signed, using: mac))
    }

    /// Version 1 encryption, kept so tests can check that old helpers' blobs still open.
    static func encryptV1(_ alert: Alert, key: Data, iv: Data) -> Data? {
        guard key.count == 64, iv.count == 16, let plain = try? JSONEncoder().encode(alert),
              let cipher = cbc(CCOperation(kCCEncrypt), plain, key: Data(key.prefix(32)), iv: iv) else { return nil }
        let signed = iv + cipher
        return signed + Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: key.suffix(32))))
    }

    private static func derivedKeys(_ key: Data) -> (enc: SymmetricKey, mac: SymmetricKey) {
        let root = SymmetricKey(data: key)
        let enc = HMAC<SHA256>.authenticationCode(for: Data("bergr-enc".utf8), using: root)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("bergr-mac".utf8), using: root)
        return (SymmetricKey(data: Data(enc)), SymmetricKey(data: Data(mac)))
    }

    private static func xor(_ input: Data, keystream enc: SymmetricKey, nonce: Data) -> Data {
        var out = Data(capacity: input.count)
        var block: UInt32 = 0
        var offset = 0
        while offset < input.count {
            let message = nonce + withUnsafeBytes(of: block.bigEndian) { Data($0) }
            let stream = Data(HMAC<SHA256>.authenticationCode(for: message, using: enc))
            for (i, byte) in input.dropFirst(offset).prefix(32).enumerated() { out.append(byte ^ stream[i]) }
            offset += 32
            block += 1
        }
        return out
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
