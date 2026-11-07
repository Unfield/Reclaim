import CoreServices
import Darwin
import Foundation

/// Where a launchd job lives, which decides who it runs for and whether changing it needs a password.
public enum LaunchItemDomain: Int, Sendable, CaseIterable, Comparable {
    /// `~/Library/LaunchAgents`: starts when you log in, only for you.
    case userAgent
    /// `/Library/LaunchAgents`: starts when anyone logs in.
    case systemAgent
    /// `/Library/LaunchDaemons`: runs in the background as root, even before anyone logs in.
    case systemDaemon

    public static func < (lhs: LaunchItemDomain, rhs: LaunchItemDomain) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .userAgent: String(localized: "Your Login Agents")
        case .systemAgent: String(localized: "System-Wide Agents")
        case .systemDaemon: String(localized: "Background Daemons")
        }
    }

    public var explanation: String {
        switch self {
        case .userAgent: String(localized: "Start when you log in. They only affect your account.")
        case .systemAgent: String(localized: "Start when anyone logs in. Changing them needs your password.")
        case .systemDaemon: String(localized: "Run in the background, even before you log in. Changing them needs your password.")
        }
    }

    public var requiresAdministrator: Bool { self != .userAgent }

    public func directory(home: URL) -> URL {
        switch self {
        case .userAgent: home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        case .systemAgent: URL(filePath: "/Library/LaunchAgents", directoryHint: .isDirectory)
        case .systemDaemon: URL(filePath: "/Library/LaunchDaemons", directoryHint: .isDirectory)
        }
    }

    /// The launchctl domain target: agents run in the user's GUI session, daemons in the system domain.
    public func launchctlDomain(uid: uid_t) -> String {
        self == .systemDaemon ? "system" : "gui/\(uid)"
    }
}

/// When a job runs, from its `RunAtLoad`, `KeepAlive`, `StartInterval` and `StartCalendarInterval` keys.
public struct LaunchSchedule: Sendable, Hashable {
    public enum KeepAlive: Sendable, Hashable {
        case never
        /// `KeepAlive = true`: launchd restarts it whenever it exits.
        case always
        /// `KeepAlive` is a dictionary: restarted only under some conditions (e.g. after a crash).
        case conditional
    }

    /// One `StartCalendarInterval` entry. Missing fields mean "every".
    public struct CalendarEntry: Sendable, Hashable {
        public var minute: Int?
        public var hour: Int?
        public var day: Int?
        public var weekday: Int?
        public var month: Int?

