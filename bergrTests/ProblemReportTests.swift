import Foundation
import Testing
@testable import bergr

struct ProblemReportTests {
    @Test func subjectIsTheFirstLine() {
        #expect(ProblemReport.subject("Chat keeps bouncing\nafter a while") == "Chat keeps bouncing")
        #expect(ProblemReport.subject("  ") == "Problem report")
    }

    @Test func issueURLStaysShortWithALongLog() {
        let log = (0..<200).map { "12:00:0\($0 % 10)  Connection: some-machine dropped, reconnecting [active] \($0)" }
        let url = ProblemReport.issueURL(description: "Drops", environment: "Bergr 1 · iOS · iPhone", log: log)
        #expect(url != nil)
        #expect(url!.absoluteString.count <= ProblemReport.issueURLLimit)
        #expect(url!.absoluteString.contains("199")) // the newest lines are kept
    }
}
