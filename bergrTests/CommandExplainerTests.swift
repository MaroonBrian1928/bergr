import Foundation
import Testing
@testable import bergr

actor WriterRecorder {
    private(set) var prompts: [String] = []
    private(set) var timeouts: [Duration] = []

    func record(prompt: String, timeout: Duration) {
        prompts.append(prompt)
        timeouts.append(timeout)
    }
}

private struct FakeWriter: OnDeviceTextWriting {
    let reply: String?
    let recorder: WriterRecorder

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        await recorder.record(prompt: prompt, timeout: timeout)
        return reply
    }
}

struct CommandExplainerTests {
    @Test func dangerousCommandGetsItsExplanation() async {
        let recorder = WriterRecorder()
        let explainer = CommandExplainer(writer: FakeWriter(
            reply: "Deletes the build/ folder and everything in it, without asking.", recorder: recorder))

        let text = await explainer.explain("rm -rf build/")

        #expect(text == "Deletes the build/ folder and everything in it, without asking.")
        #expect(await recorder.prompts.count == 1)
        #expect(await recorder.prompts.first?.contains("rm -rf build/") == true)
        #expect(await recorder.timeouts == [.seconds(3)])
    }

    @Test func safeCommandNeverAsksTheModel() async {
        let recorder = WriterRecorder()
        let explainer = CommandExplainer(writer: FakeWriter(reply: "Lists files.", recorder: recorder))

        #expect(await explainer.explain("ls -la") == nil)
        #expect(await recorder.prompts.isEmpty)
    }

    @Test func noReplyFallsBackToNil() async {
        let recorder = WriterRecorder()
        let explainer = CommandExplainer(writer: FakeWriter(reply: nil, recorder: recorder))

        #expect(await explainer.explain("git push --force origin main") == nil)
        #expect(await recorder.prompts.count == 1)
    }

    @Test func outputSayingSafeIsDropped() async {
        let recorder = WriterRecorder()
        let explainer = CommandExplainer(writer: FakeWriter(
            reply: "Deletes build/, which is safe to do.", recorder: recorder))

        #expect(await explainer.explain("rm -rf build/") == nil)
    }

    @Test func overLongOutputIsDropped() {
        let long = Array(repeating: "word", count: CommandExplainer.maxWords + 1).joined(separator: " ")

        #expect(CommandExplainer.usable(long) == nil)
        #expect(CommandExplainer.usable(String(repeating: "word ", count: CommandExplainer.maxWords).trimmingCharacters(in: .whitespaces)) != nil)
    }

    @Test func emptyOutputIsDropped() {
        #expect(CommandExplainer.usable("   \n ") == nil)
    }
}
