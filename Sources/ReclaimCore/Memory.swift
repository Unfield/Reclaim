import Darwin
import Foundation

/// How hard macOS is working to find memory. This, not "free RAM", is what tells you whether a Mac needs more memory.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal
    case warning
    case critical

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Elevated")
        case .critical: String(localized: "Critical")
        }
    }

    public var explanation: String {
        switch self {
        case .normal: String(localized: "Your Mac has plenty of memory available. Nothing to do.")
        case .warning: String(localized: "macOS is compressing memory to make room. Quitting apps you aren't using will help.")
        case .critical: String(localized: "Your Mac is short on memory and may feel slow. Quit memory-heavy apps you don't need.")
        }
    }
}

/// System-wide memory usage, using the same definitions as Activity Monitor.
public struct MemoryStats: Sendable, Equatable {
    public let total: Int64
    /// Memory used by apps (anonymous memory, excluding purgeable).
    public let appMemory: Int64
    /// Memory the system can't compress or page out.
    public let wired: Int64
    /// Memory squeezed by the compressor.
    public let compressed: Int64
    /// File caches macOS can drop instantly when apps need the space.
    public let cachedFiles: Int64
    public let swapUsed: Int64
    public let swapTotal: Int64
    public let pressure: MemoryPressure

    public init(
        total: Int64, appMemory: Int64, wired: Int64, compressed: Int64, cachedFiles: Int64,
        swapUsed: Int64, swapTotal: Int64, pressure: MemoryPressure
    ) {
        self.total = total
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    /// "Memory Used" in Activity Monitor.
    public var used: Int64 { appMemory + wired + compressed }
    public var free: Int64 { max(0, total - used - cachedFiles) }
    /// Memory apps could get right now without swapping: free plus droppable caches.
    public var available: Int64 { max(0, total - used) }
    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

/// Memory used by one app (including its helper processes) or one standalone process.
public struct ProcessGroup: Identifiable, Sendable, Hashable {
    /// The app bundle path, or the executable path for standalone processes.
    public let id: String
    public let name: String
    /// The `.app` bundle, if the processes belong to one.
    public let bundleURL: URL?
    public let pids: [pid_t]
    /// Physical footprint, the "Memory" column in Activity Monitor.
    public let memory: Int64

    public var processCount: Int { pids.count }

    /// macOS components are never offered for termination.
    public var isSystem: Bool {
        let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/", "/Library/Developer/CommandLineTools/"]
        return systemPrefixes.contains { id.hasPrefix($0) }
    }
}

public enum MemoryMonitor {
    // MARK: System stats

    public static func stats() -> MemoryStats? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Int64(pageSize)
        let anonymous = Int64(info.internal_page_count)
        let purgeable = Int64(info.purgeable_count)
        let external = Int64(info.external_page_count)
        let swap = swapUsage()

        return MemoryStats(
            total: Int64(ProcessInfo.processInfo.physicalMemory),
            appMemory: max(0, anonymous - purgeable) * page,
            wired: Int64(info.wire_count) * page,
            compressed: Int64(info.compressor_page_count) * page,
            cachedFiles: (external + purgeable) * page,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: pressure()
        )
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return pressureLevel(fromKernelValue: level)
    }

    /// The kernel reports 1 (normal), 2 (warning) or 4 (critical).
    static func pressureLevel(fromKernelValue value: Int32) -> MemoryPressure {
        switch value {
        case 4...: .critical
        case 2...3: .warning
        default: .normal
        }
    }

    static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    // MARK: Processes

    /// Your processes grouped by app, heaviest first. Other users' (and root) processes aren't readable and are skipped.
    public static func processGroups() -> [ProcessGroup] {
        var groups: [String: (name: String, bundle: URL?, pids: [pid_t], memory: Int64)] = [:]

        for pid in allPIDs() where pid > 0 {
            guard let footprint = footprint(of: pid), footprint > 0, let path = executablePath(of: pid) else { continue }
            let (key, name, bundle) = groupKey(forExecutable: path)
            groups[key, default: (name, bundle, [], 0)].pids.append(pid)
            groups[key]?.memory += footprint
        }

        return groups
            .map { ProcessGroup(id: $0.key, name: $0.value.name, bundleURL: $0.value.bundle, pids: $0.value.pids, memory: $0.value.memory) }
            .sorted { $0.memory > $1.memory }
    }

    /// Helpers live inside their app's bundle (e.g. `Google Chrome.app/Contents/Frameworks/…/Helper.app`),
    /// so the outermost `.app` in the path identifies the app.
    static func groupKey(forExecutable path: String) -> (key: String, name: String, bundle: URL?) {
        if let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            let name = (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
            return (bundlePath, name, URL(filePath: bundlePath, directoryHint: .isDirectory))
        }
        return (path, (path as NSString).lastPathComponent, nil)
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return Array(pids.prefix(Int(max(0, count))))
    }

    static func footprint(of pid: pid_t) -> Int64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Actions

    /// Asks a standalone process to exit (SIGTERM). Apps should be quit through AppKit instead so they can save.
    public static func terminate(_ group: ProcessGroup) throws {
        guard !group.isSystem else {
            throw UninstallError.notAllowed(String(localized: "\(group.name) is part of macOS and can't be terminated."))
        }
        for pid in group.pids where pid != getpid() {
            if kill(pid, SIGTERM) != 0 && errno != ESRCH {
                throw UninstallError.notAllowed(String(localized: "Couldn't terminate \(group.name): \(String(cString: strerror(errno)))."))
            }
        }
    }

    /// Runs `purge`, which drops file caches. Needs administrator rights.
    /// Returns how much more memory is available afterwards.
    public static func purge(allowAdministrator: Bool) async throws -> Int64 {
        let before = stats()?.available ?? 0
        let result: ShellResult
        if geteuid() == 0 {
            result = try await Shell.run("/usr/sbin/purge", timeout: 120)
        } else if allowAdministrator {
            result = try await Shell.runAsAdministrator(
                "/usr/sbin/purge", [], prompt: String(localized: "Reclaim needs your password to clear the memory caches.")
            )
        } else {
            throw ShellError.failed(command: "purge", message: "needs administrator rights (run with sudo, or pass --admin)")
        }
        guard result.succeeded else { throw ShellError.failed(command: "purge", message: result.failureMessage) }
        let after = stats()?.available ?? before
        return max(0, after - before)
    }
}
