import Foundation
import Testing
@testable import bergr

/// Output as the commands print it on each OS (see `MachineHealthCommand`).
private let linuxOutput = """
@os
Linux
@load
0.52 0.58 0.59 1/345 6789
@mem
MemTotal:       16000000 kB
MemAvailable:    8000000 kB
@disk
/dev/sda1 500000000 400000000 100000000 80% /home/u
@batt
87
"""

private let macOutput = """
@os
Darwin
@load
{ 1.23 1.45 1.67 }
@mem
17179869184
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100000.
Pages active:                             500000.
Pages inactive:                            50000.
Pages speculative:                         10000.
Pages wired down:                         200000.
@disk
/dev/disk3s1s1 971350180 400000000 571350180 42% /System/Volumes/Data
@batt
Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234567)\t87%; discharging; 5:00 remaining present: true
"""

private let windowsOutput = """
@mem
16777216 8388608
@disk
42949672960 536870912000
@batt
76
"""

@MainActor
@Suite struct MachineHealthParserTests {
    @Test func linuxFixture() throws {
        let health = try #require(MachineHealthParser.parse(linuxOutput, windows: false))
        #expect(health.load1 == 0.52)
        #expect(health.memoryUsedPercent == 50)
        #expect(health.disk?.freeBytes == Int64(100_000_000) * 1024)
        #expect(health.disk?.totalBytes == Int64(500_000_000) * 1024)
        #expect(health.batteryPercent == 87)
        #expect(health.parts.map(\.text) == ["load 0.5", "mem 50%", "95 GB free", "battery 87%"])
    }

    @Test func macFixtureWithBattery() throws {
        let health = try #require(MachineHealthParser.parse(macOutput, windows: false))
        #expect(health.load1 == 1.23)
        // Free + inactive + speculative pages count as available: 160,000 × 16 KB of 16 GB.
        #expect(health.memoryUsedPercent.map { $0.rounded() } == 85)
        #expect(health.disk?.freeBytes == Int64(571_350_180) * 1024)
        #expect(health.batteryPercent == 87)
        #expect(health.parts.map(\.text).last == "battery 87%")
    }

    @Test func macDesktopHasNoBattery() throws {
        let output = macOutput.replacingOccurrences(
            of: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234567)\t87%; discharging; 5:00 remaining present: true",
            with: "Now drawing from 'AC Power'")
        let health = try #require(MachineHealthParser.parse(output, windows: false))
        #expect(health.batteryPercent == nil)
        #expect(health.load1 == 1.23)
    }

    @Test func linuxDesktopHasNoBatteryLine() throws {
        let output = linuxOutput.replacingOccurrences(of: "@batt\n87", with: "@batt")
        let health = try #require(MachineHealthParser.parse(output, windows: false))
        #expect(health.batteryPercent == nil)
        #expect(health.parts.map(\.text) == ["load 0.5", "mem 50%", "95 GB free"])
    }

    @Test func windowsFixture() throws {
        let health = try #require(MachineHealthParser.parse(windowsOutput, windows: true))
        #expect(health.load1 == nil)
        #expect(health.memoryUsedPercent == 50)
        #expect(health.disk?.freeBytes == 40 * MachineHealth.gib)
        #expect(health.disk?.totalBytes == 500 * MachineHealth.gib)
        #expect(health.batteryPercent == 76)
        #expect(health.parts.map(\.text) == ["mem 50%", "40 GB free", "battery 76%"])
    }

    @Test func windowsWithoutBattery() throws {
        let output = windowsOutput.replacingOccurrences(of: "@batt\n76", with: "@batt")
        let health = try #require(MachineHealthParser.parse(output, windows: true))
        #expect(health.batteryPercent == nil)
    }

    @Test func unknownOutputIsNil() {
        #expect(MachineHealthParser.parse("bash: uname: command not found", windows: false) == nil)
        #expect(MachineHealthParser.parse("", windows: true) == nil)
    }

    @Test func missingSectionsAreSkippedNotZero() throws {
        // A Linux box whose /proc/meminfo didn't answer: no memory figure, the rest still shows.
        let output = linuxOutput.replacingOccurrences(of: "MemTotal:       16000000 kB\nMemAvailable:    8000000 kB\n", with: "")
        let health = try #require(MachineHealthParser.parse(output, windows: false))
        #expect(health.memoryUsedPercent == nil)
        #expect(health.load1 == 0.52)
    }

    @Test func windowsCommandIsEncodedPowerShell() {
        #expect(MachineHealthCommand.windows.hasPrefix("powershell -NoProfile -NonInteractive -EncodedCommand "))
        #expect(MachineHealthCommand.command(windows: false) == MachineHealthCommand.posix)
    }

    @Test func sectionsSplitAtMarkers() {
        let sections = MachineHealthParser.sections(linuxOutput)
        #expect(sections["os"] == ["Linux"])
        #expect(sections["disk"]?.count == 1)
    }
}

