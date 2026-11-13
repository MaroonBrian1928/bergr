import AVFoundation
import Speech
import SwiftUI

/// How dictated text joins the draft. Pure, so it is testable.
enum DictationText {
    /// The draft with the latest recognition result: `base` is the draft as it was when dictation
    /// started (see `prepared`), `partial` everything recognised since. Each result replaces the last.
    static func merged(base: String, partial: String) -> String {
        let spoken = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return spoken.isEmpty ? base : base + spoken
    }

    /// `base` with a space before the dictation unless it is empty or already ends in whitespace.
    static func prepared(base: String) -> String {
        guard let last = base.last, !last.isWhitespace else { return base }
        return base + " "
    }
}

/// One dictation session: microphone to the Speech framework, partial results into the draft.
@Observable
@MainActor
final class Dictation {
    enum State: Equatable { case idle, listening, denied }

    private(set) var state: State = .idle
    /// Set when recognition can't start for a reason the user can fix or should know.
    private(set) var problem: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: .current)
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var base = ""
    @ObservationIgnored private var apply: ((String) -> Void)?

    /// False when this device can't recognise speech at all (the button is then hidden).
    var available: Bool { recognizer != nil }

    static let silenceTimeout: Duration = .seconds(2)

    func toggle(draft: String, set: @escaping (String) -> Void) {
        if state == .listening { stop(); return }
        Task { await start(draft: draft, set: set) }
    }

    private func start(draft: String, set: @escaping (String) -> Void) async {
        problem = nil
        guard let recognizer, recognizer.isAvailable else { problem = "Dictation isn't available right now."; return }
        guard await Self.authorized() else {
            state = .denied
            problem = "Allow the microphone and speech recognition to dictate."
            return
        }
        state = .listening
        base = DictationText.prepared(base: draft)
        apply = set
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.state == .listening else { return }
                    if let text {
                        self.apply?(DictationText.merged(base: self.base, partial: text))
                        self.armSilence()
                    }
                    if final || error != nil { self.stop() }
                }
            }
            armSilence()
        } catch {
            problem = "Couldn't start the microphone."
            stop()
        }
    }

    func stop() {
        silence?.cancel()
        silence = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        apply = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if state == .listening { state = .idle }
    }

    /// Stops ~2 s after the last result.
    private func armSilence() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

/// The composer's mic: tap to start dictating into the draft, tap again (or pause ~2 s) to stop.
struct DictationButton: View {
    @Binding var draft: String
    let palette: ChatPalette
    let enabled: Bool

    @State private var dictation = Dictation()
    @Environment(\.openURL) private var openURL

    var body: some View {
        if dictation.available {
            let listening = dictation.state == .listening
            HStack(spacing: 4) {
                Button {
                    dictation.toggle(draft: draft) { draft = $0 }
                } label: {
                    Image(systemName: listening ? "mic.fill" : "mic")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(listening ? palette.onAccent : palette.text)
                        .symbolEffect(.pulse, isActive: listening)
                        .frame(width: PlatformMetrics.sendButtonSize, height: PlatformMetrics.sendButtonSize)
                        .background(listening ? palette.accent : palette.bubble, in: Circle())
                        .frame(width: PlatformMetrics.controlHeight, height: PlatformMetrics.controlHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(listening ? "Stop dictation" : "Dictate")
                .accessibilityIdentifier("dictate-button")
                if let problem = dictation.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                    if dictation.state == .denied, let url = Self.settingsURL {
                        Button("Settings") { openURL(url) }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .onDisappear { dictation.stop() }
        }
    }

    private static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #endif
    }
}
