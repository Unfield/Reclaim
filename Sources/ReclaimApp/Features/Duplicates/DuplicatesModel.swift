import AppKit
import Observation
import ReclaimCore

/// State for the Duplicates screen, owned by `AppModel`.
@MainActor
@Observable
final class DuplicatesModel {
    static let rootsKey = "duplicateRoots"
    static let sizeOptions: [Int64] = [100_000, 1_000_000, 10_000_000, 100_000_000]

    /// Folders to search. Persisted; missing ones (e.g. an unplugged disk) stay listed but are skipped.
    var roots: [URL] {
        didSet {
            UserDefaults.standard.set(roots.map(\.normalizedPath), forKey: Self.rootsKey)
            resetResults()
        }
    }

    var minimumSize: Int64 = 1_000_000 {
        didSet { if minimumSize != oldValue { resetResults() } }
    }

    var keepRule = DuplicateKeepRule.oldest {
        didSet { if keepRule != oldValue { selection.apply(keepRule, to: groups) } }
    }

    private(set) var groups: [DuplicateGroup] = []
    private(set) var selection = DuplicateSelection()
    private(set) var hasScanned = false
    private(set) var isScanning = false
    private(set) var isTrashing = false
    private(set) var progress = DuplicateScanProgress()
    private(set) var unreadableCount = 0
    /// Shown after a removal that skipped files.
    var removalProblem: String?

    @ObservationIgnored private var worker: Task<DuplicateScanResult, Error>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID = UUID()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.rootsKey) {
            roots = saved.map { URL(filePath: $0, directoryHint: .isDirectory) }
        } else {
            roots = DuplicateFinder.defaultRoots()
        }
    }

    // MARK: Folders

    func isAvailable(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !DuplicateFinder.isProtected(root)
    }

    var canScan: Bool { roots.contains(where: isAvailable) }

    func addRoot(_ url: URL) {
        guard !roots.contains(where: { $0.normalizedPath == url.normalizedPath }) else { return }
        roots.append(url)
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0.normalizedPath == url.normalizedPath }
    }

    // MARK: Scanning

    var wastedSpace: Int64 { groups.reduce(0) { $0 + $1.wastedSpace } }
    var selectedCount: Int { selection.count(in: groups) }
    /// What removing the selection frees, accounting for APFS clones.
    var selectedSavings: Int64 { selection.estimatedSavings(in: groups) }

    func scan() {
        cancel()
        let id = UUID()
        scanID = id
        let roots = roots.filter(isAvailable)
        let finder = DuplicateFinder(options: .init(minimumSize: minimumSize))
        groups = []
        selection = DuplicateSelection()
        hasScanned = false
        progress = DuplicateScanProgress()
        isScanning = true

        // The finder already throttles progress; keeping only the newest value means the UI never lags behind.
        let (updates, continuation) = AsyncStream.makeStream(of: DuplicateScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try finder.find(in: roots) { continuation.yield($0) }
        }
        self.worker = worker
        scanTask = Task { [weak self] in
            for await update in updates {
                guard let self, self.scanID == id else { return }
                self.progress = update
            }
            let result = await worker.result
            guard let self, self.scanID == id else { return }
            self.isScanning = false
            guard case .success(let found) = result else { return } // Cancelled.
            self.groups = found.groups
            self.selection = DuplicateSelection(groups: found.groups, keeping: self.keepRule)
            self.unreadableCount = found.unreadableCount
            self.hasScanned = true
        }
    }

    /// Stops a running scan. Finished results are kept.
    func cancel() {
        guard isScanning else { return }
        scanID = UUID()
        worker?.cancel()
        scanTask?.cancel()
        worker = nil
        scanTask = nil
        isScanning = false
    }

    private func resetResults() {
        cancel()
        groups = []
        selection = DuplicateSelection()
        hasScanned = false
        unreadableCount = 0
    }

    // MARK: Selection

    func isSelected(_ file: DuplicateFile) -> Bool { selection.contains(file) }

    func isGroupSelected(_ group: DuplicateGroup) -> Bool { !selection.selectedFiles(in: group).isEmpty }

    /// The copy that stays: the first one that isn't selected.
    func keptFile(in group: DuplicateGroup) -> DuplicateFile? {
        group.files.first { !selection.contains($0) }
    }

    func setSelected(_ file: DuplicateFile, _ selected: Bool, in group: DuplicateGroup) {
        // The selection refuses to mark every copy; let the user know nothing happened.
        if !selection.set(file, selected: selected, in: group) { NSSound.beep() }
    }

    func setGroup(_ group: DuplicateGroup, selected: Bool) {
        selection.setGroup(group, selected: selected, keeping: keepRule)
    }

    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        selection.keepOnly(file, in: group)
    }

    func selectAll() { selection.apply(keepRule, to: groups) }

    func deselectAll() { selection = DuplicateSelection() }

    // MARK: Removal

    /// Moves the selected copies to the Trash as one undoable batch. Every file is re-checked first.
    func moveSelectionToTrash(using app: AppModel) async {
        guard !selection.isEmpty, !isScanning, !isTrashing else { return }
        isTrashing = true
        let groups = groups
        let urls = selection.urls
        let result = await Task.detached(priority: .userInitiated) {
            DuplicateRemover().remove(urls, from: groups)
        }.value
        isTrashing = false

        let count = result.trashed.count
        app.recordTrash(
            title: count == 1 ? String(localized: "Removed 1 duplicate") : String(localized: "Removed \(count) duplicates"),
            records: result.trashed
        )
        app.didRemoveFiles()

        self.groups = DuplicateGroup.removing(Set(result.removed.map(\.url)), from: self.groups)
        selection.prune(to: self.groups)

        if !result.skipped.isEmpty {
            let lines = result.skipped.prefix(5).map { String(localized: "\($0.file.name): \($0.reason.localizedDescription)") }
            let more = result.skipped.count > 5 ? [String(localized: "…and \(result.skipped.count - 5) more.")] : []
            removalProblem = (lines + more).joined(separator: "\n") + "\n\n" + String(localized: "Scan again to see the current state.")
        }
    }
}