@Suite struct MachineHealthThresholdTests {
    @Test func lowDiskUnderFiveGigabytes() {
        let disk = MachineHealth.Disk(freeBytes: 4 * MachineHealth.gib, totalBytes: 1000 * MachineHealth.gib)
        #expect(disk.isLow)
    }

    @Test func lowDiskUnderFivePercent() {
        // 6 GB free is above 5 GB, but 0.6% of a 1 TB disk.
        let disk = MachineHealth.Disk(freeBytes: 6 * MachineHealth.gib, totalBytes: 1000 * MachineHealth.gib)
        #expect(disk.isLow)
    }

    @Test func healthyDisk() {
        let disk = MachineHealth.Disk(freeBytes: 40 * MachineHealth.gib, totalBytes: 500 * MachineHealth.gib)
        #expect(!disk.isLow)
    }

    @Test func lowDiskIsOrangeInParts() {
        let health = MachineHealth(load1: nil, memoryUsedPercent: nil,
                                   disk: .init(freeBytes: 2 * MachineHealth.gib, totalBytes: 100 * MachineHealth.gib),
                                   batteryPercent: nil)
        #expect(health.parts == [.init(text: "2.0 GB free", warning: true)])
    }

    @Test func emptyHealthHasNoParts() {
        #expect(MachineHealth(load1: nil, memoryUsedPercent: nil, disk: nil, batteryPercent: nil).parts.isEmpty)
    }
}

@Suite struct OfflineTrackerTests {
    let id = UUID()

    @Test func dropWithWorkingAgentsAlertsOnce() {
        var tracker = OfflineTracker()
        let fired1 = tracker.observe(id, .connected(working: true))
        #expect(fired1 == false)
        let fired2 = tracker.observe(id, .disconnected)
        #expect(fired2)
        let fired3 = tracker.observe(id, .disconnected)
        #expect(fired3 == false)
        let fired4 = tracker.observe(id, .disconnected)
        #expect(fired4 == false)
    }

    @Test func reconnectRearmsForTheNextDrop() {
        var tracker = OfflineTracker()
        _ = tracker.observe(id, .connected(working: true))
        let fired5 = tracker.observe(id, .disconnected)
        #expect(fired5)
        let fired6 = tracker.observe(id, .connected(working: true))
        #expect(fired6 == false)
        let fired7 = tracker.observe(id, .disconnected)
        #expect(fired7)
    }

    @Test func dropWithoutWorkingAgentsIsSilent() {
        var tracker = OfflineTracker()
        _ = tracker.observe(id, .connected(working: false))
        let fired8 = tracker.observe(id, .disconnected)
        #expect(fired8 == false)
    }

    @Test func neverConnectedIsSilent() {
        var tracker = OfflineTracker()
        let fired9 = tracker.observe(id, .disconnected)
        #expect(fired9 == false)
    }

    @Test func pauseIsNotADrop() {
        var tracker = OfflineTracker()
        _ = tracker.observe(id, .connected(working: true))
        let fired10 = tracker.observe(id, .paused)
        #expect(fired10 == false)
        let fired11 = tracker.observe(id, .paused)
        #expect(fired11 == false)
    }

    @Test func machinesAreTrackedSeparately() {
        var tracker = OfflineTracker()
        let other = UUID()
        _ = tracker.observe(id, .connected(working: true))
        _ = tracker.observe(other, .connected(working: false))
        let fired12 = tracker.observe(other, .disconnected)
        #expect(fired12 == false)
        let fired13 = tracker.observe(id, .disconnected)
        #expect(fired13)
    }
}

