import AVFoundation

/// "Read aloud" in the chat's message menu: speaks the whole message as plain words.
@MainActor
final class SpeechReader {
    static let shared = SpeechReader()
    private let synthesizer = AVSpeechSynthesizer()

    func toggle(_ markdown: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        let text = AgentVoice.plain(markdown)
        guard !text.isEmpty else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}
