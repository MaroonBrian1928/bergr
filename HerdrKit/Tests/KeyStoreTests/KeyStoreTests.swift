// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import CryptoKit
import Foundation
import Testing
@testable import KeyStore

@Test func generateListRenameDelete() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateKey(label: "phone")
    #expect(try store.keys().map(\.id) == [info.id])

    try store.rename(id: info.id, to: "iPhone")
    #expect(try store.keys().first?.label == "iPhone")

    let key = try store.signingKey(for: info.id)
    #expect(key.publicKey?.x963Representation == info.publicKeyX963)

    try store.deleteKey(id: info.id)
    #expect(try store.keys().isEmpty)
}

@Test func softwareKeySigns() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    // Force the software path so the test runs everywhere.
    let key = P256.Signing.PrivateKey()
    let record = StoredKey(
        info: SSHKeyInfo(id: UUID(), label: "sw", kind: .software, requiresBiometry: false,
                         createdAt: Date(), publicKeyX963: key.publicKey.x963Representation),
        keyData: key.rawRepresentation)
    let storage = InMemoryKeyStorage()
    try storage.save(try JSONEncoder().encode(record), account: record.info.id.uuidString)
    _ = store

    guard case .software(let loaded) = try KeyStore(storage: storage).signingKey(for: record.info.id) else {
        Issue.record("expected a software key")
        return
    }
    let message = Data("hello".utf8)
    #expect(key.publicKey.isValidSignature(try loaded.signature(for: message), for: message))
}

@Test(.enabled(if: KeyStore.isSecureEnclaveAvailable))
func secureEnclaveKeySigns() throws {
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.generateKey(label: "se", allowSoftwareFallback: false)
    #expect(info.kind == .secureEnclave)
    guard case .secureEnclave(let key) = try store.signingKey(for: info.id) else {
        Issue.record("expected a Secure Enclave key")
        return
    }
    let message = Data("hello".utf8)
    #expect(info.publicKey!.isValidSignature(try key.signature(for: message), for: message))
}

