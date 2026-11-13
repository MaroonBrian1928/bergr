import Foundation

/// A machine crossing a threshold the user should hear about.
enum HealthAlert: Equatable, Sendable {
    case lowDisk(freeBytes: Int64, freePercent: Double)
    case lowBattery(percent: Int)

    var title: String {
        switch self {
        case .lowDisk: "Disk almost full"
        case .lowBattery: "Battery low"
        }
    }

    var body: String {
        switch self {
        case .lowDisk(let bytes, let percent):
            String(format: "%.1f GB free (%.0f%%)", Double(bytes) / Double(MachineHealth.gib), percent)
        case .lowBattery(let percent):
            "\(percent)% and not charging"
        }
    }
}

/// Decides when a low-disk or low-battery alert is due: once per crossing. An alert re-arms only when
/// the value is back above the threshold plus a margin (or the battery is charging), so a reading
/// that hovers at the line doesn't alert again and again.
struct HealthAlertTracker {
    static let lowBattery = 15
    static let batteryRecovered = 20
    static let diskRecoveredBytes: Int64 = 6 * MachineHealth.gib
    static let diskRecoveredPercent = 6.0

    private var diskAlerted: Set<UUID> = []
    private var batteryAlerted: Set<UUID> = []

    mutating func observe(_ id: UUID, _ health: MachineHealth) -> [HealthAlert] {
        var alerts: [HealthAlert] = []
        if let disk = health.disk {
            if disk.isLow {
                if diskAlerted.insert(id).inserted {
                    alerts.append(.lowDisk(freeBytes: disk.freeBytes, freePercent: disk.freePercent))
                }
            } else if disk.freeBytes >= Self.diskRecoveredBytes, disk.freePercent >= Self.diskRecoveredPercent {
                diskAlerted.remove(id)
            }
        }
        if let percent = health.batteryPercent {
            let discharging = health.batteryDischarging == true
            if percent < Self.lowBattery, discharging {
                if batteryAlerted.insert(id).inserted { alerts.append(.lowBattery(percent: percent)) }
            } else if percent >= Self.batteryRecovered || health.batteryDischarging == false {
                batteryAlerted.remove(id)
            }
        }
        return alerts
    }
}

/// One row of the detail sheet's process list.
struct MachineProcess: Equatable, Identifiable, Sendable {
    let pid: Int
    let cpu: Double
    let memory: Double
    let name: String
    var id: Int { pid }
}

enum MachineProcessList {
    /// The top 5 by CPU (plus the header line `head -6` keeps). One `sh -c` line for both OS families.
    static let command = #"""
    sh -c 'case $(uname -s) in Darwin) ps -Ao pid,pcpu,pmem,comm -r;; *) ps -eo pid,pcpu,pmem,comm --sort=-pcpu;; esac | head -6'
    """#

    /// Reads `ps` output (macOS or Linux): a header, then "pid %cpu %mem command". Lines that don't
    /// parse are skipped; the command shows as its last path component.
    static func parse(_ output: String) -> [MachineProcess] {
        let rows: [MachineProcess] = output.split(whereSeparator: \.isNewline).compactMap { raw in
            let f = raw.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count == 4, let pid = Int(f[0]), let cpu = Double(f[1]), let mem = Double(f[2]) else { return nil }
            let command = f[3].trimmingCharacters(in: .whitespaces)
            let name = command.split(separator: "/").last.map(String.init) ?? command
            return MachineProcess(pid: pid, cpu: cpu, memory: mem, name: name)
        }
        return Array(rows.prefix(5))
    }
}
