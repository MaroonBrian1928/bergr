import Testing
@testable import bergr

@MainActor
struct AutomationQueueTests {
    private func makeModel() -> TerminalScreenModel {
        TerminalScreenModel(theme: TerminalTheme.all[0])
    }

    @Test func sequencesRunOneAtATimeInOrder() async {
        let model = makeModel()
        var log: [String] = []
        let a = Task { @MainActor in await model.automate {
            log.append("a1")
            try? await Task.sleep(for: .milliseconds(50))
            log.append("a2")
        } }
        let b = Task { @MainActor in await model.automate {
            log.append("b1")
            log.append("b2")
        } }
        await a.value; await b.value
        #expect(log == ["a1", "a2", "b1", "b2"])
    }

    @Test func earlyReturnDoesNotBlockNext() async {
        let model = makeModel()
        var log: [String] = []
        let a = Task { @MainActor in await model.automate {
            log.append("a1")
            guard log.isEmpty else { return }
            log.append("a2")
        } }
        let b = Task { @MainActor in await model.automate { log.append("b") } }
        await a.value; await b.value
        #expect(log == ["a1", "b"])
    }
}
