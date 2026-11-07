import AppKit
import Observation
import ReclaimCore
import SwiftUI

/// State for the Developer Projects screen, owned by `AppModel`.
@MainActor
@Observable
final class ProjectsModel {
    enum Filter: String, CaseIterable {
        case inactive = "Inactive"
        case all = "All Projects"

        var title: String {
            switch self {
            case .inactive: String(localized: "Inactive")
            case .all: String(localized: "All Projects")
            }
        }
    }

    private enum Keys {
        static let roots = "projectRoots"
        static let hiddenDefaults = "projectRootsHidden"
        static let inactiveDays = "projectsInactiveDays"
    }

    /// Found folders, in discovery order until the scan finishes (so rows don't jump), then by size.
    private(set) var items: [ProjectJunk] = []
    /// Folders ticked for cleanup.
    var checked: Set<URL> = []
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var hasScanned = false

    var filter = Filter.inactive
    var inactiveDays: Int {
        didSet {
            UserDefaults.standard.set(inactiveDays, forKey: Keys.inactiveDays)
            preselectInactive()
        }
    }

    var sortOrder: [KeyPathComparator<ProjectJunk>] = [] {
        didSet { items.sort(using: sortOrder) }
    }

    // MARK: Search folders

    private(set) var defaultRoots: [URL] = []
    private(set) var addedRoots: [URL]
    private var hiddenDefaults: Set<String>
    @ObservationIgnored private var didLoadDefaults = false

    /// The folders searched, in order: common code folders, then folders the user added.
    var roots: [URL] {
        var seen = Set<String>()
        return (defaultRoots.filter { !hiddenDefaults.contains($0.normalizedPath) } + addedRoots)
            .filter { seen.insert($0.normalizedPath).inserted }
    }

    var hasHiddenDefaults: Bool { defaultRoots.contains { hiddenDefaults.contains($0.normalizedPath) } }

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID = UUID()
    /// The folders the current results came from; removal is limited to these.
    @ObservationIgnored private var scannedRoots: [URL] = []

