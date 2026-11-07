import Darwin
import Foundation

/// Converts Mach absolute time units (used for CPU times on Apple silicon) to nanoseconds.
public struct MachTimebase: Sendable, Equatable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = max(1, denom)
    }

    /// 1/1 on Intel, 125/3 on Apple silicon.
    public static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            return MachTimebase(numer: 1, denom: 1)
        }
        return MachTimebase(numer: info.numer, denom: info.denom)
    }()

    public func nanoseconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom)
    }
}

/// Cumulative CPU counters of one process at one moment.
public struct ProcessCPUSample: Sendable, Equatable {
    public let path: String
    /// When the process started, in Mach ticks. Tells a reused PID apart from the original process.
    public let startTime: UInt64
    /// User plus system time, in Mach ticks.
    public let cpuTicks: UInt64
    /// Energy used so far in nanojoules, if the system reports it.
    public let energy: UInt64?
    public let footprint: Int64

    public init(path: String, startTime: UInt64, cpuTicks: UInt64, energy: UInt64?, footprint: Int64) {
        self.path = path
        self.startTime = startTime
        self.cpuTicks = cpuTicks
        self.energy = energy
        self.footprint = footprint
    }
}

/// System-wide CPU ticks (all cores), as counted by the kernel scheduler. These are 32-bit and wrap.
public struct HostCPUTicks: Sendable, Equatable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Everything needed to compute CPU usage between two moments.
public struct CPUSnapshot: Sendable {
    /// Wall-clock time of the snapshot in nanoseconds since boot (same clock as process start times).
    public let uptime: UInt64
    public let processes: [pid_t: ProcessCPUSample]
    public let host: HostCPUTicks?

    public init(uptime: UInt64, processes: [pid_t: ProcessCPUSample], host: HostCPUTicks?) {
        self.uptime = uptime
        self.processes = processes
        self.host = host
    }
}

/// How busy the whole Mac is, as fractions of all cores combined.
public struct CPULoad: Sendable, Equatable {
    public let user: Double
    public let system: Double

    public init(user: Double, system: Double) {
        self.user = max(0, user)
        self.system = max(0, system)
    }

    public var total: Double { min(1, user + system) }
    public var idle: Double { max(0, 1 - total) }
}

/// How hot the Mac is running, from `ProcessInfo.thermalState`.
public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very Hot"
        }
    }

    public var explanation: String {
        switch self {
        case .nominal: "Your Mac is running cool. Nothing to do."
        case .fair: "Your Mac is a little warm. That's normal while it's working hard."
        case .serious: "Your Mac is hot and may slow itself down to cool off. Quitting busy apps will help."
        case .critical: "Your Mac is slowing down a lot to cool off. Quit busy apps and make sure its vents aren't blocked."
        }
    }
}

/// The processor's core layout.
public struct CPUInfo: Sendable, Equatable {
    public let coreCount: Int
    public let performanceCores: Int?
    public let efficiencyCores: Int?

    public init(coreCount: Int, performanceCores: Int?, efficiencyCores: Int?) {
        self.coreCount = coreCount
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
    }

    /// "10 cores (4 performance, 6 efficiency)" or "8 cores".
    public var summary: String {
        let cores = "\(coreCount) \(coreCount == 1 ? "core" : "cores")"
        if let performanceCores, let efficiencyCores, performanceCores > 0, efficiencyCores > 0 {
            return "\(cores) (\(performanceCores) performance, \(efficiencyCores) efficiency)"
        }
        return cores
    }
}

/// CPU use of one app (including its helper processes) or one standalone process, over one sampling interval.
public struct CPUProcessGroup: Identifiable, Sendable, Hashable {
    /// The app bundle path, or the executable path for standalone processes (same as `ProcessGroup.id`).
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let pids: [pid_t]
    /// Percent of one core; 100% means one core was fully busy, so busy apps can go above 100%.
    public let cpu: Double
    /// Average power in watts over the interval, if the system reports energy.
    public let power: Double?
    /// Physical footprint, like the Memory screen.
    public let memory: Int64

    public init(id: String, name: String, bundleURL: URL?, pids: [pid_t], cpu: Double, power: Double?, memory: Int64) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
        self.pids = pids
        self.cpu = cpu
        self.power = power
        self.memory = memory
    }

    public var processCount: Int { pids.count }

    /// The same processes as a memory `ProcessGroup`, so they can be quit with the same code.
    public var processGroup: ProcessGroup {
        ProcessGroup(id: id, name: name, bundleURL: bundleURL, pids: pids, memory: memory)
    }

    public var isSystem: Bool { processGroup.isSystem }
}

