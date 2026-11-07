import Foundation

/// Removes unavailable Xcode simulators and old simulator runtimes via `xcrun simctl`.
public struct XcodeSimulatorsTool: MaintenanceTool {
    public let id = "xcode-simulators"
    public let name = "Xcode Simulators"
    public let summary = "Simulators for iOS versions you no longer have, and old simulator runtimes."
    public let safety = SafetyLevel.review
    public let options = [
        ToolOption(
            id: "runtimes",
            title: "Old simulator runtimes",
            detail: "Deletes runtimes that no simulator uses or that are older than the newest one for their platform. Simulators using them are removed too. Xcode can download them again (several GB each).",
            isEnabledByDefault: false,
            safety: .review
        ),
        ToolOption(
            id: "erase-all",
            title: "Erase all simulators",
            detail: "Shuts down every simulator and erases its apps, data and settings. The simulators themselves are kept.",
            isEnabledByDefault: false,
            safety: .caution
        ),
    ]

    /// Runs a command (`xcrun`, `xcode-select`) with arguments and a timeout. Injectable for tests.
    public typealias CommandRunner = @Sendable (_ command: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> ShellResult
    /// Measures a path in bytes, or nil if it doesn't exist. Injectable for tests.
    public typealias PathSizer = @Sendable (_ path: String) -> Int64?

    let run: CommandRunner
    let measure: PathSizer

    public init() {
        self.init(
            run: { command, arguments, timeout in try await Shell.run(command, arguments, timeout: timeout) },
            measure: Self.sizeOnDisk
        )
    }

    init(run: @escaping CommandRunner, measure: @escaping PathSizer) {
        self.run = run
        self.measure = measure
    }

    // MARK: Status

    public func status() async -> ToolStatus {
        guard await isAvailable() else { return .notInstalled }
        let devices: [Device]
        do {
            devices = try await listDevices()
        } catch {
            return ToolStatus(availability: .unavailable(error.localizedDescription))
        }

        var entries = [ToolEntry]()

        let unavailable = devices.filter { !$0.isAvailable }
        if !unavailable.isEmpty {
            entries.append(ToolEntry(
                title: "Unavailable simulators",
                detail: Self.describe(unavailable),
                size: totalSize(of: unavailable.flatMap(\.paths))
            ))
        }

        if let runtimes = await listRuntimes() {
            let unused = Self.removableRuntimes(runtimes, devices: devices)
            if !unused.isEmpty {
                let sizes = unused.compactMap(\.sizeBytes)
                entries.append(ToolEntry(
                    title: "Unused simulator runtimes",
                    detail: unused.map(\.displayName).joined(separator: ", "),
                    size: sizes.isEmpty ? nil : sizes.reduce(0, +),
                    optionID: "runtimes"
                ))
            }
        }

        let available = devices.filter(\.isAvailable)
        if !available.isEmpty {
            let count = available.count
            entries.append(ToolEntry(
                title: "Simulator data",
                detail: "Apps and data in \(count) \(count == 1 ? "simulator" : "simulators")",
                size: totalSize(of: available.compactMap(\.dataPath)),
                optionID: "erase-all"
            ))
        }

        return ToolStatus(
            availability: .ready,
            entries: entries,
            note: "Unavailable simulators belong to runtimes or device types that are no longer installed."
        )
    }

    // MARK: Cleaning

    public func clean(options: Set<String>, allowAdministrator: Bool) async throws -> ToolCleanResult {
        var log = ""
        var freed: Int64 = 0

        func simctl(_ arguments: [String], timeout: TimeInterval = 900) async throws -> ShellResult {
            let result = try await run("xcrun", ["simctl"] + arguments, timeout)
            log += "$ xcrun simctl \(arguments.joined(separator: " "))\n" + result.output + result.errorOutput
            return result
        }

        // Runtimes go first: simulators that used them become unavailable and are removed in the next step.
        if options.contains("runtimes"), let runtimes = await listRuntimes() {
            let devices = try await listDevices()
            for runtime in Self.removableRuntimes(runtimes, devices: devices) {
                let result = try await simctl(["runtime", "delete", runtime.identifier], timeout: 600)
                if result.succeeded {
                    freed += runtime.sizeBytes ?? 0
                } else {
                    // One stubborn runtime (e.g. one bundled with Xcode) shouldn't stop the rest of the cleanup.
                    log += "Couldn't delete \(runtime.displayName): \(result.failureMessage)\n"
                }
            }
        }

        let unavailablePaths = try await listDevices().filter { !$0.isAvailable }.flatMap(\.paths)
        let unavailableBefore = totalSize(of: unavailablePaths) ?? 0
        let delete = try await simctl(["delete", "unavailable"])
        guard delete.succeeded else {
            throw ShellError.failed(command: "xcrun simctl delete unavailable", message: delete.failureMessage)
        }
        freed += max(0, unavailableBefore - (totalSize(of: unavailablePaths) ?? 0))

        if options.contains("erase-all") {
            let dataPaths = try await listDevices().filter(\.isAvailable).compactMap(\.dataPath)
            let dataBefore = totalSize(of: dataPaths) ?? 0
            // `erase` refuses booted simulators. `shutdown all` fails harmlessly when none are running.
            _ = try await simctl(["shutdown", "all"], timeout: 300)
            let erase = try await simctl(["erase", "all"])
            guard erase.succeeded else {
                throw ShellError.failed(command: "xcrun simctl erase all", message: erase.failureMessage)
            }
            freed += max(0, dataBefore - (totalSize(of: dataPaths) ?? 0))
        }

        return ToolCleanResult(freed: freed, log: log)
    }

    // MARK: Commands

    /// `simctl` needs a full Xcode. Checks `xcode-select` first, because on a Mac with no developer tools at all
    /// running `xcrun` pops up the "install command line developer tools" dialog.
    func isAvailable() async -> Bool {
        guard let developerDir = try? await run("xcode-select", ["-p"], 30), developerDir.succeeded else { return false }
        guard let help = try? await run("xcrun", ["simctl", "help"], 60) else { return false }
        return help.succeeded
    }

    func listDevices() async throws -> [Device] {
        let result = try await run("xcrun", ["simctl", "list", "devices", "--json"], 120)
        guard result.succeeded else {
            throw ShellError.failed(command: "xcrun simctl list devices", message: result.failureMessage)
        }
        guard let devices = Self.parseDevices(result.output) else {
            throw ShellError.failed(command: "xcrun simctl list devices", message: "Unexpected output.")
        }
        return devices
    }

    /// Nil if runtimes can't be listed, e.g. before Xcode 15, which added `simctl runtime`.
    func listRuntimes() async -> [Runtime]? {
        guard let result = try? await run("xcrun", ["simctl", "runtime", "list", "--json"], 120), result.succeeded else {
            return nil
        }
        return Self.parseRuntimes(result.output)
    }

    private func totalSize(of paths: [String]) -> Int64? {
        let sizes = paths.compactMap(measure)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    @Sendable static func sizeOnDisk(_ path: String) -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return DirectorySizer().size(of: URL(filePath: path)).bytes
    }

    // MARK: Model

    public struct Device: Sendable, Hashable {
        public let udid: String
        public let name: String
        /// e.g. `com.apple.CoreSimulator.SimRuntime.iOS-17-0`
        public let runtimeIdentifier: String
        public let state: String?
        public let isAvailable: Bool
        public let availabilityError: String?
        public let dataPath: String?
        public let logPath: String?

        var paths: [String] { [dataPath, logPath].compactMap { $0 } }
    }

    public struct Runtime: Sendable, Hashable {
        /// The UUID `simctl runtime delete` expects.
        public let identifier: String
        public let version: String?
        public let build: String?
        /// e.g. `com.apple.platform.iphonesimulator`
        public let platformIdentifier: String?
        /// e.g. `com.apple.CoreSimulator.SimRuntime.iOS-17-0`, matching the keys of `simctl list devices`.
        public let runtimeIdentifier: String?
        public let sizeBytes: Int64?
        public let lastUsedAt: Date?
        public let isDeletable: Bool
        public let state: String?

        /// e.g. "iOS 17.0"
        public var displayName: String {
            let parsed = runtimeIdentifier.flatMap(XcodeSimulatorsTool.parseRuntimeIdentifier)
            switch (parsed?.platform, version ?? parsed?.version) {
            case let (platform?, version?): return "\(platform) \(version)"
            case let (nil, version?): return version
            case let (platform?, nil): return platform
            case (nil, nil): return identifier
            }
        }

        var platformKey: String {
            platformIdentifier ?? runtimeIdentifier.flatMap(XcodeSimulatorsTool.parseRuntimeIdentifier)?.platform ?? "unknown"
        }
    }

    // MARK: Parsing

    /// Parses `xcrun simctl list devices --json`: `{"devices": {"<runtime id>": [{device}, …]}}`.
    /// Returns nil if the output isn't in that shape at all; malformed devices are skipped.
    static func parseDevices(_ output: String) -> [Device]? {
        guard let root = jsonObject(output), let groups = root["devices"] as? [String: Any] else { return nil }
        var devices = [Device]()
        for runtimeIdentifier in groups.keys.sorted() {
            guard let list = groups[runtimeIdentifier] as? [Any] else { continue }
            for case let item as [String: Any] in list {
                guard let udid = item["udid"] as? String, !udid.isEmpty else { continue }
                devices.append(Device(
                    udid: udid,
                    name: item["name"] as? String ?? udid,
                    runtimeIdentifier: runtimeIdentifier,
                    state: item["state"] as? String,
                    isAvailable: availability(of: item),
                    availabilityError: item["availabilityError"] as? String,
                    dataPath: nonEmptyString(item["dataPath"]),
                    logPath: nonEmptyString(item["logPath"])
                ))
            }
        }
        return devices
    }

    /// Parses `xcrun simctl runtime list --json`: an object keyed by runtime UUID. Returns nil for unexpected output.
    static func parseRuntimes(_ output: String) -> [Runtime]? {
        guard let root = jsonObject(output) else { return nil }
        var runtimes = [Runtime]()
        for key in root.keys.sorted() {
            guard let item = root[key] as? [String: Any] else { continue }
            let identifier = nonEmptyString(item["identifier"]) ?? key
            runtimes.append(Runtime(
                identifier: identifier,
                version: nonEmptyString(item["version"]),
                build: nonEmptyString(item["build"]),
                platformIdentifier: nonEmptyString(item["platformIdentifier"]),
                runtimeIdentifier: nonEmptyString(item["runtimeIdentifier"]),
                sizeBytes: int64(item["sizeBytes"]),
                lastUsedAt: nonEmptyString(item["lastUsedAt"]).flatMap(parseDate),
                isDeletable: bool(item["deletable"]) ?? true,
                state: nonEmptyString(item["state"])
            ))
        }
        return runtimes
    }

    /// Runtimes worth offering for deletion: deletable ones that no available simulator uses, or that are older
    /// than the newest runtime of the same platform. Runtimes already being deleted are skipped.
    static func removableRuntimes(_ runtimes: [Runtime], devices: [Device]) -> [Runtime] {
        let inUse = Set(devices.filter(\.isAvailable).map(\.runtimeIdentifier))
        let candidates = runtimes.filter { runtime in
            runtime.isDeletable && !(runtime.state?.localizedCaseInsensitiveContains("delet") ?? false)
        }
        var newest = [String: String]()
        for runtime in runtimes {
            guard let version = runtime.version else { continue }
            if newest[runtime.platformKey].map({ compareVersions(version, $0) == .orderedDescending }) ?? true {
                newest[runtime.platformKey] = version
            }
        }
        return candidates
            .filter { runtime in
                let isUsed = runtime.runtimeIdentifier.map(inUse.contains) ?? true
                var isOlder = false
                if let version = runtime.version, let latest = newest[runtime.platformKey] {
                    isOlder = compareVersions(version, latest) == .orderedAscending
                }
                return !isUsed || isOlder
            }
            .sorted { ($0.platformKey, $0.version ?? "") < ($1.platformKey, $1.version ?? "") }
    }

    /// "iPhone 15 (iOS 17.0), iPad Air (iOS 16.4)", shortened to a few names.
    static func describe(_ devices: [Device]) -> String {
        let names = devices.prefix(3).map { device in
            platformName(fromRuntimeIdentifier: device.runtimeIdentifier).map { "\(device.name) (\($0))" } ?? device.name
        }
        let count = devices.count
        let prefix = "\(count) \(count == 1 ? "device" : "devices"): "
        return prefix + names.joined(separator: ", ") + (count > 3 ? ", …" : "")
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → "iOS 17.0", `…SimRuntime.xrOS-1-0` → "visionOS 1.0".
    static func platformName(fromRuntimeIdentifier identifier: String) -> String? {
        parseRuntimeIdentifier(identifier).map { "\($0.platform) \($0.version)" }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → ("iOS", "17.0").
    static func parseRuntimeIdentifier(_ identifier: String) -> (platform: String, version: String)? {
        guard let suffix = identifier.split(separator: ".").last, !suffix.isEmpty else { return nil }
        let parts = suffix.split(separator: "-")
        guard let platform = parts.first, parts.count > 1, parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return nil }
        return (platform == "xrOS" ? "visionOS" : String(platform), parts.dropFirst().joined(separator: "."))
    }

    /// Compares dotted version strings numerically, so "17.10" > "17.9" and "18" == "18.0".
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Lenient JSON helpers

    private static func jsonObject(_ output: String) -> [String: Any]? {
        // Some Xcode versions print warnings before the JSON; start at the first brace.
        guard let start = output.firstIndex(of: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(output[start...].utf8))) as? [String: Any]
    }

    private static func availability(of device: [String: Any]) -> Bool {
        if let value = bool(device["isAvailable"]) { return value }
        // Xcode 10 and older: "availability": "(unavailable, runtime profile not found)"
        if let text = device["availability"] as? String { return !text.contains("unavailable") }
        return true // When in doubt, treat it as available so it's never deleted.
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["yes", "true", "1"].contains(text.lowercased()) ? true
            : ["no", "false", "0"].contains(text.lowercased()) ? false : nil
        default: nil
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: number.int64Value
        case let text as String: Int64(text)
        default: nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