    init() {
        let defaults = UserDefaults.standard
        let days = defaults.integer(forKey: Keys.inactiveDays)
        inactiveDays = days > 0 ? days : 30
        addedRoots = (defaults.stringArray(forKey: Keys.roots) ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
        hiddenDefaults = Set(defaults.stringArray(forKey: Keys.hiddenDefaults) ?? [])
    }

    // MARK: Derived state

    var visibleItems: [ProjectJunk] {
        filter == .all ? items : items.filter { $0.isInactive(days: inactiveDays) }
    }

    /// Ticked and currently shown, so nothing hidden by the filter is ever removed.
    var chosenItems: [ProjectJunk] {
        visibleItems.filter { checked.contains($0.url) }
    }

    static func isAvailable(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Scanning

    /// Looks up the common code folders. Deferred until the screen is shown, since it reads the home folder.
    func prepare() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        defaultRoots = ProjectJunkFinder.commonRoots()
    }

    func scan() {
        prepare()
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        let roots = roots.filter(Self.isAvailable)
        scannedRoots = roots
        items = []
        checked = []
        sortOrder = []
        hasScanned = true
        isScanning = !roots.isEmpty
        guard !roots.isEmpty else { return }

        // The model lives as long as the app, so a strong capture is fine; stale results are dropped by `scanID`.
        scanTask = Task.detached(priority: .userInitiated) { [self] in
            let finder = ProjectJunkFinder(exclusions: .load())
            let (sizeQueue, sizeContinuation) = AsyncStream.makeStream(of: URL.self)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await junk in finder.results(in: roots) {
                        await self.didFind(junk, scan: id)
                        sizeContinuation.yield(junk.url)
                    }
                    sizeContinuation.finish()
                }
                group.addTask {
                    // A few folders at a time: big node_modules folders take a while, small ones shouldn't wait.
                    await withTaskGroup(of: (URL, Int64).self) { sizers in
                        var running = 0
                        for await url in sizeQueue {
                            if running >= 4, let measured = await sizers.next() {
                                await self.didMeasure(measured.0, size: measured.1, scan: id)
                                running -= 1
                            }
                            sizers.addTask { (url, DirectorySizer().size(of: url).bytes) }
                            running += 1
                        }
                        for await measured in sizers {
                            await self.didMeasure(measured.0, size: measured.1, scan: id)
                        }
                    }
                }
            }
            await self.didFinish(scan: id)
        }
    }

    private func didFind(_ junk: ProjectJunk, scan id: UUID) {
        guard id == scanID else { return }
        items.append(junk)
        if junk.isInactive(days: inactiveDays) { checked.insert(junk.url) }
    }

    private func didMeasure(_ url: URL, size: Int64, scan id: UUID) {
        guard id == scanID, let index = items.firstIndex(where: { $0.url == url }) else { return }
        items[index].size = size
    }

    private func didFinish(scan id: UUID) {
        guard id == scanID else { return }
        isScanning = false
        if sortOrder.isEmpty {
            sortOrder = [KeyPathComparator(\.sortSize, order: .reverse)]
        }
    }

    // MARK: Selection

    func preselectInactive() {
        checked = Set(items.filter { $0.isInactive(days: inactiveDays) }.map(\.url))
    }

    func setChecked(_ isChecked: Bool, _ urls: some Sequence<URL>) {
        if isChecked { checked.formUnion(urls) } else { checked.subtract(urls) }
    }

    func isChecked(_ item: ProjectJunk) -> Bool { checked.contains(item.url) }

    // MARK: Cleaning

    /// Validates and moves the folders to the Trash as one undoable batch.
    func trash(_ selection: [ProjectJunk], appModel: AppModel) async {
        guard !selection.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }

        let roots = scannedRoots
        let result = await Task.detached(priority: .userInitiated) {
            ProjectJunkCleaner(roots: roots).moveToTrash(selection)
        }.value

        appModel.recordTrash(title: result.undoTitle, records: result.trashed)
        appModel.didRemoveFiles()
        let removed = Set(result.removed.map(\.url))
        items.removeAll { removed.contains($0.url) }
        checked.subtract(removed)

        if !result.failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = result.failures.count == 1
                ? String(localized: "1 folder couldn't be moved to the Trash")
                : String(localized: "\(result.failures.count) folders couldn't be moved to the Trash")
            alert.informativeText = result.failures.prefix(5).map(\.message).joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Adds the projects to the shared exclusion list and drops their folders from the results.
    func neverClean(projects: Set<URL>) {
        var exclusions = Exclusions.load()
        projects.forEach { exclusions.add($0) }
        do {
            try exclusions.save()
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let removed = Set(items.filter { exclusions.excludes($0.url) }.map(\.url))
        items.removeAll { removed.contains($0.url) }
        checked.subtract(removed)
    }

    // MARK: Managing search folders

    func addRoot(_ url: URL) {
        let path = url.normalizedPath
        if hiddenDefaults.remove(path) == nil, !roots.contains(where: { $0.normalizedPath == path }) {
            addedRoots.append(URL(filePath: path, directoryHint: .isDirectory))
        }
        saveRoots()
        scan()
    }

    func removeRoot(_ url: URL) {
        let path = url.normalizedPath
        addedRoots.removeAll { $0.normalizedPath == path }
        if defaultRoots.contains(where: { $0.normalizedPath == path }) { hiddenDefaults.insert(path) }
        saveRoots()
        scan()
    }

    func restoreDefaultRoots() {
        hiddenDefaults.removeAll()
        saveRoots()
        scan()
    }

    private func saveRoots() {
        UserDefaults.standard.set(addedRoots.map(\.normalizedPath), forKey: Keys.roots)
        UserDefaults.standard.set(hiddenDefaults.sorted(), forKey: Keys.hiddenDefaults)
    }
}