        public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
            self.minute = minute
            self.hour = hour
            self.day = day
            self.weekday = weekday
            self.month = month
        }
    }

    public var runAtLoad: Bool
    public var keepAlive: KeepAlive
    /// `StartInterval` in seconds.
    public var interval: Int?
    public var calendar: [CalendarEntry]
    /// Started by launchd when something happens (a file changes, a connection arrives…).
    public var startsOnDemand: Bool

    public init(runAtLoad: Bool = false, keepAlive: KeepAlive = .never, interval: Int? = nil, calendar: [CalendarEntry] = [], startsOnDemand: Bool = false) {
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.interval = interval
        self.calendar = calendar
        self.startsOnDemand = startsOnDemand
    }

    /// Short "when" text, e.g. "At login", "Always running", "At login, then every 30 minutes".
    public func summary(for domain: LaunchItemDomain) -> String {
        if keepAlive == .always { return String(localized: "Always running") }
        let start = domain == .systemDaemon ? String(localized: "At startup") : String(localized: "At login")
        let periodic = interval.map(Self.describe(interval:)) ?? calendarDescription
        switch (runAtLoad, periodic) {
        case (true, let periodic?): return String(localized: "\(start), then \(Self.lowercasedFirst(periodic))")
        case (true, nil): return start
        case (false, let periodic?): return periodic
        case (false, nil): return String(localized: "When needed")
        }
    }

    /// A plain explanation of the restart behavior, if there's anything worth saying.
    public var detail: String? {
        switch keepAlive {
        case .always: String(localized: "Keeps itself running")
        case .conditional: String(localized: "Restarts itself when needed")
        case .never: nil
        }
    }

    private var calendarDescription: String? {
        guard !calendar.isEmpty else { return nil }
        guard calendar.count == 1, let entry = calendar.first else { return String(localized: "On a schedule") }
        return Self.describe(entry)
    }

    static func describe(interval seconds: Int) -> String {
        switch seconds {
        case ..<1: return String(localized: "Repeatedly")
        case 1: return String(localized: "Every second")
        case 2..<60: return String(localized: "Every \(seconds) seconds")
        case 60: return String(localized: "Every minute")
        case 86_400: return String(localized: "Once a day")
        case 3_600: return String(localized: "Every hour")
        case let s where s % 86_400 == 0: return String(localized: "Every \(s / 86_400) days")
        case let s where s % 3_600 == 0: return String(localized: "Every \(s / 3_600) hours")
        default: return String(localized: "Every \(Int((Double(seconds) / 60).rounded())) minutes")
        }
    }

    static func describe(_ entry: CalendarEntry) -> String {
        let time: String? = entry.hour.map { String(format: "%02d:%02d", $0, entry.minute ?? 0) }
        if entry.month != nil { return String(localized: "On a schedule") }
        if let weekday = entry.weekday, let every = everyWeekday(weekday) {
            return time.map { String(localized: "\(every) at \($0)") } ?? every
        }
        if let day = entry.day {
            return time.map { String(localized: "Monthly on day \(day) at \($0)") } ?? String(localized: "Monthly on day \(day)")
        }
        if let time { return String(localized: "Daily at \(time)") }
        if let minute = entry.minute { return String(localized: "Hourly at :\(String(format: "%02d", minute))") }
        return String(localized: "Every minute")
    }

    /// launchd numbers weekdays 0 (Sunday) to 7 (Sunday again).
    private static func everyWeekday(_ weekday: Int) -> String? {
        switch weekday {
        case 0, 7: String(localized: "Every Sunday")
        case 1: String(localized: "Every Monday")
        case 2: String(localized: "Every Tuesday")
        case 3: String(localized: "Every Wednesday")
        case 4: String(localized: "Every Thursday")
        case 5: String(localized: "Every Friday")
        case 6: String(localized: "Every Saturday")
        default: nil
        }
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Whether the program a job runs is actually there.
public enum ProgramState: Sendable, Hashable {
    case present
    case missing
    /// Couldn't tell (no permission, a disk that isn't connected, a command looked up by name…). Never treated as broken.
    case unknown
}

public enum LaunchItemStatus: Sendable, Hashable {
    case on
    case off
    case broken

    public var label: String {
        switch self {
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        case .broken: String(localized: "Broken")
        }
    }
}

/// A launchd agent or daemon installed by a third-party app.
public struct LaunchItem: Identifiable, Sendable, Hashable {
    public var id: String { plistURL.path(percentEncoded: false) }
    public let label: String
    public let plistURL: URL
    public let domain: LaunchItemDomain
    /// The executable, from `Program` or the first of `ProgramArguments`.
    public let program: String?
    public let arguments: [String]
    public let schedule: LaunchSchedule
    public let associatedBundleIdentifiers: [String]
    /// The installed app this belongs to, if found.
    public let appURL: URL?
    /// The owning app's name, even if the app itself is gone.
    public let appName: String?
    public let programState: ProgramState
    /// Turned off with `launchctl disable` (or the legacy `Disabled` key).
    public var isDisabled: Bool
    /// Currently loaded into launchd; nil if unknown.
    public var isLoaded: Bool?
    /// PID if it's running right now.
    public var pid: Int32?

    public init(
        label: String, plistURL: URL, domain: LaunchItemDomain, program: String?, arguments: [String],
        schedule: LaunchSchedule, associatedBundleIdentifiers: [String], appURL: URL?, appName: String?,
        programState: ProgramState, isDisabled: Bool, isLoaded: Bool? = nil, pid: Int32? = nil
    ) {
        self.label = label
        self.plistURL = plistURL
        self.domain = domain
        self.program = program
        self.arguments = arguments
        self.schedule = schedule
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.appURL = appURL
        self.appName = appName
        self.programState = programState
        self.isDisabled = isDisabled
        self.isLoaded = isLoaded
        self.pid = pid
    }

    /// The program is missing or the job doesn't say what to run: launchd can't start it, so it's safe to remove.
    public var isBroken: Bool { programState == .missing }

    public var status: LaunchItemStatus { isBroken ? .broken : isDisabled ? .off : .on }

    public var displayName: String { appName ?? label }

    public var isRunning: Bool { (pid ?? 0) > 0 }

    /// What's wrong, in plain English.
    public var problem: String? {
        guard isBroken else { return nil }
        return program == nil ? String(localized: "Doesn't say what to run") : String(localized: "Program is missing")
    }

    /// The command it runs, with the home folder shortened to `~`.
    public var command: String {
        guard let program else { return "—" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let shortened = program.hasPrefix(home) ? "~/" + program.dropFirst(home.count).drop { $0 == "/" } : program
        return ([String(shortened)] + arguments.dropFirst()).joined(separator: " ")
    }
}

public enum LaunchItemError: Error, LocalizedError, Sendable {
    case notAllowed(String)
    case needsAdministrator(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let reason): reason
        case .needsAdministrator(let what): "\(what) needs administrator rights (run with sudo, or pass --admin)."
        }
    }
}

