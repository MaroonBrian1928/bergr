import Foundation
import HerdrKit
import Observation
import UserNotifications
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What a machine's line looks like at one look.
enum MachineLine: Equatable {
    case connected(working: Bool)
    case disconnected
    /// Paused or stopped by the app (in the background, or removed): not a drop.
    case paused
}

/// The part of a machine's session the monitor needs. `HostSession` conforms; tests fake it.
@MainActor
protocol MachineHealthSource: AnyObject {
    var healthID: UUID { get }
    var healthName: String { get }
    var healthLine: MachineLine { get }
    /// Commands can run here: a real machine (not the demo), connected.
    var canRunHealthCommand: Bool { get }
    var isWindowsMachine: Bool { get }
    func runHealthCommand(_ command: String) async throws -> String
}

extension HostSession: MachineHealthSource {
    var healthID: UUID { host.id }

    var healthName: String { host.name.isEmpty ? host.target.host : host.name }

    var healthLine: MachineLine {
        guard intent == .running else { return .paused }
        guard state == .connected else { return .disconnected }
        return .connected(working: terminals.contains { $0.isLive && $0.agentState == .working })
    }

    var canRunHealthCommand: Bool { canRunCommands }

    var isWindowsMachine: Bool { isWindowsHost }

    func runHealthCommand(_ command: String) async throws -> String {
        try await commandOutput(command)
    }
}

/// Decides when a "went offline" alert is due: once per drop, and only for a drop that came while
/// the machine had working agents. A pause (the app in the background) and a machine that was never
/// up don't count.
struct OfflineTracker {
    private var workingBeforeDrop: [UUID: Bool] = [:]
    private var alerted: Set<UUID> = []

    /// True when this look is the first of a drop that should alert.
    mutating func observe(_ id: UUID, _ line: MachineLine) -> Bool {
        switch line {
        case .paused:
            return false
        case .connected(let working):
            alerted.remove(id)
            workingBeforeDrop[id] = working
            return false
        case .disconnected:
            guard workingBeforeDrop[id] == true, !alerted.contains(id) else { return false }
            alerted.insert(id)
            return true
        }
    }
}

/// Polls each connected machine's health at most once a minute, while the app is active (never in
/// the background), and alerts when a machine drops while it had working agents.
@MainActor
@Observable
final class MachineHealthMonitor {
    static let shared = MachineHealthMonitor()

    /// The least time between two polls of one machine.
    static let pollInterval: Duration = .seconds(60)
    /// How often the loop looks at the machines; polls still happen at most once a minute.
    static let tickInterval: Duration = .seconds(5)

    private(set) var health: [UUID: MachineHealth] = [:]

    @ObservationIgnored private var machines: [UUID: WeakMachine] = [:]
    @ObservationIgnored private var lastPoll: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var offline = OfflineTracker()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let isActive: @MainActor () -> Bool
    @ObservationIgnored private let notifyOffline: @MainActor (UUID, String) -> Void

    init(
        isActive: @escaping @MainActor () -> Bool = MachineHealthMonitor.appIsActive,
        notifyOffline: @escaping @MainActor (UUID, String) -> Void = MachineHealthMonitor.postOffline
    ) {
        self.isActive = isActive
        self.notifyOffline = notifyOffline
    }

    /// Follows a machine and starts the loop (once). Called from the machine's header.
    func track(_ machine: any MachineHealthSource) {
        register(machine)
        guard loop == nil else { return }
        loop = Task { [self] in
            while !Task.isCancelled {
                await tick(now: ContinuousClock.now)
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Follows a machine without starting the loop.
    func register(_ machine: any MachineHealthSource) {
        machines[machine.healthID] = WeakMachine(source: machine)
    }

    /// One pass: offline checks for every machine, then the polls that are due.
    func tick(now: ContinuousClock.Instant) async {
        machines = machines.filter { $0.value.source != nil }
        let active = isActive()
        var due: [any MachineHealthSource] = []
        for box in machines.values {
            guard let machine = box.source else { continue }
            let line = machine.healthLine
            if offline.observe(machine.healthID, line) {
                notifyOffline(machine.healthID, machine.healthName)
            }
            if case .disconnected = line { health[machine.healthID] = nil }
            guard case .connected = line, machine.canRunHealthCommand, active else { continue }
            if let last = lastPoll[machine.healthID], now - last < Self.pollInterval { continue }
            lastPoll[machine.healthID] = now
            due.append(machine)
        }
        let polls = due.map { machine in Task { await self.poll(machine) } }
        for poll in polls { await poll.value }
    }

    private func poll(_ machine: any MachineHealthSource) async {
        let windows = machine.isWindowsMachine
        guard let output = try? await machine.runHealthCommand(MachineHealthCommand.command(windows: windows)),
              let parsed = MachineHealthParser.parse(output, windows: windows) else { return }
        health[machine.healthID] = parsed
    }

    // MARK: Platform

    static func appIsActive() -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        NSApplication.shared.isActive
        #endif
    }

    /// The "<machine> went offline" local notification, under the Settings → Notifications switch.
    static func postOffline(_ id: UUID, name: String) {
        guard UserDefaults.standard.bool(forKey: Delivery.notificationsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) went offline"
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = id.uuidString
        let request = UNNotificationRequest(identifier: "offline|\(id.uuidString)|\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private struct WeakMachine {
    weak var source: (any MachineHealthSource)?
}
