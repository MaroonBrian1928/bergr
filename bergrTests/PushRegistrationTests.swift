import Foundation
import Testing
@testable import bergr

struct PushRegistrationTests {
    @Test func tokenIsLowercaseHex() {
        #expect(PushRegistration.hex(Data([0x00, 0xAB, 0x0F, 0xFF])) == "00ab0fff")
    }

    @Test func payloadCarriesRelaySecretNotToken() throws {
        let relay = URL(string: "https://relay.example")!
        let data = PushRegistration.payload(token: "ab12", secret: "s3cret", enabled: true, relay: relay, name: "Phone")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["op"] as? String == "add")
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["token"] == nil)
        #expect(device["secret"] as? String == "s3cret")
        #expect(device["relay"] as? String == "https://relay.example")
        #expect(device["id"] as? String == PushRegistration.deviceID(token: "ab12"))
        #expect(device["name"] as? String == "Phone")
        let removed = PushRegistration.payload(token: "ab12", secret: "s3cret", enabled: false, relay: relay, name: "Phone")
        #expect((try JSONSerialization.jsonObject(with: removed) as? [String: Any])?["op"] as? String == "remove")
    }

    @Test func deviceIDIsStableAndHidesToken() {
        #expect(PushRegistration.deviceID(token: "ab12") == PushRegistration.deviceID(token: "ab12"))
        #expect(PushRegistration.deviceID(token: "ab12").count == 16)
        #expect(PushRegistration.deviceID(token: "ab12") != PushRegistration.deviceID(token: "ab13"))
    }

    @Test func commandEncodesScriptAndPayload() throws {
        let payload = Data("{\"x\":1}".utf8)
        let parts = PushRegistration.command(payload: payload).split(separator: " ")
        #expect(parts.prefix(3) == ["python3", "-I", "-c"])
        let args = parts.suffix(2)
        let script = try #require(Data(base64Encoded: String(args.first!)))
        #expect(String(decoding: script, as: UTF8.self) == PushRegistration.mergeScript)
        #expect(Data(base64Encoded: String(args.last!)) == payload)
    }

    @MainActor @Test func parsesVersionLine() {
        #expect(PushRegistration.version(in: "import os\nVERSION = 7\nx = 1") == 7)
        #expect(PushRegistration.version(in: "# VERSION = 3\n") == nil)
        #expect((PushRegistration.bundledVersion ?? 0) >= 1)
    }

    @Test func declineSetRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "PushRegistrationTests.\(UUID())"))
        let a = UUID(), b = UUID()
        #expect(PushRegistration.declinedHosts(defaults).isEmpty)
        PushRegistration.setDeclined(true, host: a, defaults: defaults)
        PushRegistration.setDeclined(true, host: b, defaults: defaults)
        #expect(PushRegistration.declinedHosts(defaults) == [a.uuidString, b.uuidString])
        PushRegistration.setDeclined(false, host: a, defaults: defaults)
        #expect(PushRegistration.declinedHosts(defaults) == [b.uuidString])
    }

    @Test func installerCommandCarriesInstallerAndArgs() throws {
        let parts = PushRegistration.installerCommand(installer: "print(1)", op: "install", script: "VERSION = 1")
            .split(separator: " ")
        #expect(parts.prefix(3) == ["python3", "-I", "-c"])
        #expect(String(decoding: try #require(Data(base64Encoded: String(parts[parts.count - 2]))), as: UTF8.self) == "print(1)")
        let args = try #require(Data(base64Encoded: String(parts.last!)))
        let object = try #require(try JSONSerialization.jsonObject(with: args) as? [String: String])
        #expect(object == ["op": "install", "script": "VERSION = 1"])
    }

    @Test func payloadIncludesKeyOnlyWhenGiven() throws {
        let relay = URL(string: "https://relay.example")!
        let key = Data(repeating: 7, count: 64)
        func device(_ key: Data?) throws -> [String: Any] {
            let data = PushRegistration.payload(token: "ab12", secret: "s", enabled: true, relay: relay, name: "P", key: key)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(object["device"] as? [String: Any])
        }
        #expect(try device(key)["key"] as? String == key.base64EncodedString())
        #expect(try device(nil)["key"] == nil)
    }

    @Test func unsupportedReasons() {
        let windows = "Windows isn't supported yet"
        #expect(PushRegistration.unsupportedReason(uname: "Linux", hasPython: true) == nil)
        #expect(PushRegistration.unsupportedReason(uname: "Darwin", hasPython: true) == nil)
        #expect(PushRegistration.unsupportedReason(uname: nil, hasPython: true) == windows)
        #expect(PushRegistration.unsupportedReason(uname: "MINGW64_NT-10.0", hasPython: true) == windows)
        #expect(PushRegistration.unsupportedReason(uname: "Linux", hasPython: false) == "python3 isn't installed")
        let parsed = PushRegistration.parseProbe("Linux\n__python3__\n")
        #expect(parsed.uname == "Linux" && parsed.hasPython)
        #expect(PushRegistration.parseProbe("'uname' is not recognized as a command").uname == nil)
    }

    @Test func installQueueIsFIFOAndDedupes() {
        struct Item: Identifiable { let id: UUID; let tag: Int }
        let a = UUID(), b = UUID()
        var queue = PushRegistration.InstallQueue<Item>()
        let first = queue.enqueue(Item(id: a, tag: 1))
        let second = queue.enqueue(Item(id: b, tag: 2))
        let dup = queue.enqueue(Item(id: a, tag: 3))
        #expect(first && second && !dup)
        let p1 = queue.pop()
        #expect(p1?.tag == 1)
        #expect(queue.first?.tag == 2)
        let p2 = queue.pop()
        let p3 = queue.pop()
        #expect(p2?.tag == 2)
        #expect(p3 == nil)
    }
}