/// Reads and changes launchd agents and daemons. Apple's own (`com.apple.*`) are never listed or touched.
public enum LaunchItems {
    /// Who we're acting for. Under `sudo`, that's still the user who ran it.
    public struct Context: Sendable {
        public var uid: uid_t
        public var home: URL

        public init(uid: uid_t, home: URL) {
            self.uid = uid
            self.home = home
        }

        public static var current: Context {
            var uid = getuid()
            if uid == 0, let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap({ uid_t($0) }) {
                uid = sudoUID
            }
            if let entry = getpwuid(uid), let dir = entry.pointee.pw_dir {
                return Context(uid: uid, home: URL(filePath: String(cString: dir), directoryHint: .isDirectory))
            }
            return Context(uid: uid, home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// Finds the installed app for a bundle identifier.
    public typealias AppResolver = @Sendable (String) -> URL?

    // MARK: Listing

    /// Every third-party agent and daemon, with its on/off and loaded state from launchctl.
    public static func scan(context: Context = .current, resolver: @escaping AppResolver = defaultResolver) async -> [LaunchItem] {
        let fileItems = LaunchItemDomain.allCases.flatMap { domain in
            items(in: domain.directory(home: context.home), domain: domain, resolver: resolver)
        }

        let gui = "gui/\(context.uid)"
        async let guiDisabled = launchctlOutput(["print-disabled", gui])
        async let systemDisabled = launchctlOutput(["print-disabled", "system"])
        async let guiServices = launchctlOutput(["print", gui])
        async let systemServices = launchctlOutput(["print", "system"])

        let userOverrides = parseDisabledServices(await guiDisabled ?? "")
        let systemOverrides = parseDisabledServices(await systemDisabled ?? "")
        let guiOutput = await guiServices
        let systemOutput = await systemServices
        let userLoaded = guiOutput.map(parseServiceList)
        let systemLoaded = systemOutput.map(parseServiceList)

        return fileItems.map { item in
            var item = item
            let overrides = item.domain == .systemDaemon ? systemOverrides : userOverrides
            if let disabled = overrides[item.label] { item.isDisabled = disabled }
            if let loaded = item.domain == .systemDaemon ? systemLoaded : userLoaded {
                let pid = loaded[item.label]
                item.isLoaded = pid != nil
                item.pid = pid.flatMap { $0 > 0 ? $0 : nil }
            }
            return item
        }
        .sorted { ($0.domain, $0.displayName.localizedLowercase, $0.label) < ($1.domain, $1.displayName.localizedLowercase, $1.label) }
    }

    /// Parses every plist in one folder. Unreadable files and Apple's jobs are skipped.
    public static func items(in directory: URL, domain: LaunchItemDomain, resolver: AppResolver = defaultResolver) -> [LaunchItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { item(at: $0, domain: domain, resolver: resolver) }
    }

    /// Parses one job definition. Returns nil for unreadable files, files without a label, and Apple's jobs.
    public static func item(at url: URL, domain: LaunchItemDomain, resolver: AppResolver = defaultResolver) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty, !isApple(label)
        else { return nil }

        let arguments = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let explicitProgram = (plist["Program"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let program = explicitProgram ?? arguments.first
        let bundleIDs = stringList(plist["AssociatedBundleIdentifiers"])

        let programState: ProgramState
        if let program {
            programState = state(ofProgram: program)
        } else {
            // `BundleProgram` is relative to an app bundle we can't locate reliably; don't call it broken.
            programState = plist["BundleProgram"] is String ? .unknown : .missing
        }

        let owner = owningApp(program: program, bundleIDs: bundleIDs, label: label, resolver: resolver)
        return LaunchItem(
            label: label,
            plistURL: url,
            domain: domain,
            program: program,
            arguments: arguments,
            schedule: schedule(from: plist),
            associatedBundleIdentifiers: bundleIDs,
            appURL: owner.url,
            appName: owner.name,
            programState: programState,
            isDisabled: (plist["Disabled"] as? Bool) ?? false
        )
    }

    static func isApple(_ label: String) -> Bool {
        label.lowercased().hasPrefix("com.apple.")
    }

    static func schedule(from plist: [String: Any]) -> LaunchSchedule {
        let keepAlive: LaunchSchedule.KeepAlive
        switch plist["KeepAlive"] {
        case let value as Bool: keepAlive = value ? .always : .never
        case is [String: Any]: keepAlive = .conditional
        default: keepAlive = .never
        }

        let calendar: [LaunchSchedule.CalendarEntry]
        switch plist["StartCalendarInterval"] {
        case let entry as [String: Any]: calendar = [calendarEntry(entry)]
        case let entries as [Any]: calendar = entries.compactMap { ($0 as? [String: Any]).map(calendarEntry) }
        default: calendar = []
        }

        let triggers = ["WatchPaths", "QueueDirectories", "Sockets", "MachServices", "StartOnMount", "LaunchEvents"]
        return LaunchSchedule(
            runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
            keepAlive: keepAlive,
            interval: (plist["StartInterval"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            calendar: calendar,
            startsOnDemand: triggers.contains { plist[$0] != nil }
        )
    }

    private static func calendarEntry(_ dict: [String: Any]) -> LaunchSchedule.CalendarEntry {
        LaunchSchedule.CalendarEntry(
            minute: dict["Minute"] as? Int, hour: dict["Hour"] as? Int, day: dict["Day"] as? Int,
            weekday: dict["Weekday"] as? Int, month: dict["Month"] as? Int
        )
    }

    private static func stringList(_ value: Any?) -> [String] {
        switch value {
        case let string as String: [string]
        case let list as [Any]: list.compactMap { $0 as? String }
        default: []
        }
    }

    /// Only a definite "no such file" counts as missing, so a disconnected disk or a permission problem
    /// never makes a job look broken (and offered for removal).
    static func state(ofProgram program: String) -> ProgramState {
        let path = (program as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            // Looked up by name on launchd's default PATH.
            let found = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
                .contains { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(path)) }
            return found ? .present : .unknown
        }
        var info = stat()
        if stat(path, &info) == 0 { return .present }
        guard errno == ENOENT || errno == ENOTDIR else { return .unknown }

        let components = (path as NSString).pathComponents
        if components.count > 2, components[1] == "Volumes" {
            let volume = "/Volumes/" + components[2]
            if stat(volume, &info) != 0 { return .unknown }
        }
        return .missing
    }

    // MARK: Owning app

    static func owningApp(program: String?, bundleIDs: [String], label: String, resolver: AppResolver) -> (url: URL?, name: String?) {
        if let program, program.contains(".app/") {
            let group = MemoryMonitor.groupKey(forExecutable: program)
            if let bundle = group.bundle {
                let exists = FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false))
                return (exists ? bundle : nil, group.name)
            }
        }
        for id in bundleIDs {
            if let url = resolver(id) { return (url, appName(of: url)) }
        }
        // Many labels start with the app's bundle ID ("com.spotify.client.startuphelper"). Require at least
        // three components so a bare vendor prefix ("com.docker") never matches an unrelated app.
        var components = label.split(separator: ".").map(String.init)
        while components.count >= 3 {
            if let url = resolver(components.joined(separator: ".")) { return (url, appName(of: url)) }
            components.removeLast()
        }
        return (nil, nil)
    }

    static func appName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Looks the bundle ID up with Launch Services, ignoring copies in the Trash.
    public static let defaultResolver: AppResolver = { bundleID in
        guard let unmanaged = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil) else { return nil }
        let urls = (unmanaged.takeRetainedValue() as? [URL]) ?? []
        return urls.first { url in
            let path = url.path(percentEncoded: false)
            return !path.contains("/.Trash/") && FileManager.default.fileExists(atPath: path)
        }
    }

    // MARK: launchctl output

    private static func launchctlOutput(_ arguments: [String]) async -> String? {
        guard let result = try? await Shell.run("/bin/launchctl", arguments, timeout: 15), result.succeeded else { return nil }
        return result.output
    }

    /// Parses `launchctl print-disabled`: `"label" => disabled|enabled` (older systems print `true|false`).
    /// Returns label → isDisabled.
    public static func parseDisabledServices(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\""), let arrow = text.range(of: "\" => ") else { continue }
            let label = String(text[text.index(after: text.startIndex)..<arrow.lowerBound])
            switch text[arrow.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// Parses the `services = { … }` block of `launchctl print <domain>`: `PID  last-exit  label` per line.
    /// Returns label → PID (0 when loaded but not running).
    public static func parseServiceList(_ output: String) -> [String: Int32] {
        var result: [String: Int32] = [:]
        var inServices = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !inServices {
                if text == "services = {" { inServices = true }
                continue
            }
            if text == "}" { break }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]) else { continue }
            result[fields[2...].joined(separator: " ")] = pid
        }
        return result
    }

