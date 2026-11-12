import Foundation
import os

/// Debug-only timings of a chat's first paint: from the feed starting to the conversation showing.
/// Lines go to the unified log and to `Documents/firstpaint.log` (pull it off a device with
/// `xcrun devicectl device copy from`).
@MainActor
final class FirstPaintTrace {
    private let start = ContinuousClock.now
    private var marked: Set<String> = []
    private let label: String
    private var bytes = 0
    private var events = 0
    private var parse: Duration = .zero

    init(label: String) { self.label = label }

    func count(bytes: Int, events: Int, parse: Duration) {
        self.bytes += bytes
        self.events += events
        self.parse += parse
    }

    /// Records `step` once per trace.
    func mark(_ step: String) {
        #if DEBUG
        guard marked.insert(step).inserted else { return }
        let ms = (ContinuousClock.now - start).components
        let elapsed = Double(ms.seconds) * 1000 + Double(ms.attoseconds) / 1e15
        let p = parse.components
        let parseMs = Double(p.seconds) * 1000 + Double(p.attoseconds) / 1e15
        let line = String(format: "%@ %@ %.0f ms (bytes %d, events %d, parse %.0f ms)",
                          label, step, elapsed, bytes, events, parseMs)
        Self.log.info("\(line, privacy: .public)")
        Self.append(line)
        #endif
    }

    private static let log = Logger(subsystem: "bergr", category: "firstpaint")

    private static func append(_ line: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("firstpaint.log")
        let stamp = ISO8601DateFormatter().string(from: .now)
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
