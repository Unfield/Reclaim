import CoreServices
import Foundation

// MARK: - Model

/// A folder in ~/Library where apps keep data named after their bundle ID.
public enum LeftoverKind: String, Sendable, CaseIterable, Hashable {
    case applicationSupport
    case caches
    case containers
    case preferences
    case savedState
    case httpStorages
    case webKit
    case logs
    case applicationScripts
    case cookies

    /// The folder inside ~/Library.
    public var folderName: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .containers: "Containers"
        case .preferences: "Preferences"
        case .savedState: "Saved Application State"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        case .logs: "Logs"
        case .applicationScripts: "Application Scripts"
        case .cookies: "Cookies"
        }
    }

    public var title: String {
        switch self {
        case .applicationSupport: "App Data"
        case .caches: "Cache"
        case .containers: "Container"
        case .preferences: "Settings"
        case .savedState: "Saved Windows"
        case .httpStorages: "Web Storage"
        case .webKit: "WebKit Data"
        case .logs: "Logs"
        case .applicationScripts: "Scripts"
        case .cookies: "Cookies"
        }
    }

    /// What follows the bundle ID in an entry's name. An empty suffix means the entry is named exactly like the ID.
    var suffixes: [String] {
        switch self {
        case .preferences: [".plist"]
        case .savedState: [".savedState"]
        case .cookies: [".binarycookies"]
        case .httpStorages: [".binarycookies", ""]
        default: [""]
        }
    }

    /// Reading inside another app's container makes macOS ask "would like to access data from other apps",
    /// so containers are only measured when the user asks for it.
    public var isPrivacyProtected: Bool { self == .containers }
}

/// One file or folder an uninstalled app left behind.
public struct LeftoverLocation: Identifiable, Sendable, Hashable {
    public let bundleID: String
    public let kind: LeftoverKind
    public let url: URL
    /// Nil until measured (containers aren't measured during a scan).
    public var size: Int64?
    public var modified: Date?

    public init(bundleID: String, kind: LeftoverKind, url: URL, size: Int64?, modified: Date?) {
        self.bundleID = bundleID
        self.kind = kind
        self.url = url
        self.size = size
        self.modified = modified
    }

    public var id: URL { url }
}

/// Everything left behind by one bundle ID.
public struct LeftoverGroup: Identifiable, Sendable, Hashable {
    public let bundleID: String
    /// A best guess; the app itself is gone.
    public let name: String
    /// Largest first.
    public var locations: [LeftoverLocation]

    public init(bundleID: String, name: String, locations: [LeftoverLocation]) {
        self.bundleID = bundleID
        self.name = name
        self.locations = locations
    }

    public var id: String { bundleID }
    /// Leftovers can hold settings or documents, so they're never "Safe".
    public var safety: SafetyLevel { .review }
    /// Total of the measured locations.
    public var size: Int64 { locations.reduce(0) { $0 + ($1.size ?? 0) } }
    public var hasUnmeasuredLocations: Bool { locations.contains { $0.size == nil } }
    public var lastModified: Date? { locations.compactMap(\.modified).max() }

    /// Recently written data suggests something still uses it (e.g. an app outside the usual folders).
    public func isRecentlyModified(within days: Int = 7, now: Date = Date()) -> Bool {
        guard let lastModified else { return false }
        return lastModified > now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }
}

public struct LeftoverScan: Sendable {
    /// Largest first.
    public var groups: [LeftoverGroup]
    /// Library folders that couldn't be listed (usually needs Full Disk Access).
    public var unreadableFolders: [URL]

    public init(groups: [LeftoverGroup], unreadableFolders: [URL]) {
        self.groups = groups
        self.unreadableFolders = unreadableFolders
    }
}

public enum LeftoverError: Error, LocalizedError, Sendable {
    case notALeftover(URL)
    case stillInstalled(String)
    case symbolicLink(URL)
    case excluded(URL)
    case missing(URL)