    // MARK: Actions

    /// Characters launchd labels use in practice. Anything else is refused rather than passed to a shell.
    static func validate(_ item: LaunchItem, context: Context) throws {
        guard !isApple(item.label) else {
            throw LaunchItemError.notAllowed(String(localized: "\(item.label) is part of macOS and can't be changed."))
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@+")
        guard item.label.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LaunchItemError.notAllowed(String(localized: "\(item.label) has an unusual name, so Reclaim won't change it."))
        }
        let folder = item.domain.directory(home: context.home).standardizedFileURL.path(percentEncoded: false)
        let parent = item.plistURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        guard folder.trimmingSuffix("/") == parent.trimmingSuffix("/") else {
            throw LaunchItemError.notAllowed(String(localized: "\(item.plistURL.lastPathComponent) isn't in a launch agent or daemon folder."))
        }
    }

    /// The launchctl commands that turn a job off (and stop it now) or on (and load it now).
    /// The first command must succeed; the rest are best effort (e.g. it may not be loaded).
    public static func commands(for item: LaunchItem, enable: Bool, uid: uid_t) -> [[String]] {
        let domain = item.domain.launchctlDomain(uid: uid)
        let target = "\(domain)/\(item.label)"
        if enable {
            return [["enable", target], ["bootstrap", domain, item.plistURL.path(percentEncoded: false)]]
        }
        return [["disable", target], ["bootout", target]]
    }

