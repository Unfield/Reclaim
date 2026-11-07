import Observation
import ReclaimCore
import SwiftUI

/// State for the App Leftovers screen, owned by `AppModel`.
@MainActor
@Observable
final class OrphansModel {
    private(set) var groups: [LeftoverGroup] = []
    private(set) var unreadableFolders: [URL] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var isRemoving = false
    /// Locations being measured on request (containers aren't measured during a scan).
    private(set) var measuring = Set<URL>()
    /// Checked locations. Nothing is preselected.
    private(set) var selection = Set<URL>()
    var expandedGroups = Set<String>()
    /// Problems from the last removal, shown in an alert.
    var removalFailures: [String] = []

    init() {}

    // MARK: Scanning

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let result = await Task.detached(priority: .userInitiated) {
            await OrphanFinder().scan()
        }.value
        groups = result.groups
        unreadableFolders = result.unreadableFolders
        hasScanned = true
        let present = Set(groups.flatMap { $0.locations.map(\.url) })
        selection.formIntersection(present)
        expandedGroups.formIntersection(groups.map(\.id))
    }

    /// Measures an unmeasured location (an app container). macOS may ask the user for permission.
    func measure(_ location: LeftoverLocation) {
        guard location.size == nil, !measuring.contains(location.url) else { return }
        measuring.insert(location.url)
        Task {
            let measured = await Task.detached(priority: .userInitiated) {
                OrphanFinder.measured(location)
            }.value
            measuring.remove(location.url)
            // Sizes update in place; the list isn't re-sorted, so rows don't jump around.
            for groupIndex in groups.indices {
                if let index = groups[groupIndex].locations.firstIndex(where: { $0.url == measured.url }) {
                    groups[groupIndex].locations[index] = measured
                }
            }
        }
    }

    func measureAll(in group: LeftoverGroup) {
        group.locations.filter { $0.size == nil }.forEach(measure)
    }

    // MARK: Selection

    func isSelected(_ location: LeftoverLocation) -> Bool {
        selection.contains(location.url)
    }

    func setSelected(_ location: LeftoverLocation, _ selected: Bool) {
        if selected {
            selection.insert(location.url)
            // Choosing it for removal is a clear signal the user wants to know its size.
            measure(location)
        } else {
            selection.remove(location.url)
        }
    }

    func setSelected(_ group: LeftoverGroup, _ selected: Bool) {
        group.locations.forEach { setSelected($0, selected) }
    }

    func isFullySelected(_ group: LeftoverGroup) -> Bool {
        group.locations.allSatisfy { selection.contains($0.url) }
    }

    var selectedLocations: [LeftoverLocation] {
        groups.flatMap { $0.locations.filter { selection.contains($0.url) } }
    }

    var selectedGroups: [LeftoverGroup] {
        groups.filter { $0.locations.contains { selection.contains($0.url) } }
    }

    var selectedSize: Int64 {
        selectedLocations.reduce(0) { $0 + ($1.size ?? 0) }
    }

    // MARK: Removal

    /// Moves the checked locations to the Trash as one undoable batch.
    func removeSelected(using app: AppModel) async {
        let locations = selectedLocations
        guard !locations.isEmpty, !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }

        let names = selectedGroups.map(\.name)
        // A fresh finder re-checks every path, installed apps and exclusions right before removing.
        let report = await Task.detached(priority: .userInitiated) {
            OrphanFinder().remove(locations, method: .moveToTrash)
        }.value

        let title = names.count == 1
            ? String(localized: "Removed leftovers of \(names[0])")
            : String(localized: "Removed leftovers of \(names.count) apps")
        app.recordTrash(title: title, records: report.trashed)
        app.didRemoveFiles()

        let removed = Set(report.removed.map(\.url))
        selection.subtract(removed)
        groups = groups.compactMap { group in
            var group = group
            group.locations.removeAll { removed.contains($0.url) }
            return group.locations.isEmpty ? nil : group
        }
        removalFailures = report.failures.map { String(localized: "\($0.item.url.abbreviatedPath): \($0.message)") }
    }
}
