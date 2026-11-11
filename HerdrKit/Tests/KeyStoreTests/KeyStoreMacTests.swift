import Foundation
import Testing

@testable import KeyStore

// Mac specifics: access flags, a build without the keychain entitlement, and ~/.ssh discovery.

@Test func macUsesUserPresenceInsteadOfBiometryOnly() {
    #expect(KeyStore.accessFlags(requireBiometry: true, isMac: true) == [.privateKeyUsage, .userPresence])
    #expect(KeyStore.accessFlags(requireBiometry: true, isMac: false) == [.privateKeyUsage, .biometryCurrentSet])
    #expect(KeyStore.accessFlags(requireBiometry: false, isMac: true) == [.privateKeyUsage])
}

@Test func missingEntitlementMapsToKeysUnavailable() {
    let error = KeyStoreError.keychain(status: -34018)
    #expect(error.isKeychainUnavailable)
    #expect(error.localizedDescription.contains("unavailable in this build"))
    #expect(!KeyStoreError.keychain(status: -25300).isKeychainUnavailable)
}

/// A storage that fails like an unsigned Mac build.
private struct NoEntitlementStorage: KeyStorage {
    func loadAll() throws -> [Data] { throw KeyStoreError.keychain(status: -34018) }
    func save(_ data: Data, account: String) throws { throw KeyStoreError.keychain(status: -34018) }
    func delete(account: String) throws { throw KeyStoreError.keychain(status: -34018) }
}

@Test func unsignedBuildFailsCleanly() throws {
    let store = KeyStore(storage: NoEntitlementStorage())
    #expect(throws: KeyStoreError.self) { try store.keys() }
    let parsed = try PrivateKeyImporter.parse(edKey)
    do {
        _ = try store.importKey(parsed)
        Issue.record("should throw")
    } catch let error as KeyStoreError {
        #expect(error.isKeychainUnavailable)
    }
}

@Test func importToleratesCRLFAndSurroundingSpace() throws {
    let crlf = "\n  " + edKey.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
    #expect(try PrivateKeyImporter.parse(crlf).comment == "test-ed")
    #expect(throws: KeyImportError.notAKey) { try PrivateKeyImporter.parse(edPub) }
    #expect(throws: KeyImportError.malformed) {
        try PrivateKeyImporter.parse("-----BEGIN OPENSSH PRIVATE KEY-----\n!!!!\n-----END OPENSSH PRIVATE KEY-----")
    }
}

@Test func sshFolderListsOnlyPrivateKeys() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sshfolder-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try edKey.write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
    try edPub.write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
    try pwKey.write(to: dir.appendingPathComponent("id_locked"), atomically: true, encoding: .utf8)
    try rsaKey.write(to: dir.appendingPathComponent("id_rsa"), atomically: true, encoding: .utf8)
    try "Host x".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    try "x ssh-ed25519 AAAA".write(to: dir.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
    let found = SSHFolder.discover(in: dir)
    #expect(found.map(\.name) == ["id_ed25519", "id_locked", "id_rsa"])
    #expect(found[0].status == .importable(.ed25519, comment: "test-ed"))
    guard case .unusable = found[1].status, case .unusable = found[2].status else {
        Issue.record("expected unusable")
        return
    }
    #expect(SSHFolder.discover(in: dir.appendingPathComponent("missing")).isEmpty)
}