/// One measurement: overall load plus per-app usage, busiest first.
public struct CPUReport: Sendable {
    public let load: CPULoad?
    public let groups: [CPUProcessGroup]
    /// False when the system doesn't report per-process energy (e.g. some Intel Macs).
    public let hasEnergyData: Bool
    /// Seconds between the two snapshots.
    public let interval: Double

    public init(load: CPULoad?, groups: [CPUProcessGroup], hasEnergyData: Bool, interval: Double) {
        self.load = load
        self.groups = groups
        self.hasEnergyData = hasEnergyData
        self.interval = interval
    }
}

public enum CPUMonitor {
    // MARK: Sampling

    /// Takes two snapshots `interval` apart and compares them. Used by the CLI.
    public static func sample(interval: Duration = .milliseconds(1500)) async -> CPUReport {
        let first = snapshot()
        try? await Task.sleep(for: interval)
        let second = snapshot(reusing: first)
        return report(from: first, to: second)
    }

    /// Reads the cumulative counters of every readable process. Other users' (and root) processes are skipped.
    /// Passing the previous snapshot avoids looking up executable paths again for processes that are still running.
    public static func snapshot(reusing previous: CPUSnapshot? = nil) -> CPUSnapshot {
        var processes: [pid_t: ProcessCPUSample] = [:]
        for pid in MemoryMonitor.allPIDs() where pid > 0 {
            guard let usage = rusage(of: pid) else { continue }
            let path: String
            if let known = previous?.processes[pid], known.startTime == usage.startTime {
                path = known.path
            } else if let found = MemoryMonitor.executablePath(of: pid) {
                path = found
            } else {
                continue
            }
            processes[pid] = ProcessCPUSample(
                path: path, startTime: usage.startTime, cpuTicks: usage.cpuTicks, energy: usage.energy, footprint: usage.footprint
            )
        }
        return CPUSnapshot(uptime: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), processes: processes, host: hostTicks())
    }

    /// Compares two snapshots and groups processes by app, like the Memory screen.
    public static func report(from old: CPUSnapshot, to new: CPUSnapshot, timebase: MachTimebase = .current) -> CPUReport {
        let elapsed = new.uptime > old.uptime ? new.uptime - old.uptime : 0
        var groups: [String: (name: String, bundle: URL?, pids: [pid_t], ticks: UInt64, energy: UInt64, memory: Int64)] = [:]
        var hasEnergy = false

        for (pid, sample) in new.processes {
            if (sample.energy ?? 0) > 0 { hasEnergy = true }
            guard let baseline = baseline(for: pid, sample: sample, in: old, timebase: timebase) else { continue }
            let ticks = sample.cpuTicks >= baseline.cpuTicks ? sample.cpuTicks - baseline.cpuTicks : 0
            let newEnergy = sample.energy ?? 0
            let oldEnergy = baseline.energy ?? 0
            let energy = newEnergy >= oldEnergy ? newEnergy - oldEnergy : 0

            let (key, name, bundle) = MemoryMonitor.groupKey(forExecutable: sample.path)
            groups[key, default: (name, bundle, [], 0, 0, 0)].pids.append(pid)
            groups[key]?.ticks += ticks
            groups[key]?.energy += energy
            groups[key]?.memory += sample.footprint
        }

        let seconds = Double(elapsed) / 1_000_000_000
        let result = groups.map { key, value in
            CPUProcessGroup(
                id: key,
                name: value.name,
                bundleURL: value.bundle,
                pids: value.pids.sorted(),
                cpu: cpuPercent(ticks: value.ticks, overNanoseconds: elapsed, timebase: timebase),
                power: hasEnergy ? watts(nanojoules: value.energy, overNanoseconds: elapsed) : nil,
                memory: value.memory
            )
        }
        .sorted(by: busierFirst)

        let load: CPULoad? = if let before = old.host, let after = new.host { self.load(from: before, to: after) } else { nil }
        return CPUReport(load: load, groups: result, hasEnergyData: hasEnergy, interval: seconds)
    }

    /// The previous counters to subtract. Processes started during the interval count from zero;
    /// a PID that was reused by a different process is skipped because its earlier usage is unknown.
    static func baseline(for pid: pid_t, sample: ProcessCPUSample, in old: CPUSnapshot, timebase: MachTimebase) -> ProcessCPUSample? {
        if let previous = old.processes[pid], previous.startTime == sample.startTime {
            return previous
        }
        let started = timebase.nanoseconds(fromTicks: sample.startTime)
        guard started >= Double(old.uptime) else { return nil }
        return ProcessCPUSample(path: sample.path, startTime: sample.startTime, cpuTicks: 0, energy: 0, footprint: 0)
    }

    /// CPU time over wall time, where 100% is one fully busy core.
    static func cpuPercent(ticks: UInt64, overNanoseconds elapsed: UInt64, timebase: MachTimebase) -> Double {
        guard elapsed > 0 else { return 0 }
        return timebase.nanoseconds(fromTicks: ticks) / Double(elapsed) * 100
    }

    static func watts(nanojoules: UInt64, overNanoseconds elapsed: UInt64) -> Double {
        guard elapsed > 0 else { return 0 }
        // nJ / ns == J / s == W.
        return Double(nanojoules) / Double(elapsed)
    }

    static func busierFirst(_ lhs: CPUProcessGroup, _ rhs: CPUProcessGroup) -> Bool {
        if lhs.cpu != rhs.cpu { return lhs.cpu > rhs.cpu }
        if lhs.memory != rhs.memory { return lhs.memory > rhs.memory }
        return lhs.id < rhs.id
    }

    // MARK: Stable ordering

    /// Keeps the previous row order unless it's clearly wrong, so a live list doesn't reshuffle on every refresh.
    /// CPU use jumps around a lot, so only a clear difference (5 points and 1.5×) triggers a re-sort.
    public static func merge(_ fresh: [CPUProcessGroup], keepingOrderOf previous: [CPUProcessGroup]) -> [CPUProcessGroup] {
        guard !previous.isEmpty else { return fresh.sorted(by: busierFirst) }
        var byID: [String: CPUProcessGroup] = [:]
        for group in fresh { byID[group.id] = group }
        var merged = previous.compactMap { byID[$0.id] }
        let known = Set(merged.map(\.id))
        merged += fresh.filter { !known.contains($0.id) }.sorted(by: busierFirst)

        let outOfOrder = zip(merged, merged.dropFirst()).contains { above, below in
            below.cpu - above.cpu > 5 && below.cpu > above.cpu * 1.5
        }
        if outOfOrder { merged.sort(by: busierFirst) }
        return merged
    }

    // MARK: System-wide

    /// Share of all cores spent in user and system code between two readings. Nice time counts as user time.
    public static func load(from old: HostCPUTicks, to new: HostCPUTicks) -> CPULoad? {
        // Counters are 32-bit and wrap around, so subtract with wrapping.
        let user = Double(new.user &- old.user) + Double(new.nice &- old.nice)
        let system = Double(new.system &- old.system)
        let idle = Double(new.idle &- old.idle)
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPULoad(user: user / total, system: system / total)
    }

    static func hostTicks() -> HostCPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        // Order is CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        return HostCPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    public static func info() -> CPUInfo {
        CPUInfo(
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: sysctlInt("hw.perflevel0.logicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.logicalcpu")
        )
    }

    // MARK: Formatting

    /// "54%", "2.4%" or "0%": one decimal only where it matters.
    public static func formatPercent(_ value: Double) -> String {
        value >= 10 || value <= 0 ? "\(Int(max(0, value).rounded()))%" : String(format: "%.1f%%", value)
    }

    /// "1.2 W", "350 mW" or "0 W".
    public static func formatPower(_ watts: Double) -> String {
        if watts >= 1 { return String(format: "%.1f W", watts) }
        let milliwatts = Int((max(0, watts) * 1000).rounded())
        return milliwatts == 0 ? "0 W" : "\(milliwatts) mW"
    }

    public static var thermalLevel: ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }
    public static var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: Per-process counters

    private struct Usage {
        let startTime: UInt64
        let cpuTicks: UInt64
        let energy: UInt64?
        let footprint: Int64
    }

    /// `rusage_info_v6` adds `ri_energy_nj`. Older systems only know v4, whose layout is a prefix of v6.
    private static let supportsV6: Bool = {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0
    }()

    private static func rusage(of pid: pid_t) -> Usage? {
        var usage = rusage_info_v6()
        let flavor = supportsV6 ? RUSAGE_INFO_V6 : RUSAGE_INFO_V4
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, flavor, $0)
            }
        }
        guard result == 0 else { return nil }
        let energy: UInt64? = supportsV6
            ? (usage.ri_energy_nj > 0 ? usage.ri_energy_nj : nil)
            : (usage.ri_billed_energy > 0 ? usage.ri_billed_energy : nil)
        return Usage(
            startTime: usage.ri_proc_start_abstime,
            cpuTicks: usage.ri_user_time &+ usage.ri_system_time,
            energy: energy,
            footprint: Int64(clamping: usage.ri_phys_footprint)
        )
    }
}
