import Foundation
import Testing
@testable import bergr

struct PushAlertKeyTests {
    let key = Data(0..<64)

    @Test func roundTrip() throws {
        let blob = try #require(PushAlertKey.encrypt(.init(title: "Claude needs you", body: "Allow rm? ü"), key: key))
        #expect(PushAlertKey.decrypt(blob, key: key) == .init(title: "Claude needs you", body: "Allow rm? ü"))
    }

    @Test func tamperedBlobIsRejected() throws {
        var blob = try #require(PushAlertKey.encrypt(.init(title: "T", body: "B"), key: key))
        blob[20] ^= 1
        #expect(PushAlertKey.decrypt(blob, key: key) == nil)
    }

    @Test func wrongKeyIsRejected() throws {
        let blob = try #require(PushAlertKey.encrypt(.init(title: "T", body: "B"), key: key))
        #expect(PushAlertKey.decrypt(blob, key: Data((0..<64).map { UInt8(63 - $0) })) == nil)
    }

    /// Made by bergr-notify.py's encrypt_alert (same vector in scripts/test_bergr_notify.py).
    @Test func pythonVector() throws {
        let blob = try #require(Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODxNVq97wh/GLkAxEMJ7AXen/gWiU2YHklMcDCLwbK3tmDUM82gsiA4U1kYZzXM+PU6MMSTcmxMr/pFssU3PRmdc="))
        #expect(PushAlertKey.decrypt(blob, key: key) == .init(title: "T", body: "B"))
    }
}
