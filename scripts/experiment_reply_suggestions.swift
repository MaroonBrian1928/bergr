// Local experiment: compare the old prompt with production context and instructions.
// From the repository root:
// swiftc -parse-as-library Shared/OnDeviceText.swift bergr/Intelligence/ReplySuggestions.swift \
//   scripts/experiment_reply_suggestions.swift -o /tmp/bergr-reply-experiment
// /tmp/bergr-reply-experiment
// Requires Apple Intelligence enabled on this Mac. No network model is used.
import Foundation
import FoundationModels
@main struct Check {
 static func main() async {
  print("availability: \(SystemLanguageModel.default.availability)")
  guard case .available = SystemLanguageModel.default.availability else { return }
  let cases = [
   ("Fix the login redirect loop. Please don't commit yet.", "Fixed the login redirect loop by preserving the callback URL. All 18 auth tests pass. I haven't committed."),
   ("Help me speed up slow startup.", "Startup spends 2.4 seconds reading the cache. I can defer cache loading until after the first frame, or add an index to speed up reads. Which approach would you prefer?"),
   ("Add CSV export for filtered results.", "Implemented CSV export, but the export test fails because dates are formatted in the local timezone rather than UTC. The UI changes compile.")
  ]
  let baseline = "You suggest what the user might reply to a coding agent's last message. Write up to three short replies, one per line, each at most six words, as the user would type them (for example \"Run the tests\"). No numbering, no quotes, no other text."
  for (i, pair) in cases.enumerated() {
   for variant in ["baseline", "context"] {
    let start = ContinuousClock.now
    do {
     let session = LanguageModelSession(instructions: variant == "baseline" ? baseline : ReplySuggestions.instructions)
     let prompt = variant == "baseline" ? "The agent's last message:\n\(pair.1)" : ReplySuggestions.prompt(text: pair.1, context: "User: " + pair.0)
     let reply = try await session.respond(to: prompt)
     let processed = FoundationModelsWriter.usable(reply.content, preserveLines: variant != "baseline") ?? ""
     print("usable suggestions: \(ReplySuggestions.parse(processed).count)")
     print("case \(i + 1) \(variant) [\(start.duration(to: .now))]:\n\(reply.content)\n---")
    } catch { print("error: \(error)") }
   }
  }
 }
}
