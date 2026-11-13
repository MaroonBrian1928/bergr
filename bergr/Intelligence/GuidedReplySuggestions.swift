import Foundation
import FoundationModels

/// A classification and an exact quote precede generation. These fields stay on device and
/// are discarded after validation; only the validated reply strings enter the UI cache.
@Generable
nonisolated enum ReplySuggestionStatus: String, Codable {
    case complete
    case question
    case unfinished
}
@Generable
nonisolated struct ReplySuggestionPlan: Codable {
    @Guide(description: "Briefly restate only the work the USER requested and their constraints. Do not add optional work proposed by the agent.")
    var requestedWork: String
    @Guide(description: "Classify the user's REQUEST, not optional extra work. COMPLETE if the agent fulfilled the request, including when it offers optional deployment the user did not ask for. QUESTION if it asks a required choice. UNFINISHED if requested work failed, is blocked, or is still pending. A build awaiting store processing is unfinished.")
    var status: ReplySuggestionStatus
    @Guide(description: "An exact quote from the latest agent reply proving there is a required question or unfinished requested work. Empty for COMPLETE. Do not quote offers for work the user did not request.")
    var evidence: String
    @Guide(description: "For QUESTION only: copy the actual offered alternatives verbatim from the agent reply, such as SQLite and Postgres. No advice or new options. Empty otherwise.", .maximumCount(2))
    var choices: [String]
    @Guide(description: "For UNFINISHED only: directly request completion of the unfinished USER-REQUESTED work, using the relevant action verb. Ask to fix a failure, finish an implementation, or perform the pending action, not merely check or review it. Only for an external job already running, ask to check its status. Ignore unrequested actions mentioned by the agent. No waiting, cancelling, extra testing or new features. At most ten words. Empty for COMPLETE and QUESTION.")
    var nextReply: String
}

/// Uses guided generation so completion, offered choices and pending actions cannot be
/// confused with arbitrary lines of prose. Unavailable models simply produce no chips.
nonisolated struct GuidedReplySuggestionsWriter: OnDeviceTextWriting {
    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                guard let response = try? await session.respond(
                    to: prompt, generating: ReplySuggestionPlan.self,
                    options: GenerationOptions(temperature: 0.2)),
                      !Task.isCancelled,
                      let data = try? JSONEncoder().encode(response.content) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return Task.isCancelled ? nil : first
        }
    }
}
