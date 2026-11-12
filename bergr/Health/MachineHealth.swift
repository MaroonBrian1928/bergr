import Foundation

/// One machine's health as the Agents list shows it. Every value is optional: what a machine
/// doesn't report (no battery, no load average on Windows) is left out, not shown as zero.
struct MachineHealth: Equatable, Sendable {
    struct Disk: Equatable, Sendable {
        let freeBytes: Int64
        let totalBytes: Int64

        var freePercent: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) * 100 : 0 }
        /// Under 5 GB or under 5% free: shown in orange.
        var isLow: Bool {
            freeBytes < MachineHealth.lowDiskBytes || freePercent < MachineHealth.lowDiskPercent
        }
    }

    /// One piece of the compact line ("load 1.2", "41 GB free"); `warning` shows it in orange.
    struct Part: Equatable, Sendable {
        let text: String
        let warning: Bool
    }

    /// 1-minute load average (Unix only).
    var load1: Double?
    /// Share of physical memory in use, 0...100.
    var memoryUsedPercent: Double?
    /// The home volume (`~`, or the drive of %USERPROFILE% on Windows).
    var disk: Disk?
    /// Battery charge, 0...100, on machines that have a battery.
    var batteryPercent: Int?

    static let gib: Int64 = 1 << 30
    static let lowDiskBytes: Int64 = 5 * gib
    static let lowDiskPercent = 5.0

    /// The parts of the compact line, in order: load, memory, disk, battery. Missing values are skipped.
    var parts: [Part] {
        var result: [Part] = []
        if let load1 {
            result.append(Part(text: "load " + String(format: "%.1f", load1), warning: false))
        }
        if let memoryUsedPercent {
            result.append(Part(text: "mem \(Int(memoryUsedPercent.rounded()))%", warning: false))
        }
        if let disk {
            let gb = Double(disk.freeBytes) / Double(Self.gib)
            let text = gb < 10 ? String(format: "%.1f GB free", gb) : "\(Int(gb)) GB free"
            result.append(Part(text: text, warning: disk.isLow))
        }
        if let batteryPercent {
            result.append(Part(text: "battery \(batteryPercent)%", warning: false))
        }
        return result
    }
}

