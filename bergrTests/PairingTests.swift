import CryptoKit
import Foundation
import HerdrKit
import SSHTransport
import Testing

@testable import bergr

struct PairingTests {
    private let relay = URL(string: "https://relay.example")!
    private let hostList = [PairingHost(name: "Box", host: "box.lan", port: 22, user: "me")]
    // A real ed25519 public key line.
    private var keyLine: String {
        OpenSSH.authorizedKeysLine(Curve25519.Signing.PrivateKey().publicKey, comment: "Brian's iPhone")
    }

    // MARK: payload

    @Test func payloadRoundTrips() throws {
        let offer = PairingOffer(relay: relay, hosts: hostList)
        let decoded = try PairingPayload.decode(offer.payload.encoded())
        #expect(decoded == offer.payload)
        #expect(decoded.v == 1)
        #expect(Base64URL.decode(decoded.token)?.count == 16)
        #expect(decoded.macPublicKey != nil)
        #expect(offer.mailboxURL?.absoluteString == "https://relay.example/pair/\(decoded.token)")
    }

    @Test func payloadHoldsOnlyTheListedFields() throws {
        let text = PairingOffer(relay: relay, hosts: hostList).payload.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["v", "relay", "token", "macKey", "hosts"])
    }

    @Test func tokensAreFresh() {
        #expect(PairingOffer(relay: relay, hosts: []).payload.token != PairingOffer(relay: relay, hosts: []).payload.token)
    }

    @Test func rejectsOtherVersionsAndJunk() throws {
        var payload = PairingOffer(relay: relay, hosts: hostList).payload
        payload.v = 2
        #expect(throws: PairingError.unsupportedVersion(2)) { try PairingPayload.decode(payload.encoded()) }
        #expect(throws: PairingError.notPairingCode) { try PairingPayload.decode("https://example.com") }
        payload.v = 1
        payload.relay = "http://relay.example"
        #expect(throws: PairingError.invalid("relay")) { try PairingPayload.decode(payload.encoded()) }
        payload.relay = relay.absoluteString
        payload.token = "short"
        #expect(throws: PairingError.invalid("token")) { try PairingPayload.decode(payload.encoded()) }
    }

    @Test func offerExpiresAfterFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1000)
        let offer = PairingOffer(relay: relay, hosts: [], now: start)
        #expect(!offer.isExpired(now: start.addingTimeInterval(299)))
        #expect(offer.isExpired(now: start.addingTimeInterval(300)))
    }

    // MARK: crypto

    @Test func sealOpenRoundTrip() throws {
        let offer = PairingOffer(relay: relay, hosts: [])
        let request = try PairingClient.request(line: keyLine, payload: offer.payload)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(request.httpMethod == "POST")
        #expect(!body.contains("ssh-ed25519"))
        #expect(try offer.open(body).hasPrefix("ssh-ed25519 "))
    }

    @Test func tamperedOrMisdirectedMessagesAreRejected() throws {
        let offer = PairingOffer(relay: relay, hosts: [])
        let key = try #require(offer.payload.macPublicKey)
        let sealed = try PairingSeal.seal(Data("hello".utf8), to: key, token: offer.payload.token)
        var bytes = try #require(Base64URL.decode(sealed))
        bytes[bytes.count - 20] ^= 1
        #expect(throws: PairingError.decryptionFailed) { try offer.open(Base64URL.encode(bytes)) }
        // Same key, other token (authenticated data).
        let other = try PairingSeal.seal(Data("hello".utf8), to: key, token: "AAAAAAAAAAAAAAAAAAAAAA")
        #expect(throws: PairingError.decryptionFailed) { try offer.open(other) }
        // Another Mac's offer.
        #expect(throws: PairingError.decryptionFailed) { try PairingOffer(relay: relay, hosts: []).open(sealed) }
        #expect(throws: PairingError.decryptionFailed) { try offer.open("not base64!") }
    }

    // MARK: key line

    @Test func pairedKeyChecksAndCleansTheLine() throws {
        let key = try #require(PairedKey(keyLine))
        #expect(key.comment == "Brians iPhone")
        #expect(!key.line.contains("'"))
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        #expect(PairedKey("ssh-ed25519 not-base64") == nil)
        #expect(PairedKey("ssh-rsa " + key.line.split(separator: " ")[1]) == nil) // type mismatch
        #expect(PairedKey("command=\"x\" " + key.line) == nil)
        #expect(PairedKey(key.line + "\nssh-ed25519 AAAA") == nil)
    }

    // MARK: host import

    @Test func importSkipsDuplicates() {
        let defaults = UserDefaults(suiteName: "PairingTests-\(UUID())")!
        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Old", target: SSHTarget(host: "Box.lan", port: 22, username: "me")))
        let key = UUID()
        let added = store.importPaired([
            PairingHost(name: "Box", host: "box.lan", port: 22, user: "me"),
            PairingHost(name: "Box 2222", host: "box.lan", port: 2222, user: "me"),
            PairingHost(name: "Root", host: "box.lan", port: 22, user: "root"),
            PairingHost(name: "Root again", host: "box.lan", port: 22, user: "root"),
        ], keyID: key)
        #expect(added == 2)
        #expect(store.hosts.map(\.name) == ["Old", "Box 2222", "Root"])
        #expect(store.hosts.last?.keyID == key)
        #expect(HostStore(defaults: defaults).hosts.count == 3)
    }

    // MARK: authorized_keys

    @Test func installCommandIsIdempotentAndQuoted() throws {
        let key = try #require(PairedKey(keyLine))
        let script = AuthorizedKeysInstall.script(for: key)
        #expect(script.contains("KEY='\(key.line)'"))
        #expect(script.contains("grep -qxF -- \"$KEY\""))
        #expect(script.contains("mkdir -m 700"))
        #expect(script.contains("chmod 600"))
        #expect(script == AuthorizedKeysInstall.script(for: key))
        let args = try #require(AuthorizedKeysInstall.arguments(for: hostList[0]))
        #expect(args.suffix(3) == ["--", "me@box.lan", "sh -s"])
        #expect(args.contains("BatchMode=yes"))
        #expect(AuthorizedKeysInstall.arguments(for: PairingHost(name: "x", host: "-oProxy", port: 22, user: "me")) == nil)
    }

    @Test func installOutcomes() {
        #expect(AuthorizedKeysInstall.outcome(status: 0, stdout: "BERGR_ADDED\n", stderr: "") == .added)
        #expect(AuthorizedKeysInstall.outcome(status: 0, stdout: "BERGR_PRESENT\n", stderr: "") == .alreadyPresent)
        #expect(AuthorizedKeysInstall.outcome(
            status: 1, stdout: "", stderr: "'sh' is not recognized as an internal or external command") == .skippedWindows)
        if case .failed = AuthorizedKeysInstall.outcome(status: 255, stdout: "", stderr: "Permission denied") {} else {
            Issue.record("expected failure")
        }
    }
}
