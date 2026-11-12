import Testing
@testable import bergr

@MainActor
struct ConnectionBarTests {
    @Test func connectingSaysReconnecting() {
        #expect(ConnectionBar.title(.connecting("laptop"), machine: "laptop") == "Reconnecting to laptop…")
    }

    @Test func failedWhileRetryingShowsReason() {
        let title = ConnectionBar.title(.failed("Can't reach laptop", retrying: true), machine: "laptop")
        #expect(title == "Reconnecting to laptop… (Can't reach laptop)")
    }

    @Test func failedNotRetryingShowsOnlyReason() {
        let title = ConnectionBar.title(.failed("Can't reach laptop", retrying: false), machine: "laptop")
        #expect(title == "Can't reach laptop")
    }
}
