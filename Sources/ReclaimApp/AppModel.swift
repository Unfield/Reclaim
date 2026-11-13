import AppKit
import Observation
import ReclaimCore

enum SidebarItem: Hashable {
    case overview
    case category(String)
    case tool(String)
    case apps
    case explorer
    case largeFiles
    case memory
    case projects
    case orphans
    case duplicates
    case aiModels
    case icloud
    case activity
    case loginItems
    case history
    case recentlyRemoved
}

struct ToolState {
    var status: ToolStatus?
    var isLoading = false
    var isCleaning = false
    var options: Set<String>
    var error: String?
}

struct CleanupSummary: Identifiable {
    let id = UUID()
    var freed: Int64 = 0
    var trashed: Int64 = 0
    var failures: [String] = []
    /// The undo batch for items moved to the Trash, if any.
    var undoBatchID: UUID?

    var total: Int64 { freed + trashed }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var selection: SidebarItem? = .overview

    // MARK: Feature screens (each owns its state; see Features/)
    let projects = ProjectsModel()
    let orphans = OrphansModel()
    let duplicates = DuplicatesModel()
    let aiModels = AIModelsModel()
    let icloud = ICloudModel()
    let activity = ActivityModel()
    let loginItems = LoginItemsModel()
    let history = HistoryModel()

    // MARK: Disks
    var volumes: [VolumeInfo] = []
    /// The startup disk.
    var volume: VolumeInfo? { volumes.first(where: \.isStartup) }
    var otherVolumes: [VolumeInfo] { volumes.filter { !$0.isStartup } }

    var lowSpaceThreshold: Int64 { Int64(Prefs.int(Prefs.lowSpaceThresholdGB)) * 1_000_000_000 }
    var isLowOnSpace: Bool {
        guard let volume else { return false }
        return volume.availableForImportantUsage < lowSpaceThreshold
    }

    // MARK: Categories
    var scans: [CategoryScan] = []
    var isScanning = false
    var lastScanDate: Date?
    private(set) var selectedItems: [String: Set<URL>] = [:]

    // MARK: Tools
    let tools: [any MaintenanceTool] = ToolCatalog.all()
    var toolStates: [String: ToolState] = [:]
    var selectedTools: Set<String> = []
    @ObservationIgnored private var toolDefaultsApplied: Set<String> = []

    // MARK: Cleaning
    var isCleaning = false
    var lastReport: CleanupSummary?
    var cleanupMethod: CleanupMethod = .moveToTrash {
        didSet { UserDefaults.standard.set(cleanupMethod.rawValue, forKey: Prefs.cleanupMethod) }
    }

    // MARK: Apps
    var apps: [InstalledApp] = []
    var isLoadingApps = false
    var appsLoaded = false

    // MARK: Explorer
    var explorerFolder = FileManager.default.homeDirectoryForCurrentUser
    var explorerEntries: [FolderEntry] = []
    var explorerError: String?
    @ObservationIgnored private var explorerTask: Task<Void, Never>?
    @ObservationIgnored private var explorerCache: [URL: [FolderEntry]] = [:]

    // MARK: Memory
    var memory: MemoryStats?
    var memoryGroups: [ProcessGroup] = []
    var isPurging = false
    var purgeMessage: String?

    // MARK: Large files
    var largeFilesRoot = FileManager.default.homeDirectoryForCurrentUser
    var largeFilesMinimum: Int64 = 500_000_000
    var largeFiles: [CleanupItem] = []
    var isSearchingLargeFiles = false

    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var mountObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lowSpaceNotified = false
    @ObservationIgnored private var started = false

