import Foundation
import Testing
@testable import bergr

@MainActor
struct CoreUpdatesTests {
    let latest = CoreUpdates.Release(version: "0.1.22", generation: 1, notes: nil)

    @Test func offersOnlyANewerRelease() {
        #expect(CoreUpdates.newer(than: "0.1.20", latest: latest) == latest)
        #expect(CoreUpdates.newer(than: "0.1.22", latest: latest) == nil)
        #expect(CoreUpdates.newer(than: "0.2.0", latest: latest) == nil)
        #expect(CoreUpdates.newer(than: nil, latest: latest) == nil)
        #expect(CoreUpdates.newer(than: "0.1.20", latest: nil) == nil)
    }

    @Test func readsHerdrCoreErrors() {
        #expect(CoreUpdates.failure(#"{"error":{"hint":"","kind":"internal","message":"download failed"}}"#) == "download failed")
        #expect(CoreUpdates.failure(#"{"version":"0.1.22"}"#) == nil)
        #expect(CoreUpdates.failure("") == nil)
    }

    @Test func decodesLatestJSON() throws {
        let json = #"{"version":"0.1.22","generation":1,"notes":"**New**"}"#
        let release = try JSONDecoder().decode(CoreUpdates.Release.self, from: Data(json.utf8))
        #expect(release.version == "0.1.22" && release.generation == 1)
    }
}
