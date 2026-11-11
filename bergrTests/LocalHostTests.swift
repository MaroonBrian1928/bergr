import Foundation
import HerdrKit
import SSHTransport
import Testing

@testable import bergr

struct LocalHostTests {
    @Test func hostDecodesWithoutLocal() throws {
        let host = Host(name: "Box", target: SSHTarget(host: "box", username: "me"))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        object.removeValue(forKey: "local")
        object.removeValue(forKey: "demo")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Host.self, from: old)
        #expect(!decoded.isLocal)
        #expect(decoded.local == nil)
    }

    @Test func localHostRoundTrips() throws {
        let host = Host.makeLocal()
        let decoded = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(host))
        #expect(decoded.isLocal)
        #expect(decoded.name == "This Mac")
        #expect(decoded.keyID == nil)
        #expect(decoded.subtitle.hasPrefix("This Mac"))
    }

    @Test func storeAddsThisMacOnceAndFirst() {
        let defaults = UserDefaults(suiteName: "LocalHostTests-\(UUID())")!
        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Box", target: SSHTarget(host: "box", username: "me")))
        #expect(!store.hasLocal)
        let first = store.addLocal()
        let second = store.addLocal()
        #expect(first.id == second.id)
        #expect(store.hosts.filter(\.isLocal).count == 1)
        #expect(store.hosts.first?.isLocal == true)
        #expect(HostStore(defaults: defaults).hasLocal)
    }

    @Test func locatesCoreOnPathThenKnownFolders() {
        let home = URL(fileURLWithPath: "/Users/me")
        let onPath = LocalCore.locate(path: "/usr/bin:/opt/x/bin", home: home) { $0 == "/opt/x/bin/herdr-core" }
        #expect(onPath?.path == "/opt/x/bin/herdr-core")
        let local = LocalCore.locate(path: "/usr/bin", home: home) { $0 == "/Users/me/.local/bin/herdr-core" }
        #expect(local?.path == "/Users/me/.local/bin/herdr-core")
        let brew = LocalCore.locate(path: nil, home: home) { $0 == "/opt/homebrew/bin/herdr-core" }
        #expect(brew?.path == "/opt/homebrew/bin/herdr-core")
        #expect(LocalCore.locate(path: "/usr/bin", home: home) { _ in false } == nil)
        // A relative PATH entry is never trusted.
        #expect(LocalCore.locate(path: "bin:.", home: home) { _ in true }?.path != "bin/herdr-core")
    }

    @Test func searchPathKeepsOrderAndAddsFoldersOnce() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(LocalCore.searchPath(path: "/usr/bin:/opt/homebrew/bin", home: home)
            == "/usr/bin:/opt/homebrew/bin:/Users/me/.local/bin:/usr/local/bin")
    }

    @Test func missingCoreIsNotRetried() {
        #expect(!HostSession.isRetryable(LocalCore.notInstalled))
    }

    @Test func systemSSHArguments() {
        let ok = SystemSSHTest.arguments(for: SSHTarget(host: "box", port: 2222, username: "me"))
        #expect(ok == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-p", "2222", "--", "me@box", "true"])
        #expect(SystemSSHTest.arguments(for: SSHTarget(host: "-oProxyCommand=x", username: "me")) == nil)
        #expect(SystemSSHTest.arguments(for: SSHTarget(host: "box", username: "-x")) == nil)
        #expect(SystemSSHTest.arguments(for: SSHTarget(host: "", username: "me")) == nil)
        #expect(SystemSSHTest.explain(status: 0, stderr: "") == .works)
        guard case .failed(let text) = SystemSSHTest.explain(status: 255, stderr: "me@box: Permission denied (publickey).")
        else { Issue.record("expected failure"); return }
        #expect(text.contains("ssh-agent"))
    }

    // MARK: Keys unavailable (unsigned build)

    private struct NoEntitlement: KeyStorage {
        func loadAll() throws -> [Data] { throw KeyStoreError.keychain(status: -34018) }
        func save(_ data: Data, account: String) throws { throw KeyStoreError.keychain(status: -34018) }
        func delete(account: String) throws { throw KeyStoreError.keychain(status: -34018) }
    }

    @Test func keyLibraryExplainsMissingEntitlementInsteadOfFailing() {
        let keys = KeyLibrary(store: KeyStore(storage: NoEntitlement()))
        #expect(keys.keys.isEmpty)
        #expect(keys.unavailableReason?.contains("unavailable in this build") == true)
        #expect(keys.generate(label: "x", requireBiometry: false) == nil)
        #expect(keys.lastError == nil)
        #expect(keys.importKey(text: "hello", label: "") != nil)
    }

    @Test func keyLibraryWorksWithAWorkingStore() {
        let keys = KeyLibrary(store: KeyStore(storage: InMemoryKeyStorage()))
        #expect(keys.unavailableReason == nil)
        #expect(keys.discoverSSHFolder().allSatisfy { !$0.name.hasSuffix(".pub") })
    }
}
