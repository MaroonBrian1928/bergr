import Foundation

/// Speculative local echo for slow links: printable characters typed at a shell prompt are shown
/// right away (dimmed, underlined) until the real output confirms them or proves them wrong.
nonisolated struct EchoPredictor: Sendable {
    static let settingKey = "bergr.predictTyping"
    static let minLatency: Duration = .milliseconds(120)
    static let confirmWithin: Duration = .milliseconds(1500)

    struct Prediction: Equatable, Sendable {
        var row: Int
        var column: Int
        /// Drawn starting at (column, row).
        var text: String
    }

    private(set) var shown: Prediction?
    /// After an unconfirmed prediction, until Enter: a password prompt doesn't echo.
    private(set) var suspended = false
    /// When each character of `shown.text` was typed.
    private var typedAt: [ContinuousClock.Instant] = []

    init() {}

    mutating func typed(
        _ text: String, enabled: Bool, latency: Duration?, alternateScreen: Bool,
        cursor: (x: Int, y: Int)?, cols: Int, now: ContinuousClock.Instant
    ) {
        guard !text.isEmpty else { return }
        let printable = text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
        if !printable {
            clear()
            if text.contains("\r") { suspended = false }
            return
        }
        guard enabled, let latency, latency >= Self.minLatency, !alternateScreen, !suspended,
              let cursor
        else {
            clear()
            return
        }
        let count = text.count
        if var current = shown {
            guard current.column + current.text.count + count <= cols else {
                clear()
                return
            }
            current.text += text
            shown = current
            typedAt += Array(repeating: now, count: count)
        } else {
            guard cursor.x >= 0, cursor.y >= 0, cursor.x + count <= cols else { return }
            shown = Prediction(row: cursor.y, column: cursor.x, text: text)
            typedAt = Array(repeating: now, count: count)
        }
    }

    mutating func frameChanged(
        lines: [String], cursor: (x: Int, y: Int)?, alternateScreen: Bool, now: ContinuousClock.Instant
    ) {
        guard let current = shown else { return }
        guard !alternateScreen, lines.indices.contains(current.row), cursor == nil || cursor!.y == current.row else {
            clear()
            return
        }
        let line = Array(lines[current.row])
        let predicted = Array(current.text)
        func actual(_ i: Int) -> Character {
            let cell = current.column + i
            return line.indices.contains(cell) ? line[cell] : " "
        }
        var matches = [Bool](repeating: false, count: predicted.count)
        for i in predicted.indices where predicted[i] != " " {
            let cell = actual(i)
            if cell == predicted[i] {
                matches[i] = true
            } else if cell != " " {
                clear()
                return
            }
        }
        // A space matches a blank cell only once the cursor passed it or a later character appeared.
        for i in predicted.indices where predicted[i] == " " && actual(i) == " " {
            let passed = cursor.map { $0.x > current.column + i } ?? false
            matches[i] = passed || matches[(i + 1)...].contains(true)
        }
        var confirmed = 0
        while confirmed < matches.count, matches[confirmed] { confirmed += 1 }
        if confirmed > 0 {
            if confirmed == predicted.count {
                clear()
            } else {
                shown = Prediction(row: current.row, column: current.column + confirmed, text: String(predicted[confirmed...]))
                typedAt.removeFirst(min(confirmed, typedAt.count))
            }
        }
        tick(now: now)
    }

    mutating func tick(now: ContinuousClock.Instant) {
        guard shown != nil, let oldest = typedAt.first else { return }
        if now - oldest >= Self.confirmWithin {
            clear()
            suspended = true
        }
    }

    mutating func reset() {
        clear()
        suspended = false
    }

    private mutating func clear() {
        shown = nil
        typedAt = []
    }
}
