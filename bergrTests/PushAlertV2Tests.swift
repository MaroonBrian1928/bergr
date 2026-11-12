import Foundation
import Testing
@testable import bergr

struct PushAlertV2Tests {
    let key = Data(0..<64)

    /// Made by bergr-notify.py's encrypt_alert (same vector in scripts/test_bergr_notify.py):
    /// key 0..63, nonce 0..15, title "T", body "B".
    static let vector = "AgABAgMEBQYHCAkKCwwNDg8BGrgqFxuhYcg/RAosGAW89KEcGJy32QB42sNYgJdhGxLagnREd3oaxkvJy0KpFqLcQfc5fD/rqQ=="

    @Test func pythonVectorDecrypts() throws {
        let blob = try #require(Data(base64Encoded: Self.vector))
        #expect(PushAlertKey.decrypt(blob, key: key) == .init(title: "T", body: "B"))
    }

    @Test func tamperedBlobIsRejected() throws {
        let blob = try #require(Data(base64Encoded: Self.vector))
        for index in [0, 5, 20, blob.count - 1] {
            var bad = blob
            bad[index] ^= 1
            #expect(PushAlertKey.decrypt(bad, key: key) == nil)
        }
        #expect(PushAlertKey.decrypt(blob, key: Data((0..<64).map { UInt8(63 - $0) })) == nil)
    }

    @Test func longTextRoundTrips() throws {
        let alert = PushAlertKey.Alert(title: "Claude hit an error on pop", body: String(repeating: "é", count: 300))
        let blob = try #require(PushAlertKey.encrypt(alert, key: key))
        #expect(blob.first == 2)
        #expect(PushAlertKey.decrypt(blob, key: key) == alert)
    }

    /// Old helpers (version 1, no version byte) still decrypt, even when the random IV starts with 0x02.
    @Test func oldFormatStillOpens() throws {
        let iv = Data([2] + Array(1..<16))
        let blob = try #require(PushAlertKey.encryptV1(.init(title: "T", body: "B"), key: key, iv: iv))
        #expect(PushAlertKey.decrypt(blob, key: key) == .init(title: "T", body: "B"))
    }
}