/// The one command per OS family that reads a machine's health. Each prints `@section` marker
/// lines followed by that section's raw output, which `MachineHealthParser` reads.
enum MachineHealthCommand {
    /// macOS and Linux: one POSIX line that branches on `uname -s`, wrapped in `sh -c` so the
    /// remote login shell doesn't matter (the same approach as `NewSession.locateCommand`).
    static let posix = #"""
    sh -c 'echo @os; uname -s; case $(uname -s) in Darwin) echo @load; sysctl -n vm.loadavg; echo @mem; sysctl -n hw.memsize; vm_stat; echo @disk; df -Pk ~ | tail -n 1; echo @batt; pmset -g batt;; *) echo @load; cat /proc/loadavg; echo @mem; grep -e MemTotal -e MemAvailable /proc/meminfo; echo @disk; df -Pk ~ | tail -n 1; echo @batt; cat /sys/class/power_supply/*/capacity 2>/dev/null;; esac'
    """#

    /// Windows: one PowerShell script, sent with -EncodedCommand so cmd.exe and PowerShell both
    /// pass it through unchanged. Memory is in KB, disk in bytes.
    static let windowsScript = #"""
    Write-Output '@mem'
    $o = Get-CimInstance Win32_OperatingSystem
    Write-Output "$($o.TotalVisibleMemorySize) $($o.FreePhysicalMemory)"
    Write-Output '@disk'
    $q = Split-Path -Qualifier $env:USERPROFILE
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$q'"
    Write-Output "$($d.FreeSpace) $($d.Size)"
    Write-Output '@batt'
    Get-CimInstance Win32_Battery | ForEach-Object { Write-Output $_.EstimatedChargeRemaining }
    """#

    static var windows: String {
        let encoded = windowsScript.data(using: .utf16LittleEndian)?.base64EncodedString() ?? ""
        return "powershell -NoProfile -NonInteractive -EncodedCommand \(encoded)"
    }

    static func command(windows isWindows: Bool) -> String { isWindows ? windows : posix }
}

/// Reads a machine's command output into `MachineHealth`. Each OS has its own reader; a section
/// that is missing or doesn't parse is skipped, never shown as zero.
enum MachineHealthParser {
    /// `windows`: the machine is a Windows host (no `@os` section from the PowerShell script).
    /// Nil when the output can't be recognized at all.
    static func parse(_ output: String, windows: Bool) -> MachineHealth? {
        let sections = sections(output)
        if windows { return sections.isEmpty ? nil : windowsHealth(sections) }
        let os = sections["os"]?.first.map(trim)
        if os == "Darwin" { return darwinHealth(sections) }
        if os == "Linux" { return linuxHealth(sections) }
        return nil
    }

    /// Splits the output at `@name` marker lines. Lines before the first marker are dropped.
    static func sections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = trim(String(raw))
            if line.hasPrefix("@") {
                current = String(line.dropFirst())
                result[current!] = []
            } else if let current, !line.isEmpty {
                result[current, default: []].append(line)
            }
        }
        return result
    }

    // MARK: macOS
    //
    // @load: "{ 1.23 1.45 1.67 }"; @mem: hw.memsize in bytes, then vm_stat; @disk: df -Pk (KB);
    // @batt: pmset -g batt.

    static func darwinHealth(_ s: [String: [String]]) -> MachineHealth {
        let mem = s["mem"] ?? []
        var memoryUsed: Double?
        if let total = mem.lazy.compactMap({ Int64($0) }).first,
           let pageSize = mem.lazy.compactMap(pageSize).first,
           let free = vmPages(mem, "free"), let inactive = vmPages(mem, "inactive"),
           let speculative = vmPages(mem, "speculative") {
            let available = (free + inactive + speculative) * pageSize
            memoryUsed = memoryUsedPercent(total: Double(total), available: Double(available))
        }
        return MachineHealth(
            load1: load(s["load"]),
            memoryUsedPercent: memoryUsed,
            disk: diskFromKilobytes(s["disk"]),
            batteryPercent: battery(s["batt"]))
    }

    /// "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
    static func pageSize(_ line: String) -> Int64? {
        guard let range = line.range(of: #"page size of \d+"#, options: .regularExpression) else { return nil }
        return Int64(line[range].filter(\.isNumber))
    }

    /// "Pages free:    12345." → 12345 for name "free".
    static func vmPages(_ lines: [String], _ name: String) -> Int64? {
        guard let line = lines.first(where: { $0.hasPrefix("Pages \(name):") }),
              let last = line.split(separator: " ").last else { return nil }
        return Int64(last.filter(\.isNumber))
    }

    // MARK: Linux
    //
    // @load: /proc/loadavg; @mem: MemTotal and MemAvailable (kB); @disk: df -Pk (KB);
    // @batt: /sys/class/power_supply/*/capacity (absent on desktops).

    static func linuxHealth(_ s: [String: [String]]) -> MachineHealth {
        let mem = s["mem"] ?? []
        let total = kilobytes(mem, "MemTotal:"), available = kilobytes(mem, "MemAvailable:")
        var memoryUsed: Double?
        if let total, let available {
            memoryUsed = memoryUsedPercent(total: Double(total), available: Double(available))
        }
        return MachineHealth(
            load1: load(s["load"]),
            memoryUsedPercent: memoryUsed,
            disk: diskFromKilobytes(s["disk"]),
            batteryPercent: battery(s["batt"]))
    }

    /// "MemTotal:       16000 kB" → bytes.
    static func kilobytes(_ lines: [String], _ key: String) -> Int64? {
        guard let line = lines.first(where: { $0.hasPrefix(key) }) else { return nil }
        let fields = fields(line)
        guard fields.count >= 2, let value = Int64(fields[1]) else { return nil }
        return value * 1024
    }

    // MARK: Windows
    //
    // @mem: "<total KB> <free KB>"; @disk: "<free bytes> <size bytes>"; @batt: a percentage, if any.

    static func windowsHealth(_ s: [String: [String]]) -> MachineHealth {
        var memoryUsed: Double?
        if let line = s["mem"]?.first, let values = numbers(line), values.count >= 2 {
            memoryUsed = memoryUsedPercent(total: values[0], available: values[1])
        }
        var disk: MachineHealth.Disk?
        if let line = s["disk"]?.first, let values = numbers(line), values.count >= 2, values[1] > 0 {
            disk = MachineHealth.Disk(freeBytes: Int64(values[0]), totalBytes: Int64(values[1]))
        }
        return MachineHealth(load1: nil, memoryUsedPercent: memoryUsed, disk: disk, batteryPercent: battery(s["batt"]))
    }

    // MARK: Shared

    /// The first number of the 1-minute load: "{ 1.23 1.45 1.67 }" on macOS, "0.52 0.58 …" on Linux.
    static func load(_ lines: [String]?) -> Double? {
        lines?.lazy.flatMap { fields($0) }.compactMap { Double($0) }.first
    }

    /// `df -Pk` line: fields 1 (total) and 3 (available) in KB. Anything else is unknown.
    static func diskFromKilobytes(_ lines: [String]?) -> MachineHealth.Disk? {
        guard let line = lines?.first else { return nil }
        let f = fields(line)
        guard f.count >= 4, let total = Int64(f[1]), let available = Int64(f[3]), total > 0 else { return nil }
        return MachineHealth.Disk(freeBytes: available * 1024, totalBytes: total * 1024)
    }

    /// The first battery percentage: "87" (Linux, Windows) or "…87%; discharging" (pmset).
    static func battery(_ lines: [String]?) -> Int? {
        for line in lines ?? [] {
            if let range = line.range(of: #"\d{1,3}(?=%)"#, options: .regularExpression),
               let value = Int(line[range]) {
                return min(100, value)
            }
            if let value = Int(line), (0...100).contains(value) { return value }
        }
        return nil
    }

    static func memoryUsedPercent(total: Double, available: Double) -> Double? {
        guard total > 0 else { return nil }
        return min(100, max(0, (total - available) / total * 100))
    }

    private static func numbers(_ line: String) -> [Double]? {
        let values = fields(line).compactMap { Double($0) }
        return values.isEmpty ? nil : values
    }

    private static func fields(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func trim(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
