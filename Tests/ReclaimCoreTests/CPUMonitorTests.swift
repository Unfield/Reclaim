import Foundation
import Testing
@testable import ReclaimCore

@Suite struct CPUMonitorTests {
    /// Apple silicon's timebase: one tick is 125/3 ≈ 41.67 ns.
    let appleSilicon = MachTimebase(numer: 125, denom: 3)

    private func sample(_ path: String, start: UInt64 = 0, ticks: UInt64, energy: UInt64? = nil, footprint: Int64 = 1_000) -> ProcessCPUSample {
        ProcessCPUSample(path: path, startTime: start, cpuTicks: ticks, energy: energy, footprint: footprint)
    }

    @Test func convertsMachTicksToNanoseconds() {
        #expect(appleSilicon.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
        #expect(MachTimebase(numer: 1, denom: 1).nanoseconds(fromTicks: 5) == 5)
        // A zero denominator would divide by zero; it's clamped instead.
        #expect(MachTimebase(numer: 1, denom: 0).nanoseconds(fromTicks: 7) == 7)
        #expect(MachTimebase.current.nanoseconds(fromTicks: 0) == 0)
    }

    @Test func cpuPercentUsesTheTimebase() {
        // 12M ticks = 0.5 s of CPU over 1 s of wall time = half a core.
        #expect(CPUMonitor.cpuPercent(ticks: 12_000_000, overNanoseconds: 1_000_000_000, timebase: appleSilicon) == 50)
        // Two full cores over 2 s.
        #expect(CPUMonitor.cpuPercent(ticks: 96_000_000, overNanoseconds: 2_000_000_000, timebase: appleSilicon) == 200)
        // On Intel ticks are nanoseconds.
        #expect(CPUMonitor.cpuPercent(ticks: 250_000_000, overNanoseconds: 1_000_000_000, timebase: MachTimebase(numer: 1, denom: 1)) == 25)
        #expect(CPUMonitor.cpuPercent(ticks: 100, overNanoseconds: 0, timebase: appleSilicon) == 0)
    }

    @Test func convertsEnergyToWatts() {
        // 3 J over 1.5 s.
        #expect(CPUMonitor.watts(nanojoules: 3_000_000_000, overNanoseconds: 1_500_000_000) == 2)
        #expect(CPUMonitor.watts(nanojoules: 5, overNanoseconds: 0) == 0)
    }

    @Test func groupsHelpersAndComputesUsage() throws {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let renderer = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let node = "/opt/homebrew/bin/node"

        let old = CPUSnapshot(uptime: 10_000_000_000, processes: [
            100: sample(chrome, ticks: 1_000, energy: 1_000),
            101: sample(renderer, ticks: 5_000, energy: 2_000),
            200: sample(node, ticks: 0, energy: 10),
        ], host: nil)
        let new = CPUSnapshot(uptime: 12_000_000_000, processes: [
            100: sample(chrome, ticks: 1_000 + 24_000_000, energy: 1_000 + 1_000_000_000),  // 1 s CPU, 1 J
            101: sample(renderer, ticks: 5_000 + 24_000_000, energy: 2_000 + 1_000_000_000), // 1 s CPU, 1 J
            200: sample(node, ticks: 12_000_000, energy: 10),                                 // 0.5 s CPU
        ], host: nil)

        let report = CPUMonitor.report(from: old, to: new, timebase: appleSilicon)
        #expect(report.interval == 2)
        #expect(report.hasEnergyData)
        #expect(report.groups.map(\.name) == ["Google Chrome", "node"])

        let browser = try #require(report.groups.first)
        #expect(browser.id == "/Applications/Google Chrome.app")
        #expect(browser.pids == [100, 101])
        #expect(browser.processCount == 2)
        #expect(abs(browser.cpu - 100) < 0.0001) // 2 s of CPU over 2 s = one full core
        #expect(abs((browser.power ?? 0) - 1) < 0.0001) // 2 J over 2 s
        #expect(browser.memory == 2_000)
        #expect(browser.processGroup.id == browser.id)
        #expect(browser.processGroup.pids == browser.pids)

        let tool = try #require(report.groups.last)
        #expect(abs(tool.cpu - 25) < 0.0001)
        #expect(tool.power == 0)
        #expect(tool.bundleURL == nil)
    }

    @Test func handlesNewAndReusedProcesses() {
        let old = CPUSnapshot(uptime: 10_000_000_000, processes: [
            300: sample("/usr/bin/old", start: 1, ticks: 1_000_000_000),
        ], host: nil)
        // 11 s after boot in ticks: started during the interval, so all of its CPU time counts.
        let startedDuring = UInt64(11_000_000_000 * 3 / 125)
        let new = CPUSnapshot(uptime: 12_000_000_000, processes: [
            // Same PID, different start time: reused by another process; earlier usage unknown, so skipped.
            300: sample("/usr/bin/reused", start: 2, ticks: 2_000_000_000),
            301: sample("/usr/bin/fresh", start: startedDuring, ticks: 24_000_000),
            // Started before the first snapshot but wasn't readable then: skipped rather than over-counted.
            302: sample("/usr/bin/unknown", start: 1, ticks: 24_000_000),
        ], host: nil)

        let report = CPUMonitor.report(from: old, to: new, timebase: appleSilicon)
        #expect(report.groups.map(\.name) == ["fresh"])
        #expect(abs((report.groups.first?.cpu ?? 0) - 50) < 0.0001)
        #expect(!report.hasEnergyData)
        #expect(report.groups.first?.power == nil)
    }

