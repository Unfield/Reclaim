import Observation
import ReclaimCore
import SwiftUI

/// State for the iCloud Drive screen, owned by `AppModel`.
@MainActor
@Observable
final class ICloudModel {
    struct EvictionResult: Identifiable {
        let id = UUID()
        let count: Int
        let freed: Int64
        let failures: [String]
    }

    static let daysKey = "icloudUnusedDays"

    /// Only files not opened in this many days are listed.
    var days: Int {
        didSet {
            UserDefaults.standard.set(days, forKey: Self.daysKey)
            updateGroups()
        }
    }

    private(set) var availability: ICloudAvailability?
    private(set) var scan: ICloudScan?
    /// Files not opened in `days`, by folder.
    private(set) var groups: [ICloudGroup] = []
    private(set) var isScanning = false
    private(set) var isEvicting = false
    /// Groups whose files are shown.
    var expanded: Set<URL> = []
    var lastResult: EvictionResult?

    /// Everything eligible is selected unless the user unchecks it, whatever the day filter.
    private var deselected: Set<URL> = []
    @ObservationIgnored private var scanDate = Date()

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.daysKey)
        days = ICloudDrive.idleDayChoices.contains(stored) ? stored : ICloudDrive.defaultIdleDays
    }

    // MARK: Scanning

    func loadIfNeeded() async {
        if scan == nil && availability != .unavailable { await rescan() }
    }

    func rescan() async {
        guard !isScanning, !isEvicting else { return }
        isScanning = true
        defer { isScanning = false }

        let (availability, scan) = await Task.detached(priority: .userInitiated) { () -> (ICloudAvailability, ICloudScan?) in
            let drive = ICloudDrive()
            guard drive.availability == .available else { return (.unavailable, nil) }
            return (.available, drive.scan())
        }.value
        self.availability = availability
        self.scan = scan
        scanDate = Date()
        let known = Set(scan?.candidates.map(\.url) ?? [])
        deselected.formIntersection(known)
        updateGroups()
    }

    private func updateGroups() {
        groups = scan?.groups(unusedFor: days, now: scanDate) ?? []
    }

    // MARK: Selection

    func isSelected(_ item: ICloudItem) -> Bool { !deselected.contains(item.url) }

    func setSelected(_ selected: Bool, _ item: ICloudItem) {
        if selected { deselected.remove(item.url) } else { deselected.insert(item.url) }
    }

    func setSelected(_ selected: Bool, group: ICloudGroup) {
        let urls = group.items.map(\.url)
        if selected { deselected.subtract(urls) } else { deselected.formUnion(urls) }
    }

    func selectedItems(in group: ICloudGroup) -> [ICloudItem] {
        group.items.filter { !deselected.contains($0.url) }
    }

    var selectedItems: [ICloudItem] { groups.flatMap { selectedItems(in: $0) } }

    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    func toggleExpanded(_ group: ICloudGroup) {
        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
    }

    // MARK: Removing downloads

    func removeDownloads(_ items: [ICloudItem], appModel: AppModel) async {
        guard !items.isEmpty, !isEvicting else { return }
        isEvicting = true
        defer { isEvicting = false }

        let days = days
        let report = await Task.detached(priority: .userInitiated) {
            ICloudDrive().evict(items, unusedFor: days)
        }.value

        scan = scan?.removing(Set(report.evicted.map(\.url)))
        updateGroups()
        lastResult = EvictionResult(
            count: report.evicted.count,
            freed: report.bytesFreed,
            failures: report.failures.map(\.message)
        )
        appModel.didRemoveFiles()
    }
}
