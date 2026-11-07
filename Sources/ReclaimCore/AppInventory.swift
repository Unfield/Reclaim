import CoreServices
import Foundation

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let size: Int64
    /// When the app was last opened, according to Spotlight.
    public let lastUsed: Date?
    /// When the app was added to this Mac, according to Spotlight.
    public let dateAdded: Date?

    public init(url: URL, name: String, bundleID: String?, version: String?, size: Int64, lastUsed: Date?, dateAdded: Date?) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.size = size
        self.lastUsed = lastUsed
        self.dateAdded = dateAdded
    }

    public var id: URL { url }

    /// Apps that ship with macOS. These are never offered for removal.
    public var isAppleApp: Bool { bundleID?.hasPrefix("com.apple.") ?? false }

    /// Most recent sign of use: when it was last opened, or when it was installed if never opened.
    public var lastActivity: Date? { lastUsed ?? dateAdded }

    public func isUnused(days: Int, now: Date = Date()) -> Bool {
        guard let activity = lastActivity else { return true }
        return activity < now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }
}

/// Finds installed apps, how big they are and when they were last used.
public struct AppInventory: Sendable {
    public let roots: [URL]
    public let home: URL

    public init(roots: [URL]? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.roots = roots ?? [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// All third-party apps, largest first.
    public func scan() async -> [InstalledApp] {
        let bundles = findBundles()
        return await withTaskGroup(of: InstalledApp?.self) { group in
            for url in bundles {
                group.addTask { Self.info(for: url) }
            }
            var apps = [InstalledApp]()
            for await app in group {
                if let app, !app.isAppleApp { apps.append(app) }
            }
            return apps.sorted { $0.size > $1.size }
        }
    }

    func findBundles() -> [URL] {
        var bundles = [URL]()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension == "app" {
                    bundles.append(url)
                    enumerator.skipDescendants()
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        return bundles
    }

    static func info(for url: URL) -> InstalledApp? {
        let plist = Bundle(url: url)?.infoDictionary
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        var lastUsed: Date?
        var dateAdded: Date?
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            dateAdded = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        }
        return InstalledApp(
            url: url,
            name: name,
            bundleID: plist?["CFBundleIdentifier"] as? String,
            version: plist?["CFBundleShortVersionString"] as? String,
            size: DirectorySizer().size(of: url).bytes,
            lastUsed: lastUsed,
            dateAdded: dateAdded
        )
    }

    // MARK: Leftovers

    /// Places in ~/Library where an app commonly keeps its data, matched by exact bundle ID or app name.
    func leftoverCandidates(for app: InstalledApp) -> [URL] {
        guard !app.isAppleApp else { return [] }
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        var relative = [String]()

        if let id = app.bundleID, id.contains(".") {
            relative += [
                "Application Support/\(id)",
                "Application Scripts/\(id)",
                "Caches/\(id)",
                "Containers/\(id)",
                "Cookies/\(id).binarycookies",
                "HTTPStorages/\(id)",
                "HTTPStorages/\(id).binarycookies",
                "Logs/\(id)",
                "Preferences/\(id).plist",
                "Saved Application State/\(id).savedState",
                "WebKit/\(id)",
            ]
        }
        // Name-based matches are only used for reasonably distinctive names.
        if app.name.count >= 4, !app.name.contains("/") {
            relative += ["Application Support/\(app.name)", "Caches/\(app.name)", "Logs/\(app.name)"]
        }
        return relative.map { library.appending(path: $0) }
    }

    /// Existing support files for an app, largest first. May trigger a privacy prompt for sandboxed apps' containers.
    public func leftovers(for app: InstalledApp) -> [CleanupItem] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        return leftoverCandidates(for: app)
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) && seen.insert($0.normalizedPath).inserted }
            .map { url in
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return CleanupItem(url: url, size: DirectorySizer().size(of: url).bytes, modified: modified)
            }
            .sorted { $0.size > $1.size }
    }
}

public enum UninstallError: Error, LocalizedError, Sendable {
    case notAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let reason): reason
        }
    }
}

/// Moves apps (and optionally their support files) to the Trash.
public struct AppUninstaller: Sendable {
    public let inventory: AppInventory

    public init(inventory: AppInventory = AppInventory()) {
        self.inventory = inventory
    }

    public func validate(_ app: InstalledApp) throws {
        guard app.url.pathExtension == "app" else {
            throw UninstallError.notAllowed("\(app.name) isn't an app bundle.")
        }
        guard !app.isAppleApp else {
            throw UninstallError.notAllowed("\(app.name) is part of macOS and can't be removed.")
        }
        let path = app.url.normalizedPath
        guard inventory.roots.contains(where: { path.hasPrefix($0.normalizedPath + "/") }) else {
            throw UninstallError.notAllowed("\(app.name) isn't in an Applications folder.")
        }
    }

    public func uninstall(_ app: InstalledApp, leftovers: [CleanupItem], method: CleanupMethod) -> CleanupReport {
        var report = CleanupReport(dryRun: false)
        let appItem = CleanupItem(url: app.url, size: app.size, modified: app.lastUsed)

        do {
            try validate(app)
            if let record = try remove(app.url, size: app.size, method: method) { report.trashed.append(record) }
            report.removed.append(appItem)
        } catch {
            report.failures.append(CleanupFailure(item: appItem, message: error.localizedDescription))
            return report
        }

        let leftoverReport = removeLeftovers(leftovers, of: app, method: method)
        report.removed += leftoverReport.removed
        report.failures += leftoverReport.failures
        report.trashed += leftoverReport.trashed
        return report
    }

    /// Removes support files. Each must be one of the known leftover locations for the app.
    public func removeLeftovers(_ leftovers: [CleanupItem], of app: InstalledApp, method: CleanupMethod) -> CleanupReport {
        var report = CleanupReport(dryRun: false)
        let allowed = Set(inventory.leftoverCandidates(for: app).map(\.normalizedPath))
        for item in leftovers {
            do {
                guard allowed.contains(item.url.normalizedPath) else {
                    throw UninstallError.notAllowed("\(item.url.abbreviatedPath) isn't a recognized support file for \(app.name).")
                }
                if let record = try remove(item.url, size: item.size, method: method) { report.trashed.append(record) }
                report.removed.append(item)
            } catch {
                report.failures.append(CleanupFailure(item: item, message: error.localizedDescription))
            }
        }
        return report
    }

    /// For apps owned by another user (often root), moves the app to the Trash after asking for an administrator password.
    public func moveToTrashAsAdministrator(_ app: InstalledApp) async throws {
        try validate(app)
        let trash = inventory.home.appending(path: ".Trash", directoryHint: .isDirectory)
        var destination = trash.appending(path: app.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            let stamp = Int(Date().timeIntervalSince1970)
            destination = trash.appending(path: "\(app.name) \(stamp).app")
        }
        let result = try await Shell.runAsAdministrator(
            "/bin/mv",
            [app.url.path(percentEncoded: false), destination.path(percentEncoded: false)],
            prompt: "Reclaim needs your password to move \(app.name) to the Trash."
        )
        guard result.succeeded else { throw ShellError.failed(command: "mv", message: result.failureMessage) }
    }

    /// Returns a Trash record when the item was moved to the Trash (so it can be put back).
    private func remove(_ url: URL, size: Int64, method: CleanupMethod) throws -> TrashRecord? {
        switch method {
        case .moveToTrash:
            return try Trash.move(url, size: size)
        case .deletePermanently:
            try FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