    public var errorDescription: String? {
        switch self {
        case .notALeftover(let url): "\(url.abbreviatedPath) isn't a known leftover location."
        case .stillInstalled(let id): "An app with the ID \(id) is installed or running."
        case .symbolicLink(let url): "\(url.abbreviatedPath) is a symbolic link."
        case .excluded(let url): "\(url.abbreviatedPath) is in your exclusion list."
        case .missing(let url): "\(url.abbreviatedPath) no longer exists."
        }
    }
}

// MARK: - Installed bundle IDs

/// Bundle IDs that count as installed. An ID is covered if it equals an installed ID, or if one is a
/// dotted prefix of the other (installed `com.google.Chrome` covers `com.google.Chrome.helper` and vice versa).
public struct InstalledBundleIndex: Sendable {
    private var exact = Set<String>()
    /// Proper dotted prefixes (3+ components) of installed IDs.
    private var prefixes = Set<String>()

    public init(_ ids: some Sequence<String> = []) {
        for id in ids { insert(id) }
    }

    public var count: Int { exact.count }

    public mutating func insert(_ id: String) {
        let lower = id.lowercased()
        guard !lower.isEmpty else { return }
        exact.insert(lower)
        var parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        while parts.count > 3 {
            parts.removeLast()
            prefixes.insert(parts.joined(separator: "."))
        }
    }

    public func covers(_ id: String) -> Bool {
        let lower = id.lowercased()
        if exact.contains(lower) || prefixes.contains(lower) { return true }
        var parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        while parts.count > 2 {
            parts.removeLast()
            if exact.contains(parts.joined(separator: ".")) { return true }
        }
        return false
    }
}

// MARK: - Finder

