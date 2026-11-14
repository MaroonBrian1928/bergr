import Foundation
import Testing
import UserNotifications
@testable import bergr

/// Answering from a notification through the relay. The envelope vector is shared with
/// RemoteAnswerTests in scripts/test_bergr_notify.py (bergrTests/answer-envelope-vector.json).
@MainActor
struct RemoteAnswerTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private let id = "0123456789abcdef0123456789abcdef"
    private let key = Data((0..<64).map { UInt8($0) })

    private func vector() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("bergrTests/answer-envelope-vector.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sharedVectorOpensAndSealsByteForByte() throws {
        let v = try vector()
        let key = Data(0..<64)  // see "keyBytes" in the vector file
        let nonce = try #require(Data(base64Encoded: v["nonce"] as! String))
        let machine = v["machine"] as! String, id = v["id"] as! String
        for c in v["cases"] as! [[String: Any]] {
            let expected: PushAlertKey.AnswerChoice = (c["choice"] as? String).map { $0 == "yes" ? .yes : .no }
                ?? .option(c["choice"] as! Int)
            let blob = try #require(Data(base64Encoded: c["e"] as! String))
            #expect(PushAlertKey.openAnswer(blob, machine: machine, answerID: id, key: key) == expected)
            #expect(PushAlertKey.sealAnswer(expected, machine: machine, answerID: id, key: key, nonce: nonce) == blob)
        }
    }

    @Test func tamperedOrRebound() throws {
        let blob = try #require(PushAlertKey.sealAnswer(.yes, machine: "M1", answerID: id, key: key))
        #expect(PushAlertKey.openAnswer(blob, machine: "M1", answerID: id, key: key) == .yes)
        var flipped = blob
        flipped[20] ^= 1
        #expect(PushAlertKey.openAnswer(flipped, machine: "M1", answerID: id, key: key) == nil)
        #expect(PushAlertKey.openAnswer(blob, machine: "M2", answerID: id, key: key) == nil)
        #expect(PushAlertKey.openAnswer(blob, machine: "M1", answerID: String(repeating: "f", count: 32), key: key) == nil)
        #expect(PushAlertKey.openAnswer(blob, machine: "M1", answerID: id, key: Data(count: 64)) == nil)
        // Two seals differ (fresh nonce).
        #expect(PushAlertKey.sealAnswer(.yes, machine: "M1", answerID: id, key: key) != blob)
    }

    @Test func alertCarriesAnswerID() throws {
        let alert = PushAlertKey.Alert(title: "t", body: "b", q: AnswerQuestion(title: "q", options: ["Yes", "No"], keys: true), a: id)
        let blob = try #require(PushAlertKey.encrypt(alert, key: key))
        #expect(PushAlertKey.decrypt(blob, key: key)?.a == id)
    }

    @Test func remoteCategoryIsBackgroundButLocked() throws {
        let q = AnswerQuestion(title: "Bash: ls", options: ["Yes", "No"], keys: true)
        #expect(AnswerCategory.pushCategory(question: q, address: "t1", answerID: id) == "bergr.answer.remote.2")
        #expect(AnswerCategory.pushCategory(question: q, address: "t1") == "bergr.answer.2")
        #expect(AnswerCategory.pushCategory(question: q, address: "t1", answerID: "short") == "bergr.answer.2")
        let remote = try #require(AnswerCategory.categories().first { $0.identifier == "bergr.answer.remote.2" })
        let yes = try #require(remote.actions.first { $0.identifier == AnswerCategory.actionIdentifier(index: 0) })
        #expect(!yes.options.contains(.foreground))
        #expect(yes.options.contains(.authenticationRequired))
        let old = try #require(AnswerCategory.categories().first { $0.identifier == "bergr.answer.2" })
        #expect(old.actions.first?.options.contains(.foreground) == true)
    }

    @Test func requestPicksUpAnswerIDAndMachine() throws {
        let q = AnswerQuestion(title: "Bash: ls", options: ["Yes", "No"], keys: true)
        var info: [AnyHashable: Any] = AnswerCategory.userInfo(q, answerID: id)
        info["host"] = "UUID-1"
        let host = UUID()
        let r = try #require(AnswerCategory.request(
            actionIdentifier: AnswerCategory.actionIdentifier(index: 1), info: info, target: (host, "t1")))
        #expect(r.answerID == id && r.machine == "UUID-1")
        #expect(RemoteAnswer.choice(question: q, index: 1) == .no)
    }

    private func request(answerID: String? = nil) -> AnswerNotificationRequest {
        AnswerNotificationRequest(
            host: UUID(), address: "t1", question: AnswerQuestion(title: "Bash: ls", options: ["Yes", "No"], keys: true),
            index: 0, answerID: answerID, machine: answerID == nil ? nil : "M1")
    }

    private final class Box { var sent: [String] = []; var foreground = 0; var failed = 0 }

    private func route(_ box: Box, version: Int?, ok: Bool) -> RemoteAnswerRoute {
        RemoteAnswerRoute(
            helperVersion: { _ in version },
            send: { machine, id, choice in box.sent.append("\(machine) \(id) \(choice)"); return ok },
            foreground: { _ in box.foreground += 1 },
            failed: { _ in box.failed += 1 })
    }

    @Test func relayedWhenPostSucceeds() async {
        let box = Box()
        #expect(await route(box, version: 21, ok: true).run(request(answerID: id)) == .relayed)
        #expect(box.sent == ["M1 \(id) yes"] && box.foreground == 0)
    }

    @Test func foregroundWhenPostFails() async {
        let box = Box()
        #expect(await route(box, version: 21, ok: false).run(request(answerID: id)) == .foreground)
        #expect(box.foreground == 1 && box.failed == 1)
    }

    @Test func foregroundWhenHelperTooOldOrNoAnswerID() async {
        let box = Box()
        #expect(await route(box, version: 19, ok: true).run(request(answerID: id)) == .foreground)
        #expect(await route(box, version: 21, ok: true).run(request()) == .foreground)
        #expect(box.sent.isEmpty && box.foreground == 2)
    }

    @Test func senderPostsSealedEnvelope() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        let sender = RemoteAnswerSender(
            relay: URL(string: "https://relay.test")!, secret: { "s3cret" }, key: { key },
            post: { seen = $0; return 204 })
        #expect(await sender.send(machine: "M1", answerID: id, choice: .no))
        let req = try #require(seen)
        #expect(req.url?.absoluteString == "https://relay.test/v1/answer")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String])
        #expect(body["machine"] == "M1" && body["id"] == id)
        #expect(!(String(data: req.httpBody!, encoding: .utf8)!.contains("\"no\"")))  // relay never sees the choice
        let blob = try #require(Data(base64Encoded: body["e"]!))
        #expect(PushAlertKey.openAnswer(blob, machine: "M1", answerID: id, key: key) == .no)
        let failing = RemoteAnswerSender(relay: URL(string: "https://relay.test")!, secret: { "s" }, key: { key }, post: { _ in 500 })
        #expect(await failing.send(machine: "M1", answerID: id, choice: .yes) == false)
    }

    @Test func helperVersionPersisted() throws {
        let defaults = try #require(UserDefaults(suiteName: "RemoteAnswerTests-\(UUID())"))
        let host = UUID()
        #expect(RemoteAnswer.helperVersion(host, defaults: defaults) == nil)
        RemoteAnswer.setHelperVersion(20, for: host, defaults: defaults)
        #expect(RemoteAnswer.helperVersion(host, defaults: defaults) == 20)
    }

    @Test func latestAnswerIDExpires() throws {
        let defaults = try #require(UserDefaults(suiteName: "RemoteAnswerTests-\(UUID())"))
        let t0 = Date(timeIntervalSince1970: 1000)
        RemoteAnswer.recordLatest(machine: "M1", address: "t1", answerID: id, now: t0, defaults: defaults)
        #expect(RemoteAnswer.latest(machine: "M1", address: "t1", now: t0.addingTimeInterval(60), defaults: defaults) == id)
        #expect(RemoteAnswer.latest(machine: "M1", address: "t1", now: t0.addingTimeInterval(601), defaults: defaults) == nil)
    }

    @Test func liveActivityAnswersOnlyYesOrNo() {
        func r(_ label: String, _ key: String) -> AnswerRequest {
            AnswerRequest(host: "H", address: "t1", question: "q", number: 1, label: label, key: key)
        }
        #expect(RemoteAnswer.intentChoice(r("Yes", "y")) == .yes)
        #expect(RemoteAnswer.intentChoice(r("No, and tell Claude", "")) == .no)
        #expect(RemoteAnswer.intentChoice(r("Esc", "esc")) == nil)
        #expect(RemoteAnswer.intentAnswer(r("Yes", "y"), helperVersion: 20, latest: { _, _ in id }) == nil)
        #expect(RemoteAnswer.intentAnswer(r("Yes", "y"), helperVersion: nil, latest: { _, _ in nil }) == nil)
        #expect(RemoteAnswer.intentAnswer(r("Yes", "y"), helperVersion: 21, latest: { _, _ in id })?.id == id)
    }

    @Test func importKeepsRemoteSource() {
        let json = #"[{"id":"0B0C9B5E-9E2A-4C6C-8C1B-3E3B8E9C0A11","at":1,"command":"Bash: ls","answer":"No","source":"notification-remote"}]"#
        let entries = AutoApprovalImport.entries(from: json, machine: "pop", existing: [])
        #expect(entries.first?.source == .notificationRemote && entries.first?.answer == "No")
    }
}