    /// Turns a job on or off. User agents need no password; everything else asks for one (or needs root).
    public static func setEnabled(_ enabled: Bool, _ item: LaunchItem, allowAdministrator: Bool, context: Context = .current) async throws {
        try validate(item, context: context)
        if enabled && item.isBroken {
            throw LaunchItemError.notAllowed(String(localized: "\(item.displayName) can't be turned on because its program is missing."))
        }
        let commands = commands(for: item, enable: enabled, uid: context.uid)
        let what = "\(enabled ? "Turning on" : "Turning off") \(item.label)"
        try await run(commands, item: item, allowAdministrator: allowAdministrator, description: what,
                      prompt: enabled
                          ? String(localized: "Reclaim needs your password to turn on \(item.displayName).")
                          : String(localized: "Reclaim needs your password to turn off \(item.displayName)."))
    }

    /// Removes a broken job: stops it if launchd still has it, then moves its plist to the Trash.
    /// Returns a Trash record for user-owned files (so it can be put back); admin moves return nil.
    @discardableResult
    public static func remove(_ item: LaunchItem, allowAdministrator: Bool, context: Context = .current) async throws -> TrashRecord? {
        try validate(item, context: context)
        guard item.isBroken else {
            throw LaunchItemError.notAllowed(String(localized: "Only items whose program is missing can be removed. Turn \(item.displayName) off instead."))
        }
        let target = "\(item.domain.launchctlDomain(uid: context.uid))/\(item.label)"
        let source = item.plistURL.path(percentEncoded: false)

        if !item.domain.requiresAdministrator {
            _ = try? await Shell.run("/bin/launchctl", ["bootout", target], timeout: 15)
            let size = (try? item.plistURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return try Trash.move(item.plistURL, size: size)
        }

        let trash = context.home.appending(path: ".Trash", directoryHint: .isDirectory)
        var destination = trash.appending(path: item.plistURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            let stamp = Int(Date().timeIntervalSince1970)
            destination = trash.appending(path: "\(item.plistURL.deletingPathExtension().lastPathComponent) \(stamp).plist")
        }
        let script = "/bin/launchctl bootout \(Shell.shellQuote(target)) 2>/dev/null; /bin/mv -n \(Shell.shellQuote(source)) \(Shell.shellQuote(destination.path(percentEncoded: false)))"
        let result = try await runPrivileged(script, allowAdministrator: allowAdministrator,
                                             description: "Removing \(item.label)",
                                             prompt: String(localized: "Reclaim needs your password to move \(item.displayName)'s launch file to the Trash."))
        guard result.succeeded else { throw ShellError.failed(command: "mv", message: result.failureMessage) }
        return nil
    }

    private static func run(_ commands: [[String]], item: LaunchItem, allowAdministrator: Bool, description: String, prompt: String) async throws {
        guard let first = commands.first else { return }
        if !item.domain.requiresAdministrator {
            let result = try await Shell.run("/bin/launchctl", first, timeout: 15)
            guard result.succeeded else { throw ShellError.failed(command: "launchctl \(first.joined(separator: " "))", message: result.failureMessage) }
            for command in commands.dropFirst() {
                _ = try? await Shell.run("/bin/launchctl", command, timeout: 15)
            }
            return
        }

        // One password prompt for all steps: the first must succeed, the rest are best effort.
        let quoted = commands.map { (["/bin/launchctl"] + $0.map(Shell.shellQuote)).joined(separator: " ") }
        let rest = quoted.dropFirst().map { "\($0) 2>/dev/null" }.joined(separator: "; ")
        let script = rest.isEmpty ? quoted[0] : "\(quoted[0]) && { \(rest); true; }"
        let result = try await runPrivileged(script, allowAdministrator: allowAdministrator, description: description, prompt: prompt)
        guard result.succeeded else { throw ShellError.failed(command: "launchctl \(first.joined(separator: " "))", message: result.failureMessage) }
    }

    private static func runPrivileged(_ script: String, allowAdministrator: Bool, description: String, prompt: String) async throws -> ShellResult {
        if geteuid() == 0 {
            return try await Shell.run("/bin/sh", ["-c", script], timeout: 30)
        }
        guard allowAdministrator else { throw LaunchItemError.needsAdministrator(description) }
        return try await Shell.runAsAdministrator("/bin/sh", ["-c", script], prompt: prompt)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
