#if DEBUG
import AppKit
import os

/// Profiling the chat (debug builds, `-bergr.demo YES -bergr.stress <turns>`): the main thread's
/// processor time per pass of its run loop (not wall time, which a busy machine stretches), printed
/// every few seconds with the live updates sent meanwhile, and with `-bergr.stressScroll YES`
/// scroll-wheel events sent to the chat as a hand on a trackpad would.
@MainActor
enum MacStress {
    private static var busy: [Double] = []
    private static var woke: Double = 0
    private static var wheels = 0

    /// The main thread's processor time so far, in milliseconds.
    private static func cpu() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1e6
    }
    private static let log = OSSignposter(subsystem: "bergr.stress", category: .pointsOfInterest)

    static func start() {
        guard UserDefaults.standard.integer(forKey: "bergr.stress") > 0 else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            MainActor.assumeIsolated {
                let now = cpu()
                if activity == .afterWaiting {
                    woke = now
                } else if woke > 0 {
                    busy.append(now - woke)
                    woke = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "bergr.stressWarmup").clamped(4)))
            busy = []
            ChatFeed.stressEvents = 0
            if UserDefaults.standard.bool(forKey: "bergr.stressScroll") { Task { await scroll() } }
            if let path = UserDefaults.standard.string(forKey: "bergr.stressShot") { shoot(to: path) }
            if UserDefaults.standard.bool(forKey: "bergr.stressCheck") { Task { await check() } }
            while true {
                try? await Task.sleep(for: .seconds(5))
                report()
            }
        }
    }

    /// `-bergr.stressShot <file>`: the main window's views drawn into a PNG, for comparing the
    /// chat's look between builds (materials and the sidebar don't come out; the chat does).
    private static func shoot(to path: String) {
        guard let window = NSApp.windows.filter({ $0.isVisible }).max(by: { $0.frame.width < $1.frame.width }),
              let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("[stress] window saved to \(path)")
        fflush(stdout)
    }

    private static func report() {
        let sorted = busy.sorted()
        busy = []
        guard !sorted.isEmpty else { return }
        func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let total = sorted.reduce(0, +)
        let events = ChatFeed.stressEvents + wheels
        let line = String(format: "[stress] cpu %.0f ms updates %d wheels %d ms/event %.2f passes %d p50 %.2f p90 %.2f p99 %.2f max %.1f over8 %d over16 %d over33 %d",
                          total, ChatFeed.stressEvents, wheels, total / Double(max(events, 1)),
                          sorted.count, at(0.5), at(0.9), at(0.99), sorted.last!,
                          sorted.count { $0 > 8.3 }, sorted.count { $0 > 16.7 }, sorted.count { $0 > 33.3 })
        ChatFeed.stressEvents = 0
        wheels = 0
        print(line)
        fflush(stdout)
    }

    private static weak var cachedScrollView: NSScrollView?

    /// The chat's scroll view (its table's, see `ChatTable`), found once and kept while it is
    /// in a window: walking the window's views on every event was part of what this measured.
    private static func chatScrollView() -> NSScrollView? {
        if let view = cachedScrollView, view.window != nil { return view }
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? ChatTableScrollView { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        cachedScrollView = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
        return cachedScrollView
    }

    /// `-bergr.stressCheck YES`: the table's behaviour, step by step, printed as `[check]` lines:
    /// opening at the bottom, scrolling up (stops following), loading earlier messages (the row
    /// on top stays put), resizing the window (remeasured, still in place), and jumping back.
    private static func check() async {
        guard let view = chatScrollView() as? ChatTableScrollView, let table = view.table, let window = view.window else {
            print("[check] no chat table"); fflush(stdout); return
        }
        func state(_ label: String) { print("[check] \(label): \(table.debugState)"); fflush(stdout) }
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        state("opened")
        for _ in 0..<40 {
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0) {
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                if let wheel = NSEvent(cgEvent: e) { view.scrollWheel(with: wheel) }
            }
            await pause(0.016)
        }
        await pause(0.5)
        state("scrolled up")
        table.debugScroll(to: -view.contentInsets.top)
        await pause(0.5)
        state("at the top")
        table.debugClick(row: 0)
        await pause(1)
        state("earlier loaded")
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width - 300, height: frame.height), display: true)
        await pause(1)
        state("narrower")
        window.setFrame(frame, display: true)
        await pause(1)
        state("restored")
        table.scrollToBottom(animated: true)
        await pause(0.12)
        state("jumping")
        await pause(1)
        state("jumped")
        await pause(3)
        state("followed")
    }

    /// Up through the conversation and back down, over and over, 60 events a second.
    private static func scroll() async {
        var step = 0
        while true {
            try? await Task.sleep(for: .milliseconds(16))
            guard let view = chatScrollView() else { continue }
            // 150 events up, 150 down, a rest of 60.
            let phase = step % 360
            step += 1
            guard phase < 300 else { continue }
            let delta: Int32 = phase < 150 ? 30 : -30
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            guard let wheel = NSEvent(cgEvent: event) else { continue }
            let state = log.beginInterval("scroll")
            view.scrollWheel(with: wheel)
            wheels += 1
            log.endInterval("scroll", state)
        }
    }
}

private extension Double {
    func clamped(_ fallback: Double) -> Double { self > 0 ? self : fallback }
}
#endif
