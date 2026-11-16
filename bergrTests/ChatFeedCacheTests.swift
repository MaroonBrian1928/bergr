import HerdrKit
import Testing
@testable import bergr

@MainActor
struct ChatFeedCacheTests {
    private func session() -> HostSession {
        HostSession(host: Host(name: "cache-test", target: SSHTarget(host: "unused", username: "test")),
                    knownHosts: UserDefaultsKnownHosts())
    }

    private func feed(_ address: String, in session: HostSession) -> ChatFeed {
        session.chatFeed(address: address, agent: .codex, pid: 0, cwd: "/unused", sessionHint: nil)
    }

    @Test func backgroundRequestsKeepVisibleFeedAndEvictHiddenFeed() {
        let session = session()
        defer { session.stop() }
        session.startLooking(at: "visible")
        let visible = feed("visible", in: session)
        _ = feed("hidden-1", in: session)
        _ = feed("hidden-2", in: session)
        _ = feed("hidden-3", in: session)
        _ = feed("hidden-4", in: session)
        #expect(session.runningFeed(address: "visible") === visible)
        #expect((1...4).filter { session.runningFeed(address: "hidden-\($0)") != nil }.count == 3)
    }

    @Test func visibleFeedBecomesEvictableOnlyAfterLastViewerLeaves() {
        let session = session()
        defer { session.stop() }
        session.startLooking(at: "visible")
        session.startLooking(at: "visible")
        let visible = feed("visible", in: session)
        session.stopLooking(at: "visible")
        for i in 1...4 { _ = feed("hidden-\(i)", in: session) }
        #expect(session.runningFeed(address: "visible") === visible)
        for i in 1...4 where session.runningFeed(address: "hidden-\(i)") != nil {
            session.startLooking(at: "hidden-\(i)")
        }
        session.stopLooking(at: "visible")
        _ = feed("hidden-5", in: session)
        #expect(session.runningFeed(address: "visible") == nil)
    }

    @Test func allVisibleFeedsSurviveCapacityPressure() {
        let session = session()
        defer { session.stop() }
        for i in 1...4 {
            session.startLooking(at: "visible-\(i)")
            _ = feed("visible-\(i)", in: session)
        }
        _ = feed("background", in: session)
        for i in 1...4 { #expect(session.runningFeed(address: "visible-\(i)") != nil) }
    }
}