@MainActor
final class FakeMachine: MachineHealthSource {
    let healthID = UUID()
    let healthName = "lab"
    var healthLine: MachineLine = .connected(working: false)
    var canRunHealthCommand = true
    var isWindowsMachine = false
    var output = linuxOutput
    private(set) var calls = 0

    func runHealthCommand(_ command: String) async throws -> String {
        calls += 1
        return output
    }
}

@MainActor
private final class Recorder {
    var alerts: [String] = []
}

@MainActor
private final class Flag {
    var active = true
}

@MainActor
@Suite struct MachineHealthMonitorTests {
    private func makeMonitor(flag: Flag? = nil, recorder: Recorder? = nil) -> MachineHealthMonitor {
        let flag = flag ?? Flag()
        let recorder = recorder ?? Recorder()
        return MachineHealthMonitor(isActive: { flag.active }, notifyOffline: { _, name in recorder.alerts.append(name) })
    }

    @Test func pollsAtMostOncePerMinute() async {
        let monitor = makeMonitor()
        let machine = FakeMachine()
        monitor.register(machine)
        let t0 = ContinuousClock.now
        await monitor.tick(now: t0)
        #expect(machine.calls == 1)
        #expect(monitor.health[machine.healthID]?.load1 == 0.52)
        await monitor.tick(now: t0.advanced(by: .seconds(30)))
        #expect(machine.calls == 1)
        await monitor.tick(now: t0.advanced(by: .seconds(60)))
        #expect(machine.calls == 2)
    }

    @Test func nothingPolledWhileInBackground() async {
        let flag = Flag()
        flag.active = false
        let monitor = makeMonitor(flag: flag)
        let machine = FakeMachine()
        monitor.register(machine)
        await monitor.tick(now: ContinuousClock.now)
        #expect(machine.calls == 0)
        #expect(monitor.health[machine.healthID] == nil)
    }

    @Test func pausedAndDisconnectedMachinesAreNotPolled() async {
        let monitor = makeMonitor()
        let machine = FakeMachine()
        monitor.register(machine)
        machine.healthLine = .paused
        await monitor.tick(now: ContinuousClock.now)
        machine.healthLine = .disconnected
        await monitor.tick(now: ContinuousClock.now)
        #expect(machine.calls == 0)
    }

    @Test func demoMachineIsNotPolled() async {
        let monitor = makeMonitor()
        let machine = FakeMachine()
        machine.canRunHealthCommand = false
        monitor.register(machine)
        await monitor.tick(now: ContinuousClock.now)
        #expect(machine.calls == 0)
    }

    @Test func healthClearsWhenMachineDrops() async {
        let monitor = makeMonitor()
        let machine = FakeMachine()
        monitor.register(machine)
        await monitor.tick(now: ContinuousClock.now)
        #expect(monitor.health[machine.healthID] != nil)
        machine.healthLine = .disconnected
        await monitor.tick(now: ContinuousClock.now)
        #expect(monitor.health[machine.healthID] == nil)
    }

    @Test func offlineAlertOncePerDrop() async {
        let recorder = Recorder()
        let monitor = makeMonitor(recorder: recorder)
        let machine = FakeMachine()
        monitor.register(machine)
        machine.healthLine = .connected(working: true)
        await monitor.tick(now: ContinuousClock.now)
        machine.healthLine = .disconnected
        await monitor.tick(now: ContinuousClock.now)
        await monitor.tick(now: ContinuousClock.now)
        #expect(recorder.alerts == ["lab"])
        machine.healthLine = .connected(working: true)
        await monitor.tick(now: ContinuousClock.now)
        machine.healthLine = .disconnected
        await monitor.tick(now: ContinuousClock.now)
        #expect(recorder.alerts == ["lab", "lab"])
    }

    @Test func noAlertWhenBackgroundPausedTheMachine() async {
        let recorder = Recorder()
        let monitor = makeMonitor(recorder: recorder)
        let machine = FakeMachine()
        monitor.register(machine)
        machine.healthLine = .connected(working: true)
        await monitor.tick(now: ContinuousClock.now)
        machine.healthLine = .paused
        await monitor.tick(now: ContinuousClock.now)
        #expect(recorder.alerts.isEmpty)
    }
}
