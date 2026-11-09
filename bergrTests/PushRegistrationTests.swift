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
}