    @Test func counterGoingBackwardsCountsAsZero() {
        let old = CPUSnapshot(uptime: 0, processes: [1: sample("/bin/x", ticks: 500)], host: nil)
        let new = CPUSnapshot(uptime: 1_000_000_000, processes: [1: sample("/bin/x", ticks: 100)], host: nil)
        #expect(CPUMonitor.report(from: old, to: new, timebase: appleSilicon).groups.first?.cpu == 0)
    }

    @Test func overallLoadFromHostTicks() throws {
        let old = HostCPUTicks(user: 1_000, system: 500, idle: 10_000, nice: 0)
        let new = HostCPUTicks(user: 1_250, system: 600, idle: 10_600, nice: 50)
        let load = try #require(CPUMonitor.load(from: old, to: new))
        #expect(abs(load.user - 0.3) < 0.0001) // (250 + 50 nice) / 1000
        #expect(abs(load.system - 0.1) < 0.0001)
        #expect(abs(load.total - 0.4) < 0.0001)
        #expect(abs(load.idle - 0.6) < 0.0001)
        #expect(CPUMonitor.load(from: old, to: old) == nil)
    }

    @Test func hostTicksWrapAround() throws {
        let old = HostCPUTicks(user: UInt32.max - 49, system: 0, idle: UInt32.max - 49, nice: 0)
        let new = HostCPUTicks(user: 50, system: 0, idle: 50, nice: 0)
        let load = try #require(CPUMonitor.load(from: old, to: new))
        #expect(abs(load.user - 0.5) < 0.0001)
    }

    @Test func stableOrderOnlyReshufflesForClearChanges() {
        func group(_ id: String, _ cpu: Double) -> CPUProcessGroup {
            CPUProcessGroup(id: id, name: id, bundleURL: nil, pids: [1], cpu: cpu, power: nil, memory: 0)
        }
        let previous = [group("a", 40), group("b", 20), group("c", 1)]

        // Small swings keep the order.
        let noisy = CPUMonitor.merge([group("c", 3), group("b", 22), group("a", 18)], keepingOrderOf: previous)
        #expect(noisy.map(\.id) == ["a", "b", "c"])
        #expect(noisy.first?.cpu == 18)

        // New groups go to the end, gone ones disappear.
        let changed = CPUMonitor.merge([group("b", 20), group("a", 30), group("d", 2)], keepingOrderOf: previous)
        #expect(changed.map(\.id) == ["a", "b", "d"])

        // A clear jump re-sorts everything.
        let jump = CPUMonitor.merge([group("a", 10), group("b", 15), group("c", 90)], keepingOrderOf: previous)
        #expect(jump.map(\.id) == ["c", "b", "a"])

        // First refresh: busiest first.
        #expect(CPUMonitor.merge([group("x", 1), group("y", 5)], keepingOrderOf: []).map(\.id) == ["y", "x"])
    }

    @Test func describesCoresAndThermalState() {
        #expect(CPUInfo(coreCount: 10, performanceCores: 4, efficiencyCores: 6).summary == "10 cores (4 performance, 6 efficiency)")
        #expect(CPUInfo(coreCount: 8, performanceCores: nil, efficiencyCores: nil).summary == "8 cores")
        #expect(CPUInfo(coreCount: 8, performanceCores: 8, efficiencyCores: 0).summary == "8 cores")
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.nominal).label == "Normal")
        #expect(ThermalLevel.allCases.allSatisfy { !$0.explanation.isEmpty })
        #expect(ThermalLevel.fair < .critical)
    }

    @Test func formatsPercentAndPower() {
        #expect(CPUMonitor.formatPercent(0) == "0%")
        #expect(CPUMonitor.formatPercent(2.44) == "2.4%")
        #expect(CPUMonitor.formatPercent(54.4) == "54%")
        #expect(CPUMonitor.formatPercent(312.6) == "313%")
        #expect(CPUMonitor.formatPower(0) == "0 W")
        #expect(CPUMonitor.formatPower(0.0004) == "0 W")
        #expect(CPUMonitor.formatPower(0.35) == "350 mW")
        #expect(CPUMonitor.formatPower(4.42) == "4.4 W")
    }

    @Test func liveSampleFindsOwnProcess() async {
        let info = CPUMonitor.info()
        #expect(info.coreCount == ProcessInfo.processInfo.activeProcessorCount)

        let report = await CPUMonitor.sample(interval: .milliseconds(300))
        #expect(report.interval > 0.2)
        #expect(report.groups.contains { $0.pids.contains(getpid()) })
        #expect(report.groups.allSatisfy { $0.cpu >= 0 })
        if let load = report.load {
            #expect((0...1).contains(load.total))
        }
        #expect(zip(report.groups, report.groups.dropFirst()).allSatisfy { $0.cpu >= $1.cpu })
    }
}
