import Foundation
import Testing
import UserNotifications
@testable import bergr

struct SnoozeTests {
    @Test func existingActionIdsAreUnchanged() throws {
        let two = try #require(AnswerCategory.categories().first { $0.identifier == "bergr.answer.2" })
        let ids = two.actions.map(\.identifier)
        #expect(Array(ids.prefix(3)) == ["bergr.answer.action.0", "bergr.answer.action.1", AnswerCategory.replyAction])
        #expect(ids.last == "bergr.snooze.action")
        #expect(AnswerCategory.index(ofAction: AnswerCategory.snoozeAction) == nil)
        let reply = try #require(AnswerCategory.categories().first { $0.identifier == "bergr.reply" })
        #expect(reply.actions.map(\.identifier) == [AnswerCategory.replyAction])
    }

    @Test func snoozeReschedulesTheSameContentInAnHour() throws {
        let content = UNMutableNotificationContent()
        content.title = "Claude needs you on mac"
        content.body = "Run ls?"
        content.threadIdentifier = "t1"
        content.categoryIdentifier = "bergr.answer.remote.2"
        content.userInfo = ["address": "t1", "host": "h", AnswerCategory.answerIDKey: String(repeating: "a", count: 32)]
        let request = AnswerCategory.snoozeRequest(from: content, id: "x")
        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 3600 && !trigger.repeats)
        #expect(request.content.title == content.title && request.content.body == content.body)
        #expect(request.content.threadIdentifier == "t1")
        // The expired answerID is dropped and the buttons fall back to opening the app.
        #expect(request.content.categoryIdentifier == "bergr.answer.2")
        #expect(request.content.userInfo[AnswerCategory.answerIDKey] == nil)
        #expect(request.content.userInfo["address"] as? String == "t1")
    }
}
