import Foundation
import Testing
@testable import bergr

private let gib = MachineHealth.gib

private func health(freeGB: Double = 200, totalGB: Double = 500, battery: Int? = nil, discharging: Bool? = nil) -> MachineHealth {
    MachineHealth(
        disk: .init(freeBytes: Int64(freeGB * Double(gib)), totalBytes: Int64(totalGB * Double(gib))),
        batteryPercent: battery, batteryDischarging: discharging)
}

@Suite struct HealthAlertTrackerTests {
    @Test func lowDiskAlertsOncePerCrossing() {
        var tracker = HealthAlertTracker()
        let id = UUID()
        #expect(tracker.observe(id, health()).isEmpty)
        #expect(tracker.observe(id, health(freeGB: 4)).count == 1)
        #expect(tracker.observe(id, health(freeGB: 3)).isEmpty)
    }

    @Test func diskRearmsOnlyPastTheMargin() {
        var tracker = HealthAlertTracker()
        let id = UUID()
        _ = tracker.observe(id, health(freeGB: 4))
        // 5.5 GB is above the threshold but inside the margin: still alerted.
        #expect(tracker.observe(id, health(freeGB: 5.5)).isEmpty)
        #expect(tracker.observe(id, health(freeGB: 4)).isEmpty)
        #expect(tracker.observe(id, health(freeGB: 100)).isEmpty)
        #expect(tracker.observe(id, health(freeGB: 4)).count == 1)
    }

    @Test func lowPercentAlertsEvenWithGigabytesFree() {
        var tracker = HealthAlertTracker()
        #expect(tracker.observe(UUID(), health(freeGB: 40, totalGB: 1000)).count == 1)
    }

    @Test func batteryNeedsDischarging() {
        var tracker = HealthAlertTracker()
        let id = UUID()
        #expect(tracker.observe(id, health(battery: 10, discharging: false)).isEmpty)
        #expect(tracker.observe(id, health(battery: 10, discharging: nil)).isEmpty)
        #expect(tracker.observe(id, health(battery: 14, discharging: true)) == [.lowBattery(percent: 14)])
        #expect(tracker.observe(id, health(battery: 12, discharging: true)).isEmpty)
    }

    @Test func batteryRearmsWhenChargingOrRecovered() {
        var tracker = HealthAlertTracker()
        let id = UUID()
        _ = tracker.observe(id, health(battery: 10, discharging: true))
        _ = tracker.observe(id, health(battery: 11, discharging: false))
        #expect(tracker.observe(id, health(battery: 9, discharging: true)).count == 1)
        _ = tracker.observe(id, health(battery: 40, discharging: true))
        #expect(tracker.observe(id, health(battery: 8, discharging: true)).count == 1)
    }

    @Test func machinesAreSeparate() {
        var tracker = HealthAlertTracker()
        #expect(tracker.observe(UUID(), health(freeGB: 1)).count == 1)
        #expect(tracker.observe(UUID(), health(freeGB: 1)).count == 1)
    }
}

@Suite struct MachineProcessListTests {
    @Test func macOutput() {
        let out = """
          PID  %CPU %MEM COMM
          312  45.2  1.3 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
           88   3.0  0.1 /usr/sbin/mDNSResponder
        """
        let rows = MachineProcessList.parse(out)
        #expect(rows.count == 2)
        #expect(rows[0] == MachineProcess(pid: 312, cpu: 45.2, memory: 1.3, name: "Google Chrome"))
        #expect(rows[1].name == "mDNSResponder")
    }

    @Test func linuxOutputAndLimit() {
        var lines = ["    PID %CPU %MEM COMMAND"]
        for i in 1...8 { lines.append("   \(i) \(10 - i).5  0.\(i) proc\(i)") }
        let rows = MachineProcessList.parse(lines.joined(separator: "\n"))
        #expect(rows.count == 5)
        #expect(rows.first == MachineProcess(pid: 1, cpu: 9.5, memory: 0.1, name: "proc1"))
    }

    @Test func garbageIsSkipped() {
        #expect(MachineProcessList.parse("ps: error\n\n").isEmpty)
    }
}

@MainActor
@Suite struct MachineHealthFailureTests {
    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func monitor(_ sent: @escaping @MainActor (HealthAlert) -> Void = { _ in }) -> MachineHealthMonitor {
        MachineHealthMonitor(isActive: { true }, notifyOffline: { _, _ in }, notifyHealth: { _, _, alert in sent(alert) })
    }

    @Test func failedPollIsRecordedAndClears() async {
        let monitor = monitor()
        let machine = FakeMachine()
        machine.error = Boom()
        monitor.register(machine)
        let t0 = ContinuousClock.now
        await monitor.tick(now: t0)
        #expect(monitor.health[machine.healthID] == nil)
        #expect(monitor.failure[machine.healthID] == "boom")
        machine.error = nil
        await monitor.tick(now: t0.advanced(by: .seconds(60)))
        #expect(monitor.failure[machine.healthID] == nil)
        #expect(monitor.health[machine.healthID] != nil)
    }

    @Test func unrecognizedOutputIsAFailure() async {
        let monitor = monitor()
        let machine = FakeMachine()
        machine.output = "nonsense"
        monitor.register(machine)
        await monitor.tick(now: ContinuousClock.now)
        #expect(monitor.failure[machine.healthID] != nil)
    }

    @Test func lowDiskFromPollNotifiesOnce() async {
        final class Box { var alerts: [HealthAlert] = [] }
        let box = Box()
        let monitor = monitor { box.alerts.append($0) }
        let machine = FakeMachine()
        machine.output = """
        @os
        Linux
        @disk
        /dev/sda1 500000000 499000000 1000000 99% /home/u
        """
        monitor.register(machine)
        let t0 = ContinuousClock.now
        await monitor.tick(now: t0)
        await monitor.tick(now: t0.advanced(by: .seconds(60)))
        #expect(box.alerts.count == 1)
    }
}

@Suite struct BatteryParsingTests {
    @Test func macDischarging() throws {
        let h = try #require(MachineHealthParser.parse("@os\nDarwin\n@batt\n -InternalBattery-0 (id=1)\t13%; discharging; 1:00 remaining\n", windows: false))
        #expect(h.batteryPercent == 13)
        #expect(h.batteryDischarging == true)
    }

    @Test func macCharging() throws {
        let h = try #require(MachineHealthParser.parse("@os\nDarwin\n@batt\n -InternalBattery-0 (id=1)\t13%; charging; 1:00 remaining\n", windows: false))
        #expect(h.batteryDischarging == false)
    }

    @Test func linuxStatusColumn() throws {
        let h = try #require(MachineHealthParser.parse("@os\nLinux\n@batt\n42 Discharging\n", windows: false))
        #expect(h.batteryPercent == 42)
        #expect(h.batteryDischarging == true)
    }
}
