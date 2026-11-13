import Foundation
import HerdrKit
import Testing
@testable import bergr

@MainActor
struct DirectMigrationTests {
    func store() -> HostStore {
        HostStore(defaults: UserDefaults(suiteName: "mig-\(UUID().uuidString)")!)
    }

    func host(_ name: String, address: String? = nil) -> Host {
        Host(name: name, target: SSHTarget(host: address ?? "\(name).lan", username: "u"))
    }

    func machine(_ name: String, host: String? = nil) throws -> MachineView {
        let h = host.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(
            MachineView.self,
            from: Data("{\"name\":\"\(name)\",\"host\":\(h),\"state\":\"connected\",\"target\":null,\"version\":null}".utf8))
    }

    func candidate(_ name: String, parent: Host) -> DirectMigration.Candidate {
        .init(name: name, host: nil, target: nil, parentID: parent.id, parentName: parent.name)
    }

    func migration(_ store: HostStore, fail: Set<String> = [], reason: String = "nope") -> DirectMigration {
        DirectMigration(
            store: store,
            prepare: { Host(name: $0.name, target: SSHTarget(host: "\($0.name).lan", username: "u")) },
            test: { host, _ in fail.contains(host.name) ? reason : nil })
    }

    @Test func savesOnlyOnSuccessAndReportsReason() async {
        let s = store()
        let parent = host("parent")
        s.save(parent)
        let m = migration(s, fail: ["bad"], reason: "auth failed")
        await m.run([candidate("good", parent: parent), candidate("bad", parent: parent)])
        #expect(s.hosts.map(\.name) == ["parent", "good"])
        #expect(m.outcomes.map(\.result) == [.connected, .stayed("auth failed")])
    }

    @Test func failureLeavesStoreUnchanged() async {
        let s = store()
        let parent = host("parent")
        s.save(parent)
        let before = s.hosts
        let m = migration(s, fail: ["bad"])
        await m.run([candidate("bad", parent: parent)])
        #expect(s.hosts == before)
        #expect(m.outcomes.first?.result == .stayed("nope"))
    }

    @Test func insertsAfterParent() async {
        let s = store()
        let a = host("a"), b = host("b")
        s.save(a)
        s.save(b)
        let m = migration(s)
        await m.run([candidate("x", parent: a)])
        #expect(s.hosts.map(\.name) == ["a", "x", "b"])
    }

    @Test func skipsMachinesWithDirectHost() throws {
        let parent = host("parent")
        let direct = host("pop-os", address: "10.0.0.5")
        let parents = [DirectMigration.Parent(host: parent, connected: true,
                                              machines: [try machine("pop-os"), try machine("pi", host: "pi.lan")])]
        let found = DirectMigration.candidates(hosts: [parent, direct], parents: parents)
        #expect(found.map(\.name) == ["pi"])
        let byAddress = DirectMigration.candidates(hosts: [parent, host("other", address: "pi.lan")], parents: parents)
        #expect(byAddress.map(\.name) == ["pop-os"])
    }

    @Test func runSkipsMachineSavedMeanwhile() async {
        let s = store()
        let parent = host("parent")
        s.save(parent)
        s.save(host("late"))
        let m = migration(s)
        await m.run([candidate("late", parent: parent)])
        #expect(m.outcomes.isEmpty)
        #expect(s.hosts.count == 2)
    }

    @Test func ignoresDisconnectedAndDemoParents() throws {
        let parent = host("parent")
        let demo = Host.makeDemo()
        let found = DirectMigration.candidates(hosts: [parent, demo], parents: [
            .init(host: parent, connected: false, machines: [try machine("a")]),
            .init(host: demo, connected: true, machines: [try machine("b")]),
        ])
        #expect(found.isEmpty)
    }

    @Test func bannerShowsUntilDismissedAndReturnsWhenSetChanges() {
        let parent = host("parent")
        let one = [candidate("a", parent: parent)]
        let two = one + [candidate("b", parent: parent)]
        #expect(!DirectMigration.showBanner([], dismissedKey: nil))
        #expect(DirectMigration.showBanner(one, dismissedKey: nil))
        let key = DirectMigration.bannerKey(one)
        #expect(!DirectMigration.showBanner(one, dismissedKey: key))
        #expect(DirectMigration.showBanner(two, dismissedKey: key))
        #expect(!DirectMigration.showBanner(two.reversed(), dismissedKey: DirectMigration.bannerKey(two)))
    }
}