#if os(macOS)
/// Our authorized_keys line and fingerprint must match what ssh-keygen says about it.
@Test func matchesSSHKeygen() throws {
    let info = SSHKeyInfo(id: UUID(), label: "my phone", kind: .software, requiresBiometry: false,
                          createdAt: Date(), publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-\(UUID()).pub")
    try info.authorizedKeysLine.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-l", "-E", "sha256", "-f", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(process.terminationStatus == 0)
    // "256 SHA256:… my phone (ECDSA)"
    #expect(out.hasPrefix("256 \(info.fingerprint) my phone (ECDSA)"), "ssh-keygen said: \(out)")
}
#endif

// MARK: - Key import

let edKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCRbshhCTzdiIUgm3HvJd6m+MElZ4UL/DlBq323BgcEWgAAAJCaThKnmk4S
pwAAAAtzc2gtZWQyNTUxOQAAACCRbshhCTzdiIUgm3HvJd6m+MElZ4UL/DlBq323BgcEWg
AAAEDm6ppStPcxzMbuCmNYr0dS8lEROG8siuJIntic1P8135FuyGEJPN2IhSCbce8l3qb4
wSVnhQv8OUGrfbcGBwRaAAAAB3Rlc3QtZWQBAgMEBQY=
-----END OPENSSH PRIVATE KEY-----
"""
let edPub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFuyGEJPN2IhSCbce8l3qb4wSVnhQv8OUGrfbcGBwRa test-ed"
private let ecKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQP0ieLjTd4uE5/dy54M9C+s5gha/DZ
b/0MTQEqeA0XIjdU0BYyu9q94ojXM1jUXK/wkb/KtZ7JxRD4jXQCEzuNAAAAoLwkDOa8JA
zmAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBA/SJ4uNN3i4Tn93
Lngz0L6zmCFr8Nlv/QxNASp4DRciN1TQFjK72r3iiNczWNRcr/CRv8q1nsnFEPiNdAITO4
0AAAAhAJzDoqIEOkMMSd6IacjvdcpiC+KaPxSYd2NpzIXuPDhzAAAAB3Rlc3QtZWM=
-----END OPENSSH PRIVATE KEY-----
"""
private let ecPub = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBA/SJ4uNN3i4Tn93Lngz0L6zmCFr8Nlv/QxNASp4DRciN1TQFjK72r3iiNczWNRcr/CRv8q1nsnFEPiNdAITO40= test-ec"
let pwKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD/XtgSU4
YYEliUTzhuVRUwAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIE7JCvPvqAdUIeKU
iQ81xuvgFPFFDxDY5diX5NGSXh0FAAAAkPc31sCQRObl/BM3xfzfjLkKAG5uD0RpQuLLNo
Kf85d7M5w7FQu1ieu1OnsmCd5r5Wr1EQpvyRSepfss6FW1thgMEclxwDFyPpuyU6jT/pQ4
gEF0+AOQbedEAopiEuwPY2K/iO4W4whPqxMryCc5xhZjY4Zw8xqJfkMPQKrk2N9RcuiyfC
6hq+MgUOixiJmKpg==
-----END OPENSSH PRIVATE KEY-----
"""
let rsaKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEAtz6DXpla1zaWNuuoIqtsjzOVHnv3hfHefdrse+dLz5/uodEEaSeN
NFNhTpoffCOdJZfFZKoPrLlQjE/k0DWWCdiGs45/O/yuAyXPNzf02h27iqZlS/91liLI4j
/NNlOu7czPbmJnuoPGL6yXBkE+Amxm2GBs6FAbBtkW9E9ya7uNlY19hZnotfelgjj8Amdv
7s2LEWLVl0Glfk82PwmAKrPHOCdO5RMFmgWS0T3BgIFMRGeit8Qq0/+BzrjcaSjPT15kJ6
Br7dwzXhY41RLLGCdVMXpb2IJG54LXPAhIbYQXG1SLTCC4jLICDvKreI3Zn+Kb8vFVF8PI
CQ8isAJzMQAAA8DdgIOv3YCDrwAAAAdzc2gtcnNhAAABAQC3PoNemVrXNpY266giq2yPM5
Uee/eF8d592ux750vPn+6h0QRpJ400U2FOmh98I50ll8Vkqg+suVCMT+TQNZYJ2Iazjn87
/K4DJc83N/TaHbuKpmVL/3WWIsjiP802U67tzM9uYme6g8YvrJcGQT4CbGbYYGzoUBsG2R
b0T3Jru42VjX2Fmei196WCOPwCZ2/uzYsRYtWXQaV+TzY/CYAqs8c4J07lEwWaBZLRPcGA
gUxEZ6K3xCrT/4HOuNxpKM9PXmQnoGvt3DNeFjjVEssYJ1UxelvYgkbngtc8CEhthBcbVI
tMILiMsgIO8qt4jdmf4pvy8VUXw8gJDyKwAnMxAAAAAwEAAQAAAQAOtQm+MfjEhTERP2DD
R5by92TkiXaYXY1J9KQ+XZYMF/4DJs9/0RjYNkj9Egms4P7f4YqKRcv0RPteB5uJyoM8Tx
CgoLM9kU42GnbDK86PIwvGWQyQSPSbFDejURObZKQJmgKcDXHd2m2xrdyBOANOFn06qKKV
ErjYl9vrx+SbGNOV7kuuoSGscQYyIgTbhxcUbbye+k7t1oeU4d/mbA31AOEdACcFt0p5WX
AGgn003IpgOeXUVcMnzkI0RjEi5yIeFgsoJwmoJNjWCj+8XYS1s9bh4XdZAp+WnnJXHr+k
LtXfCSGoSnEHG4f24i/8lTGBh5QH7oPn/W8W8U1qhDdxAAAAgQCmWclPRDTy8DDZzEhWEB
NtJqLP6WlAE1SFJYoTfCU4x+20OdugvIxeoJcdi9QdH4FyadhyxnPiao/RM5xgKVUWrflc
okv2oDIlPYHSwi/e8wnnMPbQGU1cNgZwA0hmVIDd9AySP7MB+2TH1h99VRmv8sUf9MaqEm
hMEsnghILEpQAAAIEA77zFTBFKhFCHWjnLD1Vg2B6cuXYoz6qfbxa75w7Ljg1JAswc6zpC
j1cp7K+B18a2VXQlzphqVPekmrNV3rGSOUDKjZfaJpNKfJFyImgyN2vluVQUPaQvUtZANR
6dHC+QzQLIbaxmrvjJ+QpQ4a7N/6W3Ag/5n4de0FYMRkVU4eMAAACBAMOssYg8NB9ncuQl
LrQk8v+Zcl+vhnA19K+3hEf4kQ3m9tTgyPoPvS4BQZe6btW0pW25RZ9Bokernffrq+0dx8
orxWuTwYK3gLq/QLdLuJ2jqe1Zx8k0bDt0DpudRK/lQHnlM4EI2O1GNAEdDnkOm4o4zbDh
3sxp+lRY21L709LbAAAAA3JzYQECAwQFBgc=
-----END OPENSSH PRIVATE KEY-----
"""

@Test func importEd25519() throws {
    let imported = try PrivateKeyImporter.parse(edKey)
    #expect(imported.comment == "test-ed")
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.importKey(imported)
    #expect(info.label == "test-ed")
    #expect(info.kind == .imported)
    #expect(info.authorizedKeysLine == edPub)
    #expect(info.fingerprint == OpenSSH.sha256Fingerprint(publicKeyLine: edPub))
    guard case .ed25519(let key) = try store.signingKey(for: info.id) else { Issue.record("wrong kind"); return }
    #expect(key.publicKey.rawRepresentation == info.publicKeyX963)
}

@Test func importEcdsa() throws {
    let imported = try PrivateKeyImporter.parse(ecKey)
    let store = KeyStore(storage: InMemoryKeyStorage())
    let info = try store.importKey(imported, label: "mine")
    #expect(info.label == "mine")
    #expect(info.authorizedKeysLine == ecPub.replacingOccurrences(of: "test-ec", with: "mine"))
    #expect(try store.signingKey(for: info.id).publicKey?.x963Representation == info.publicKeyX963)
}

@Test func importPem() throws {
    let key = P256.Signing.PrivateKey()
    let imported = try PrivateKeyImporter.parse(key.pemRepresentation)
    guard case .p256(let got) = imported.material else { Issue.record("wrong kind"); return }
    #expect(got.publicKey.x963Representation == key.publicKey.x963Representation)
}

@Test func importErrors() {
    #expect(throws: KeyImportError.passphrase) { try PrivateKeyImporter.parse(pwKey) }
    #expect(throws: KeyImportError.rsa) { try PrivateKeyImporter.parse(rsaKey) }
    #expect(throws: KeyImportError.empty) { try PrivateKeyImporter.parse("  \n") }
    #expect(throws: KeyImportError.notAKey) { try PrivateKeyImporter.parse("hello") }
}

@Test func oldRecordDecodes() throws {
    let key = P256.Signing.PrivateKey()
    let old = """
    {"id":"00000000-0000-0000-0000-000000000001","label":"old","kind":"software","requiresBiometry":false,\
    "createdAt":0,"publicKeyX963":"\(key.publicKey.x963Representation.base64EncodedString())"}
    """
    let info = try JSONDecoder().decode(SSHKeyInfo.self, from: Data(old.utf8))
    #expect(info.algorithm == .p256)
    #expect(info.publicKey?.x963Representation == key.publicKey.x963Representation)
}