    private init() {
        for tool in tools {
            toolStates[tool.id] = ToolState(options: tool.defaultOptions)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Prefs.register()
        cleanupMethod = CleanupMethod(rawValue: UserDefaults.standard.string(forKey: Prefs.cleanupMethod) ?? "") ?? .moveToTrash
        // `open Reclaim.app --args -ReclaimScreen memory` opens a specific screen (handy for screenshots).
        if let screen = UserDefaults.standard.string(forKey: "ReclaimScreen") {
            selection = Self.screens[screen] ?? selection
        }

        refreshTrashHistory()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateVolume()
                if let self { await self.history.tick(appModel: self) }
                try? await Task.sleep(for: .seconds(300))
            }
        }
        observeMounts()
        if Prefs.bool(Prefs.scanOnLaunch) {
            Task { await refresh() }
        }
    }

    /// Refreshes usage for all mounted disks.
    private static let screens: [String: SidebarItem] = [
        "overview": .overview, "apps": .apps, "explorer": .explorer, "large": .largeFiles, "memory": .memory,
        "projects": .projects, "leftovers": .orphans, "duplicates": .duplicates, "models": .aiModels,
        "icloud": .icloud, "cpu": .activity, "login": .loginItems, "history": .history, "removed": .recentlyRemoved,
    ]

    func updateVolume() {
        volumes = VolumeInfo.mounted()
        history.record(volumes)
        checkLowSpace()
    }

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification,
        ]
        mountObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.disksChanged() }
            }
        }
    }

    private func disksChanged() {
        updateVolume()
        // Add or drop the per-disk Trash categories.
        if lastScanDate != nil { Task { await scanCategories() } }
        if case .category(let id) = selection, scan(for: id) == nil { selection = .overview }
    }

    func eject(_ volume: VolumeInfo) {
        let url = volume.url
        Task {
            let error: String? = await Task.detached {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let error {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn't eject \(volume.name)")
                alert.informativeText = error
                alert.runModal()
            }
            disksChanged()
        }
    }

    private func checkLowSpace() {
        guard let volume else { return }
        if isLowOnSpace {
            guard !lowSpaceNotified, Prefs.bool(Prefs.lowSpaceNotifications) else { return }
            lowSpaceNotified = true
            let body = String(localized: "Only \(ByteSize.format(volume.availableForImportantUsage)) is available on \(volume.name). Open Reclaim to free up space.")
            Task { await Notifier.post(title: String(localized: "Your disk is almost full"), body: body) }
        } else {
            lowSpaceNotified = false
        }
    }

    // MARK: - Scanning

    /// Rescans everything: disk usage, cleanup categories and tools (and apps, if they've been loaded).
    func refresh() async {
        updateVolume()
        async let categories: Void = scanCategories()
        async let tools: Void = refreshTools()
        _ = await (categories, tools)
        if appsLoaded { await loadApps() }
    }

    func scanCategories() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let catalog = CategoryCatalog.all(oldDownloadsDays: max(1, Prefs.int(Prefs.oldDownloadsDays)))
            + CategoryCatalog.volumeCategories(for: volumes)
        let order = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ($1.id, $0) })

        // Results are applied one category at a time. Reading a protected folder (e.g. Downloads)
        // can block on a macOS privacy prompt, and that shouldn't hold up everything else.
        await withTaskGroup(of: CategoryScan.self) { group in
            for category in catalog {
                group.addTask { await Self.scanInBackground(category) }
            }
            for await result in group {
                apply(result, order: order)
            }
        }
        lastScanDate = Date()
    }

    /// `nonisolated async` so the (blocking) file system walk runs off the main actor.
    nonisolated private static func scanInBackground(_ category: CleanupCategory) async -> CategoryScan {
        Scanner().scan(category)
    }

    private func apply(_ result: CategoryScan, order: [String: Int]) {
        // Drop categories that weren't in this catalog (e.g. an ejected disk's Trash).
        var updated = scans.filter { order[$0.id] != nil && $0.id != result.id }
        if result.isPresent { updated.append(result) }
        updated.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        scans = updated

        // Default selection: everything in Safe categories, nothing elsewhere.
        selectedItems[result.id] = result.category.safety == .safe ? Set(result.items.map(\.url)) : []
    }

    func scan(for id: String) -> CategoryScan? { scans.first { $0.id == id } }

    var categoriesTotal: Int64 { scans.reduce(0) { $0 + $1.totalSize } }

    var totalReclaimable: Int64 {
        categoriesTotal + tools.reduce(0) { $0 + (toolReclaimable($1.id) ?? 0) }
    }

    var safeReclaimable: Int64 {
        scans.filter { $0.category.safety == .safe }.reduce(0) { $0 + $1.totalSize }
            + tools.filter { $0.safety == .safe }.reduce(0) { $0 + (toolReclaimable($1.id) ?? 0) }
    }

    var inaccessibleCount: Int { scans.reduce(0) { $0 + $1.inaccessibleCount } }

    // MARK: - Category selection

    func isSelected(_ item: CleanupItem, in scan: CategoryScan) -> Bool {
        selectedItems[scan.id, default: []].contains(item.url)
    }

    func setSelected(_ selected: Bool, item: CleanupItem, in scan: CategoryScan) {
        if selected {
            selectedItems[scan.id, default: []].insert(item.url)
        } else {
            selectedItems[scan.id, default: []].remove(item.url)
        }
    }

    func selectAll(_ selected: Bool, in scan: CategoryScan) {
        selectedItems[scan.id] = selected ? Set(scan.items.map(\.url)) : []
    }

    func selectedItems(in scan: CategoryScan) -> [CleanupItem] {
        let urls = selectedItems[scan.id, default: []]
        return scan.items.filter { urls.contains($0.url) }
    }

    func selectedSize(in scan: CategoryScan) -> Int64 {
        selectedItems(in: scan).reduce(0) { $0 + $1.size }
    }

    var totalSelectedSize: Int64 {
        scans.reduce(0) { $0 + selectedSize(in: $1) }
            + selectedTools.reduce(0) { $0 + (toolReclaimable($1) ?? 0) }
    }

    var hasSelection: Bool {
        scans.contains { !selectedItems(in: $0).isEmpty } || !selectedTools.isEmpty
    }

    // MARK: - Tools

    func tool(_ id: String) -> (any MaintenanceTool)? { tools.first { $0.id == id } }

    func toolState(_ id: String) -> ToolState {
        toolStates[id] ?? ToolState(options: [])
    }

    /// Tools that are installed (or still being checked).
    var visibleTools: [any MaintenanceTool] {
        tools.filter { toolStates[$0.id]?.status?.availability != .notInstalled }
    }

    func toolReclaimable(_ id: String) -> Int64? {
        let state = toolState(id)
        guard let status = state.status, status.isReady else { return nil }
        return status.reclaimable(options: state.options)
    }

    func setOption(_ optionID: String, enabled: Bool, toolID: String) {
        if enabled {
            toolStates[toolID]?.options.insert(optionID)
        } else {
            toolStates[toolID]?.options.remove(optionID)
        }
    }

    func setToolSelected(_ selected: Bool, toolID: String) {
        if selected { selectedTools.insert(toolID) } else { selectedTools.remove(toolID) }
    }

    func refreshTools() async {
        await withTaskGroup(of: Void.self) { group in
            for tool in tools {
                group.addTask { await self.refreshTool(tool.id) }
            }
        }
    }

    func refreshTool(_ id: String) async {
        guard let tool = tool(id), toolStates[id]?.isLoading != true else { return }
        toolStates[id]?.isLoading = true
        let status = await tool.status()
        toolStates[id]?.status = status
        toolStates[id]?.isLoading = false

        if !status.isReady { selectedTools.remove(id) }
        if status.isReady && !toolDefaultsApplied.contains(id) {
            toolDefaultsApplied.insert(id)
            if tool.safety == .safe, (toolReclaimable(id) ?? 0) > 0 { selectedTools.insert(id) }
        }
    }

    func deleteSnapshot(named name: String) async {
        guard let snapshot = TimeMachineTool.parseSnapshots(name).first else { return }
        toolStates["time-machine"]?.isCleaning = true
        do {
            _ = try await TimeMachineTool().delete(snapshot, allowAdministrator: true)
        } catch {
            toolStates["time-machine"]?.error = error.localizedDescription
        }
        toolStates["time-machine"]?.isCleaning = false
        updateVolume()
        await refreshTool("time-machine")
    }

    // MARK: - Cleaning

    /// Cleans everything currently selected in the overview.
    func cleanSelected() async {
        let categories = scans.map { ($0.category, selectedItems(in: $0)) }
        await clean(categories: categories, toolIDs: Array(selectedTools))
    }

    func cleanCategory(_ id: String) async {
        guard let scan = scan(for: id) else { return }
        await clean(categories: [(scan.category, selectedItems(in: scan))], toolIDs: [])
    }

    func cleanTool(_ id: String) async {
        await clean(categories: [], toolIDs: [id])
    }

    /// Cleans every Safe category and Safe tool, ignoring the current selection (used by the menu bar).
    /// - Parameters:
    ///   - includingTrash: Whether to empty the Trash (permanent). Unattended runs pass `false`.
    ///   - showReport: Whether to show the result alert.
    @discardableResult
    func cleanAllSafe(includingTrash: Bool = true, showReport: Bool = true) async -> CleanupSummary? {
        let categories = scans
            .filter { $0.category.safety == .safe }
            .filter { includingTrash || !$0.category.deletesPermanently }
            .map { ($0.category, $0.items) }
        let toolIDs = tools.filter { $0.safety == .safe && toolState($0.id).status?.isReady == true }.map(\.id)
        return await clean(categories: categories, toolIDs: toolIDs, showReport: showReport)
    }

    /// Empties the Trash on every disk.
    func emptyTrash() async {
        let trashes = scans.filter { $0.id == "trash" || $0.category.group == .otherDisks }
        await clean(categories: trashes.map { ($0.category, $0.items) }, toolIDs: [])
    }

    @discardableResult
    private func clean(categories: [(CleanupCategory, [CleanupItem])], toolIDs: [String], showReport: Bool = true) async -> CleanupSummary? {
        let categories = categories.filter { !$0.1.isEmpty }
        guard !categories.isEmpty || !toolIDs.isEmpty, !isCleaning else { return nil }
        isCleaning = true
        defer { isCleaning = false }

        var summary = CleanupSummary()
        let method = cleanupMethod

        let reports = await Task.detached(priority: .userInitiated) {
            let cleaner = Cleaner()
            return categories.map { category, items in
                (category, cleaner.clean(items, in: category, method: method))
            }
        }.value
        var trashed = [TrashRecord]()
        for (category, report) in reports {
            if category.deletesPermanently || method == .deletePermanently {
                summary.freed += report.bytesFreed
            } else {
                summary.trashed += report.bytesFreed
            }
            summary.failures += report.failures.map { String(localized: "\($0.item.name): \($0.message)") }
            trashed += report.trashed
        }
        if !trashed.isEmpty {
            let names = categories.map(\.0.name)
            let title = names.count == 1 ? names[0] : String(localized: "Cleanup of \(names.count) categories")
            summary.undoBatchID = recordTrash(title: title, records: trashed)
        }

        for id in toolIDs {
            guard let tool = tool(id) else { continue }
            let estimate = toolReclaimable(id)
            toolStates[id]?.isCleaning = true
            do {
                let result = try await tool.clean(options: toolState(id).options, allowAdministrator: true)
                summary.freed += result.freed ?? estimate ?? 0
                toolStates[id]?.error = nil
            } catch {
                summary.failures.append(String(localized: "\(tool.name): \(error.localizedDescription)"))
                toolStates[id]?.error = error.localizedDescription
            }
            toolStates[id]?.isCleaning = false
        }

        if showReport { lastReport = summary }
        updateVolume()
        if !categories.isEmpty { await scanCategories() }
        for id in toolIDs { await refreshTool(id) }
        return summary
    }

    // MARK: - Apps

    func loadApps() async {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        apps = await AppInventory().scan()
        appsLoaded = true
        isLoadingApps = false
    }

    /// Set when an app is dropped on Reclaim (window or Dock icon); the Applications screen shows the uninstall sheet.
    var uninstallRequest: InstalledApp?

    func requestUninstall(_ url: URL) {
        guard let app = AppInventory.info(for: url.standardizedFileURL) else { return }
        do {
            try AppUninstaller().validate(app)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Can't uninstall \(app.name)")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        selection = .apps
        uninstallRequest = app
    }

    func unusedApps(days: Int) -> [InstalledApp] {
        apps.filter { $0.isUnused(days: days) }
    }

    func leftovers(for app: InstalledApp) async -> [CleanupItem] {
        await Task.detached(priority: .userInitiated) {
            AppInventory().leftovers(for: app)
        }.value
    }

    static func isRunning(_ app: InstalledApp) -> Bool {
        guard let id = app.bundleID else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
    }

    static func quit(_ app: InstalledApp) {
        guard let id = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    /// Returns a report; if the app itself couldn't be moved, the caller can offer `uninstallAsAdministrator`.
    func uninstall(_ app: InstalledApp, leftovers: [CleanupItem]) async -> CleanupReport {
        let method = cleanupMethod
        let report = await Task.detached(priority: .userInitiated) {
            AppUninstaller().uninstall(app, leftovers: leftovers, method: method)
        }.value
        if report.removed.contains(where: { $0.url == app.url }) {
            apps.removeAll { $0.url == app.url }
        }
        recordTrash(title: String(localized: "Uninstalled \(app.name)"), records: report.trashed)
        updateVolume()
        return report
    }

    func uninstallAsAdministrator(_ app: InstalledApp, leftovers: [CleanupItem]) async throws -> CleanupReport {
        let uninstaller = AppUninstaller()
        try await uninstaller.moveToTrashAsAdministrator(app)
        apps.removeAll { $0.url == app.url }
        let method = cleanupMethod
        var report = await Task.detached(priority: .userInitiated) {
            uninstaller.removeLeftovers(leftovers, of: app, method: method)
        }.value
        report.removed.insert(CleanupItem(url: app.url, size: app.size, modified: app.lastUsed), at: 0)
        // The app itself was moved as root, so only its support files can be put back automatically.
        recordTrash(title: String(localized: "Support files of \(app.name)"), records: report.trashed)
        updateVolume()
        return report
    }

    // MARK: - Removing Xcode completely

    struct XcodeRemovalInfo {
        /// Simulator runtimes that can be deleted along with Xcode. Empty while another copy of Xcode is installed.
        var runtimes: [XcodeSimulatorsTool.Runtime]
        var otherInstallations: [URL]
        /// Whether `xcode-select` points into this Xcode, so it needs resetting afterwards.
        var isActiveDeveloperDirectory: Bool
    }

    struct XcodeRemovalNote: Identifiable {
        let id = UUID()
        let text: String
        let isFailure: Bool
    }

    /// What else goes when this copy of Xcode is removed. Must be called while it's still installed.
    func xcodeRemovalInfo(for app: InstalledApp) async -> XcodeRemovalInfo {
        let others = await Task.detached(priority: .userInitiated) {
            AppInventory().otherXcodeInstallations(than: app)
        }.value
        let uninstaller = XcodeUninstaller()
        // Runtimes are shared by every copy of Xcode.
        let runtimes = others.isEmpty ? await uninstaller.runtimes(for: app.url) : []
        let isActive = await uninstaller.isActiveDeveloperDirectory(app.url)
        return XcodeRemovalInfo(runtimes: runtimes, otherInstallations: others, isActiveDeveloperDirectory: isActive)
    }

    /// The steps that need Xcode's own `simctl`, so they run before the app is removed:
    /// quits the Simulator, shuts down simulators and deletes the chosen runtimes.
    func prepareXcodeRemoval(_ app: InstalledApp, deleting runtimes: [XcodeSimulatorsTool.Runtime]) async -> [XcodeRemovalNote] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").forEach { $0.terminate() }
        let uninstaller = XcodeUninstaller()
        await uninstaller.shutdownSimulators(using: app.url)
        guard !runtimes.isEmpty else { return [] }

        let (freed, failures) = await uninstaller.deleteRuntimes(runtimes, using: app.url)
        var notes = [XcodeRemovalNote]()
        if failures.count < runtimes.count {
            let text = freed > 0
                ? String(localized: "Deleted simulator runtimes (\(ByteSize.format(freed))).")
                : String(localized: "Deleted simulator runtimes.")
            notes.append(XcodeRemovalNote(text: text, isFailure: false))
        }
        notes += failures.map { XcodeRemovalNote(text: String(localized: "Couldn't delete simulator runtime \($0)"), isFailure: true) }
        updateVolume()
        return notes
    }

    /// Call once Xcode is gone. Resets `xcode-select` if it pointed into the removed Xcode (asks for a password).
    func finishXcodeRemoval(resetDeveloperDirectory: Bool) async -> [XcodeRemovalNote] {
        var notes = [XcodeRemovalNote]()
        if resetDeveloperDirectory {
            do {
                try await XcodeUninstaller().resetDeveloperDirectory()
                notes.append(XcodeRemovalNote(text: String(localized: "Reset the active developer directory, so command line tools keep working."), isFailure: false))
            } catch {
                notes.append(XcodeRemovalNote(
                    text: String(localized: "Couldn't reset the active developer directory. Run `sudo xcode-select --reset` in Terminal so command line tools keep working."),
                    isFailure: true
                ))
            }
        }
        await refreshTool("xcode-simulators")
        return notes
    }

    // MARK: - Undo

    /// Batches of items Reclaim moved to the Trash that can still be put back.
    var trashHistory: [TrashBatch] = []

    /// Records an undoable batch. Feature screens that move files to the Trash should go through this.
    @discardableResult
    func recordTrash(title: String, records: [TrashRecord]) -> UUID? {
        guard !records.isEmpty else { return nil }
        TrashLedger.shared.record(title: title, records: records)
        refreshTrashHistory()
        return trashHistory.first?.id
    }

    /// Moves one item to the Trash as its own undoable batch.
    func moveToTrash(_ url: URL, size: Int64, title: String? = nil) throws {
        let record = try Trash.move(url, size: size)
        recordTrash(title: title ?? String(localized: "Moved \(url.lastPathComponent) to the Trash"), records: [record])
        didRemoveFiles()
    }

    func refreshTrashHistory() {
        trashHistory = TrashLedger.shared.batches()
    }

    /// Puts a batch back where it came from, then rescans.
    func putBack(_ batchID: UUID) async {
        let result = await Task.detached(priority: .userInitiated) {
            TrashLedger.shared.putBack(batchID)
        }.value
        refreshTrashHistory()
        if !result.failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(result.failures.count) items couldn't be put back")
            alert.informativeText = result.failures.prefix(5).map { String(localized: "\($0.record.name): \($0.message)") }.joined(separator: "\n")
            alert.runModal()
        }
        updateVolume()
        if lastScanDate != nil { await scanCategories() }
        if appsLoaded { await loadApps() }
        if orphans.hasScanned { await orphans.scan() }
    }

    /// Call after removing files outside the normal cleanup flow, so disk usage stays current.
    func didRemoveFiles() {
        updateVolume()
        refreshTrashHistory()
    }

    // MARK: - Explorer

    var explorerTotal: Int64 { explorerEntries.reduce(0) { $0 + ($1.size ?? 0) } }
    var isExploring: Bool { explorerEntries.contains { $0.size == nil } }

    func explore(_ folder: URL, useCache: Bool = true) {
        explorerTask?.cancel()
        explorerFolder = folder
        explorerError = nil

        if useCache, let cached = explorerCache[folder] {
            explorerEntries = cached
            return
        }

        let entries: [FolderEntry]
        do {
            entries = try FolderExplorer.list(folder)
        } catch {
            explorerEntries = []
            explorerError = error.localizedDescription
            return
        }
        explorerEntries = entries

        explorerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: FolderEntry.self) { group in
                for entry in entries {
                    group.addTask { FolderExplorer.measure(entry) }
                }
                for await measured in group {
                    await self?.applyMeasurement(measured, in: folder)
                }
            }
            await self?.finishExploring(folder)
        }
    }

    private func applyMeasurement(_ entry: FolderEntry, in folder: URL) {
        guard folder == explorerFolder, let index = explorerEntries.firstIndex(where: { $0.url == entry.url }) else { return }
        explorerEntries[index] = entry
    }

    private func finishExploring(_ folder: URL) {
        guard folder == explorerFolder, !Task.isCancelled, !isExploring else { return }
        explorerEntries.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        explorerCache[folder] = explorerEntries
    }

    func trashExplorerEntry(_ entry: FolderEntry) {
        do {
            try moveToTrash(entry.url, size: entry.size ?? 0)
            explorerEntries.removeAll { $0.url == entry.url }
            // Sizes of this folder and its ancestors are now stale.
            explorerCache = explorerCache.filter { !explorerFolder.normalizedPath.hasPrefix($0.key.normalizedPath) }
            updateVolume()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func chooseExplorerFolder() {
        if let url = Self.chooseFolder(startingAt: explorerFolder) { explore(url) }
    }

    // MARK: - Memory

    /// Cheap; safe to call every couple of seconds.
    func refreshMemoryStats() {
        memory = MemoryMonitor.stats()
    }

    func refreshMemory() async {
        let (stats, groups) = await Task.detached(priority: .utility) {
            (MemoryMonitor.stats(), MemoryMonitor.processGroups())
        }.value
        memory = stats
        memoryGroups = merge(groups)
    }

    /// Keeps the previous row order unless it's clearly wrong, so the list doesn't reshuffle on every refresh.
    private func merge(_ fresh: [ProcessGroup]) -> [ProcessGroup] {
        guard !memoryGroups.isEmpty else { return fresh }
        let byID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        var merged = memoryGroups.compactMap { byID[$0.id] }
        let known = Set(merged.map(\.id))
        merged += fresh.filter { !known.contains($0.id) }

        let outOfOrder = zip(merged, merged.dropFirst()).contains { above, below in
            below.memory - above.memory > 50_000_000 && Double(below.memory) > Double(above.memory) * 1.25
        }
        if outOfOrder { merged.sort { $0.memory > $1.memory } }
        return merged
    }

    func runningApp(for group: ProcessGroup) -> NSRunningApplication? {
        guard let bundle = group.bundleURL?.standardizedFileURL else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == bundle && !$0.isTerminated
        }
    }

    /// Regular apps can always be quit (like ⌘Q); other processes only if they aren't part of macOS.
    func canQuit(_ group: ProcessGroup) -> Bool {
        if group.pids.contains(getpid()) { return false }
        if let app = runningApp(for: group) { return app.activationPolicy == .regular || !group.isSystem }
        return !group.isSystem
    }

    func quit(_ group: ProcessGroup, force: Bool) {
        if let app = runningApp(for: group) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            do {
                try MemoryMonitor.terminate(group)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await refreshMemory()
        }
    }

    func purgeMemory() async {
        guard !isPurging else { return }
        isPurging = true
        defer { isPurging = false }
        do {
            let freed = try await MemoryMonitor.purge(allowAdministrator: true)
            purgeMessage = String(localized: "Cleared memory caches. \(ByteSize.formatMemory(freed)) more is available right now.")
        } catch {
            purgeMessage = error.localizedDescription
        }
        await refreshMemory()
    }

    // MARK: - Large files

    func findLargeFiles() async {
        isSearchingLargeFiles = true
        let root = largeFilesRoot
        let options = LargeFileFinder.Options(minimumSize: largeFilesMinimum, limit: 200)
        largeFiles = await Task.detached(priority: .userInitiated) {
            LargeFileFinder().find(in: root, options: options)
        }.value
        isSearchingLargeFiles = false
    }

    func trashLargeFile(_ item: CleanupItem) {
        do {
            try moveToTrash(item.url, size: item.size)
            largeFiles.removeAll { $0.url == item.url }
            updateVolume()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func chooseLargeFilesRoot() {
        if let url = Self.chooseFolder(startingAt: largeFilesRoot) {
            largeFilesRoot = url
            largeFiles = []
        }
    }

    // MARK: - Helpers

    static func chooseFolder(startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = url
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
