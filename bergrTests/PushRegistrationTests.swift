import Foundation
import Testing
@testable import bergr

struct PushRegistrationTests {
    @Test func tokenIsLowercaseHex() {
        #expect(PushRegistration.hex(Data([0x00, 0xAB, 0x0F, 0xFF])) == "00ab0fff")
    }

    @Test func payloadCarriesDevice() throws {
        let data = PushRegistration.payload(token: "ab12", enabled: true, bundleID: "com.example.bergr", name: "Phone")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["op"] as? String == "add")
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["token"] as? String == "ab12")
        #expect(device["bundle_id"] as? String == "com.example.bergr")
        #expect(device["name"] as? String == "Phone")
        #expect(device["sandbox"] is Bool)
        let removed = PushRegistration.payload(token: "ab12", enabled: false, bundleID: nil, name: "Phone")
        #expect((try JSONSerialization.jsonObject(with: removed) as? [String: Any])?["op"] as? String == "remove")
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
}
