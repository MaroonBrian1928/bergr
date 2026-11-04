#if DEBUG
import AVFoundation
import ReplayKit
import UIKit

/// Records the app's own screen into `Documents/<name>.mp4`, for videos made on a real device
/// (`just video-device`), over Wi-Fi as well as by cable. Started by the launch argument
/// `-hirte.record <name>`; stops and finishes the file when the app stops being active (home).
/// Debug builds only.
nonisolated final class ScreenRecording: @unchecked Sendable {
    @MainActor private static var current: ScreenRecording?

    @MainActor
    static func startIfRequested() {
        guard current == nil, let name = UserDefaults.standard.string(forKey: "hirte.record"), !name.isEmpty else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recording = ScreenRecording(url: documents.appendingPathComponent("\(name).mp4"))
        current = recording
        // ReplayKit fails to start (-5803) until the app is active, so wait a moment.
        Task { @MainActor in
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            recording.start(attempts: 5)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let task = UIApplication.shared.beginBackgroundTask()
                recording.stop { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
                current = nil
            }
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    private init(url: URL) {
        self.url = url
    }

    private func start(attempts: Int) {
        try? FileManager.default.removeItem(at: url)
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = false
        recorder.startCapture(handler: { [self] buffer, type, error in
            guard error == nil, type == .video else { return }
            append(buffer)
        }, completionHandler: { [self] error in
            guard let error else { return print("screen recording started") }
            print("screen recording did not start: \(error)")
            if attempts > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start(attempts: attempts - 1) }
            }
        })
    }

    private func append(_ buffer: CMSampleBuffer) {
        lock.withLock {
            if writer == nil {
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
                let size = CMVideoFormatDescriptionGetDimensions(format)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: size.width,
                    AVVideoHeightKey: size.height,
                ])
                input.expectsMediaDataInRealTime = true
                // Fragments: a file cut off by suspension still plays.
                writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                self.writer = writer
                self.input = input
            }
            if let input, input.isReadyForMoreMediaData {
                input.append(buffer)
            }
        }
    }

    /// Finishes the file first: once the app is suspended, ReplayKit may never call back.
    private func stop(then done: @escaping @Sendable () -> Void) {
        let (writer, input) = lock.withLock {
            defer { self.input = nil }
            return (self.writer, self.input)
        }
        RPScreenRecorder.shared().stopCapture { _ in }
        guard let writer, let input else { return done() }
        input.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}
#endif
