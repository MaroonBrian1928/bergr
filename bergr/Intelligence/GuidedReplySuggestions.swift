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
    @Guide(description: "A quote from the latest agent reply showing the required question or unfinished requested work, copied as closely as possible. Empty for COMPLETE. Do not quote offers for work the user did not request.")
    var evidence: String
    @Guide(description: "For QUESTION only: copy the actual offered alternatives verbatim from the agent reply, such as SQLite and Postgres. No advice or new options. Empty otherwise.", .maximumCount(2))
    var choices: [String]
    @Guide(description: "For COMPLETE: one short, natural next step the user would likely send, such as checking or running the result or asking what changed. For UNFINISHED: directly request completion of the unfinished USER-REQUESTED work (fix the failure, finish it, or perform the pending action); for an external job already running, ask to check its status. Never commit, push, deploy, install, cancel or delete unless the user asked. At most ten words. Empty for QUESTION.")
    var nextReply: String
}

/// Uses guided generation so completion, offered choices and pending actions cannot be
/// confused with arbitrary lines of prose. Unavailable models simply produce no chips.
nonisolated struct GuidedReplySuggestionsWriter: OnDeviceTextWriting {
    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return await OnDeviceText.race(timeout: timeout) {
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(
                to: prompt, generating: ReplySuggestionPlan.self,
                options: GenerationOptions(temperature: 0.2)),
                  !Task.isCancelled,
                  let data = try? JSONEncoder().encode(response.content) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