/// Finds data in ~/Library left behind by apps that are no longer installed.
///
/// Conservative by design: an ID counts as installed if LaunchServices knows an existing app for it, if any
/// app bundle (or a helper, extension or framework nested inside one) in the app folders uses it, if a launch
/// agent/daemon or privileged helper refers to it, or if a running process uses it.
public struct OrphanFinder: Sendable {
    public let home: URL
    /// Folders searched for app bundles (and other bundles such as preference panes).
    public let appRoots: [URL]
    /// Folders with launchd plists and privileged helpers, whose names and labels count as installed IDs.
    public let serviceFolders: [URL]
    public let exclusions: Exclusions
    /// Apps LaunchServices and Spotlight know for a bundle ID (they may no longer exist).
    public let applicationURLs: @Sendable (String) -> [URL]
    /// Bundle IDs of running processes.
    public let runningBundleIDs: @Sendable () -> [String]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appRoots: [URL]? = nil,
        serviceFolders: [URL]? = nil,
        exclusions: Exclusions = .load(),
        applicationURLs: @escaping @Sendable (String) -> [URL] = { OrphanFinder.launchServicesURLs(for: $0) + OrphanFinder.spotlightURLs(for: $0) },
        runningBundleIDs: @escaping @Sendable () -> [String] = OrphanFinder.runningProcessBundleIDs
    ) {
        self.home = home
        self.appRoots = appRoots ?? [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            URL(filePath: "/Library/PreferencePanes", directoryHint: .isDirectory),
            home.appending(path: "Library/PreferencePanes", directoryHint: .isDirectory),
            URL(filePath: "/Library/Input Methods", directoryHint: .isDirectory),
            home.appending(path: "Library/Input Methods", directoryHint: .isDirectory),
            URL(filePath: "/Library/Screen Savers", directoryHint: .isDirectory),
            home.appending(path: "Library/Screen Savers", directoryHint: .isDirectory),
        ]
        self.serviceFolders = serviceFolders ?? [
            home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory),
            URL(filePath: "/Library/LaunchAgents", directoryHint: .isDirectory),
            URL(filePath: "/Library/LaunchDaemons", directoryHint: .isDirectory),
            URL(filePath: "/Library/PrivilegedHelperTools", directoryHint: .isDirectory),
        ]
        self.exclusions = exclusions
        self.applicationURLs = applicationURLs
        self.runningBundleIDs = runningBundleIDs
    }

    var library: URL { home.appending(path: "Library", directoryHint: .isDirectory) }

    func folder(for kind: LeftoverKind) -> URL {
        library.appending(path: kind.folderName, directoryHint: .isDirectory)
    }

    // MARK: Scanning

    /// Finds leftovers, largest first. Containers aren't measured (see `LeftoverKind.isPrivacyProtected`).
    public func scan() async -> LeftoverScan {
        let index = installedIndex()
        var unreadable = [URL]()
        // Keyed by lowercased ID: bundle IDs are case-insensitive.
        var found = [String: [LeftoverLocation]]()
        var order = [String]()

        // Removal refuses symlinked Library folders, so they aren't offered either.
        let kinds = Self.isSymbolicLink(library) ? [] : LeftoverKind.allCases.filter { !Self.isSymbolicLink(folder(for: $0)) }
        for kind in kinds {
            let folder = folder(for: kind)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            } catch {
                if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) { unreadable.append(folder) }
                continue
            }
            for name in names.sorted() {
                guard let id = Self.bundleID(fromEntry: name, kind: kind), !index.covers(id) else { continue }
                let url = folder.appending(path: name)
                guard !exclusions.excludes(url), !Self.isSymbolicLink(url) else { continue }
                let key = id.lowercased()
                if found[key] == nil { order.append(key) }
                found[key, default: []].append(LeftoverLocation(bundleID: id, kind: kind, url: url, size: nil, modified: nil))
            }
        }

        // LaunchServices and Spotlight are only asked about the few remaining candidates.
        var nameHints = [String: URL]()
        for key in order {
            guard let id = found[key]?.first?.bundleID else { continue }
            let known = applicationURLs(id)
            if known.contains(where: Self.isLiveApp) {
                found[key] = nil
            } else if let hint = known.first {
                nameHints[key] = hint
            }
        }

        // Extensions and helpers of a removed app (`com.vendor.App.Widget`) join the app's group (`com.vendor.App`).
        // Each location keeps its own bundle ID, which is what removal validates against.
        let remaining = order.filter { found[$0] != nil }
        for key in remaining.sorted(by: { $0.count < $1.count }) {
            guard let parent = remaining.first(where: { key.hasPrefix($0 + ".") && found[$0] != nil }),
                  let locations = found.removeValue(forKey: key)
            else { continue }
            found[parent, default: []].append(contentsOf: locations)
        }

        let candidates = order.compactMap { found[$0] }.flatMap { $0 }
        let measured = await withTaskGroup(of: LeftoverLocation.self) { group in
            for location in candidates {
                group.addTask { Self.measured(location, includingProtected: false) }
            }
            var results = [URL: LeftoverLocation]()
            for await location in group { results[location.url] = location }
            return results
        }

        let groups = order.compactMap { key -> LeftoverGroup? in
            guard let locations = found[key], let first = locations.first(where: { $0.bundleID.lowercased() == key }) ?? locations.first else { return nil }
            return LeftoverGroup(
                bundleID: first.bundleID,
                name: Self.guessName(for: first.bundleID, appURL: nameHints[key]),
                locations: Self.sorted(locations.map { measured[$0.url] ?? $0 })
            )
        }
        return LeftoverScan(groups: Self.sorted(groups), unreadableFolders: unreadable)
    }

    /// Largest first; ties by name, so the order is stable between scans.
    public static func sorted(_ groups: [LeftoverGroup]) -> [LeftoverGroup] {
        groups.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending
        }
    }

    /// Largest first, unmeasured last; ties by folder, then path.
    public static func sorted(_ locations: [LeftoverLocation]) -> [LeftoverLocation] {
        locations.sorted { ($0.size ?? -1, $1.kindOrder, $1.url.path) > ($1.size ?? -1, $0.kindOrder, $0.url.path) }
    }

    /// The group with every location measured, including containers (macOS may ask for permission).
    public static func measured(_ group: LeftoverGroup) -> LeftoverGroup {
        var group = group
        group.locations = sorted(group.locations.map { measured($0) })
        return group
    }

    /// Measures a location. Protected locations (containers) are skipped unless `includingProtected` is set,
    /// in which case macOS may ask the user for permission.
    public static func measured(_ location: LeftoverLocation, includingProtected: Bool = true) -> LeftoverLocation {
        var location = location
        if location.kind.isPrivacyProtected && !includingProtected {
            // The entry's own date lives in ~/Library/Containers itself, so reading it doesn't need permission.
            location.modified = (try? location.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return location
        }
        let result = measure(location.url)
        location.size = result.bytes
        location.modified = result.modified
        return location
    }

    /// Allocated size and newest modification date of a file or folder, without following symbolic links.
    public static func measure(_ url: URL) -> (bytes: Int64, modified: Date?) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, nil) }
        var newest = values.contentModificationDate
        func allocated(_ values: URLResourceValues) -> Int64 {
            Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return (allocated(values), newest)
        }

        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let childValues = try? child.resourceValues(forKeys: keys) else { continue }
            if let date = childValues.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
            if childValues.isDirectory == true && childValues.isSymbolicLink != true { continue }
            total += allocated(childValues)
        }
        return (total, newest)
    }

    // MARK: Removal

    /// Re-checks every location right before removing it: it must be exactly a leftover location for its bundle ID,
    /// the ID must still not be installed, and it must not be a symbolic link or excluded.
    public func remove(_ locations: [LeftoverLocation], method: CleanupMethod = .moveToTrash) -> CleanupReport {
        var report = CleanupReport(dryRun: false)
        guard !locations.isEmpty else { return report }
        let index = installedIndex()
        var installedVerdicts = [String: Bool]()

        for location in locations {
            var item = CleanupItem(url: location.url, size: location.size ?? 0, modified: location.modified)
            do {
                try validateLocation(location)
                let key = location.bundleID.lowercased()
                let isInstalled: Bool
                if let known = installedVerdicts[key] {
                    isInstalled = known
                } else {
                    isInstalled = index.covers(location.bundleID) || applicationURLs(location.bundleID).contains(where: Self.isLiveApp)
                    installedVerdicts[key] = isInstalled
                }
                if isInstalled { throw LeftoverError.stillInstalled(location.bundleID) }

                if location.size == nil { item = CleanupItem(url: location.url, size: Self.measure(location.url).bytes, modified: location.modified) }
                switch method {
                case .moveToTrash:
                    report.trashed.append(try Trash.move(location.url, size: item.size))
                case .deletePermanently:
                    try FileManager.default.removeItem(at: location.url)
                }
                report.removed.append(item)
            } catch {
                report.failures.append(CleanupFailure(item: item, message: error.localizedDescription))
            }
        }
        return report
    }

    /// Path-level checks (everything except "is it installed").
    func validateLocation(_ location: LeftoverLocation) throws {
        let url = location.url
        let folder = folder(for: location.kind)
        let name = url.lastPathComponent
        // `..` is resolved lexically by `normalizedPath` but through symlinks by the kernel, so it's never accepted.
        guard Self.isCandidate(location.bundleID),
              url.isFileURL,
              !url.pathComponents.contains(where: { $0 == ".." || $0 == "." }),
              url.deletingLastPathComponent().normalizedPath == folder.normalizedPath,
              let id = Self.bundleID(fromEntry: name, kind: location.kind),
              id.lowercased() == location.bundleID.lowercased(),
              !url.normalizedPath.hasPrefix("/System/")
        else {
            throw LeftoverError.notALeftover(url)
        }
        // A symlinked ~/Library or Library subfolder could redirect the removal elsewhere.
        for ancestor in [library, folder] where Self.isSymbolicLink(ancestor) {
            throw LeftoverError.notALeftover(url)
        }
        guard (try? FileManager.default.attributesOfItem(atPath: url.normalizedPath)) != nil else {
            throw LeftoverError.missing(url)
        }
        if Self.isSymbolicLink(url) { throw LeftoverError.symbolicLink(url) }
        if exclusions.excludes(url) { throw LeftoverError.excluded(url) }
    }

    // MARK: Names and IDs

    /// The bundle ID an entry in a Library folder belongs to, if it's a leftover candidate.
    public static func bundleID(fromEntry name: String, kind: LeftoverKind) -> String? {
        for suffix in kind.suffixes {
            let id: String
            if suffix.isEmpty {
                id = name
            } else if name.count > suffix.count, name.hasSuffix(suffix) {
                id = String(name.dropLast(suffix.count))
            } else {
                continue
            }
            if isCandidate(id) { return id }
        }
        return nil
    }

    /// Reverse-DNS: at least three non-empty components of ASCII letters, digits, `-` or `_`.
    public static func looksLikeBundleID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Prefixes of IDs that are never offered: Apple's, app groups, and caches shared by developer tools and SDKs
    /// rather than owned by one app.
    static let ignoredPrefixes = [
        "com.apple.", "group.", "systemgroup.",
        "org.swift.", "com.plausiblelabs.", "io.branch.", "org.sparkle-project.", "com.crashlytics.",
    ]

    /// A bundle ID that could be a leftover (before checking whether it's installed).
    public static func isCandidate(_ id: String) -> Bool {
        guard looksLikeBundleID(id) else { return false }
        let lower = id.lowercased()
        if ignoredPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        // Team-ID prefixed names (`ABCDE12345.com.vendor.shared`) are app groups shared between apps.
        if let first = id.split(separator: ".").first, first.count == 10,
           first.allSatisfy({ ($0.isASCII && $0.isUppercase) || $0.isNumber }) {
            return false
        }
        return true
    }

    /// The app's former name: from the (deleted) app LaunchServices remembers, else from the bundle ID.
    public static func guessName(for bundleID: String, appURL: URL? = nil) -> String {
        if let appURL {
            let name = appURL.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        let generic: Set<String> = ["app", "mac", "macos", "macosx", "osx", "client", "desktop", "application", "helper", "agent", "launcher"]
        var parts = bundleID.split(separator: ".").dropFirst().map(String.init)
        // Skip generic or version-like endings: `com.spotify.client` is Spotify, `com.unity3d.UnityEditor5.x` is UnityEditor5.
        while parts.count > 1, let last = parts.last, generic.contains(last.lowercased()) || last.count <= 2 {
            parts.removeLast()
        }
        let raw = (parts.last ?? bundleID).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard raw == raw.lowercased() else { return raw }
        return raw.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Installed apps

    /// Every bundle ID that counts as installed right now.
    public func installedIndex() -> InstalledBundleIndex {
        var index = InstalledBundleIndex(Self.bundleIDs(inRoots: appRoots))
        for id in Self.serviceIDs(in: serviceFolders) { index.insert(id) }
        for id in runningBundleIDs() { index.insert(id) }
        return index
    }

    static let bundleExtensions: Set<String> = [
        "app", "appex", "xpc", "framework", "bundle", "plugin", "systemextension", "prefpane", "saver",
        "qlgenerator", "mdimporter", "service", "driver", "kext",
    ]

    /// Places inside a bundle where apps keep helpers, extensions and frameworks with their own IDs.
    static let nestedFolders = [
        "Contents/Library/LoginItems", "Contents/Helpers", "Contents/XPCServices", "Contents/PlugIns",
        "Contents/Library/LaunchServices", "Contents/Frameworks", "Contents/Library/SystemExtensions",
        "Contents/Extensions", "Contents/Library/QuickLook", "Contents/Library/Spotlight",
        "Versions/Current/Helpers", "Versions/Current/XPCServices", "Versions/Current/Frameworks",
    ]

    /// IDs of all bundles in the roots (up to three folders deep) and of the bundles nested inside them.
    static func bundleIDs(inRoots roots: [URL]) -> Set<String> {
        var ids = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if bundleExtensions.contains(url.pathExtension.lowercased()) {
                    collectIDs(ofBundle: url, depth: 0, into: &ids)
                    enumerator.skipDescendants()
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        return ids
    }

    static func collectIDs(ofBundle bundle: URL, depth: Int, into ids: inout Set<String>) {
        if let id = bundleIdentifier(of: bundle) { ids.insert(id) }
        guard depth < 4 else { return }
        let fileManager = FileManager.default
        for relative in nestedFolders {
            let folder = bundle.appending(path: relative, directoryHint: .isDirectory)
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { continue }
            for name in names {
                let url = folder.appending(path: name)
                if bundleExtensions.contains(url.pathExtension.lowercased()) {
                    collectIDs(ofBundle: url, depth: depth + 1, into: &ids)
                } else if looksLikeBundleID(name) {
                    // Helper tools in Contents/Library/LaunchServices are named after their ID.
                    ids.insert(name)
                }
            }
        }
    }

    static func bundleIdentifier(of bundle: URL) -> String? {
        for relative in ["Contents/Info.plist", "Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Info.plist"] {
            let plist = bundle.appending(path: relative)
            guard let data = try? Data(contentsOf: plist),
                  let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            if let id = dictionary["CFBundleIdentifier"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Names, labels and associated bundle IDs of launchd jobs and privileged helpers.
    static func serviceIDs(in folders: [URL]) -> Set<String> {
        var ids = Set<String>()
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { continue }
            for name in names {
                let base = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
                if looksLikeBundleID(base) { ids.insert(base) }
                guard name.hasSuffix(".plist"),
                      let data = try? Data(contentsOf: folder.appending(path: name)),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                if let label = plist["Label"] as? String { ids.insert(label) }
                if let associated = plist["AssociatedBundleIdentifiers"] as? String { ids.insert(associated) }
                if let associated = plist["AssociatedBundleIdentifiers"] as? [String] { ids.formUnion(associated) }
            }
        }
        return ids
    }

    /// Bundle IDs of the bundles containing each running process (yours; others' aren't readable).
    public static func runningProcessBundleIDs() -> [String] {
        var bundles = Set<String>()
        for pid in MemoryMonitor.allPIDs() where pid > 0 {
            guard let path = MemoryMonitor.executablePath(of: pid) else { continue }
            var current = ""
            for component in path.split(separator: "/") {
                current += "/" + component
                if bundleExtensions.contains((String(component) as NSString).pathExtension.lowercased()) {
                    bundles.insert(current)
                }
            }
        }
        return bundles.compactMap { bundleIdentifier(of: URL(filePath: $0, directoryHint: .isDirectory)) }
    }

    /// Wraps the deprecated LaunchServices call. Its replacement is in AppKit, which ReclaimCore doesn't use.
    public static func launchServicesURLs(for bundleID: String) -> [URL] {
        let lookup: any LaunchServicesLookup.Type = LegacyLaunchServices.self
        return lookup.applicationURLs(for: bundleID)
    }

    /// Bundles Spotlight knows with this ID, anywhere on disk (finds apps outside the usual folders).
    public static func spotlightURLs(for bundleID: String) -> [URL] {
        // Only validated IDs go into the query, so there's nothing to escape.
        guard looksLikeBundleID(bundleID),
              let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemCFBundleIdentifier == \"\(bundleID)\"c" as CFString, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        else { return [] }
        var urls = [URL]()
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                urls.append(URL(filePath: path, directoryHint: .isDirectory))
            }
        }
        return urls
    }

    /// An app that still exists and isn't sitting in a Trash.
    static func isLiveApp(_ url: URL) -> Bool {
        let path = url.normalizedPath
        guard !path.contains("/.Trash/"), !path.contains("/.Trashes/") else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        // No trailing slash: `lstat("link/")` follows the link.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.normalizedPath)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}

private extension LeftoverLocation {
    var kindOrder: Int { LeftoverKind.allCases.firstIndex(of: kind) ?? 0 }
}

// Calling through a protocol keeps the deprecation warning of `LSCopyApplicationURLsForBundleIdentifier` contained here.
private protocol LaunchServicesLookup {
    static func applicationURLs(for bundleID: String) -> [URL]
}

private enum LegacyLaunchServices: LaunchServicesLookup {
    @available(macOS, deprecated: 12.0, message: "Wraps a deprecated LaunchServices call")
    static func applicationURLs(for bundleID: String) -> [URL] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() else { return [] }
        return (urls as? [URL]) ?? []
    }
}
