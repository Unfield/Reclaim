import Observation
import ReclaimCore
import SwiftUI

/// State for the Login Items screen, owned by `AppModel`.
@MainActor
@Observable
final class LoginItemsModel {
    var items: [LaunchItem] = []
    var isLoading = false
    var hasLoaded = false
    /// IDs of items with an action in progress.
    var busy: Set<String> = []
    /// The last error, shown above the list.
    var message: String?

    /// The newest load wins, so a reload after an action is never dropped because another load was running.
    @ObservationIgnored private var loadGeneration = 0

    init() {}

    func items(in domain: LaunchItemDomain) -> [LaunchItem] {
        items.filter { $0.domain == domain }
    }

    var brokenCount: Int { items.filter(\.isBroken).count }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let fresh = await Task.detached(priority: .userInitiated) { await LaunchItems.scan() }.value
        guard generation == loadGeneration else { return }
        items = fresh
        hasLoaded = true
        isLoading = false
    }

    /// Turns an item on or off. System-wide items ask for an administrator password.
    func setEnabled(_ item: LaunchItem, _ enabled: Bool) async {
        await perform(on: item) {
            try await LaunchItems.setEnabled(enabled, item, allowAdministrator: true)
        }
    }

    /// Moves a broken item's launch file to the Trash. Returns a record for undo when the file was the user's own.
    func remove(_ item: LaunchItem) async -> TrashRecord? {
        var record: TrashRecord?
        await perform(on: item) {
            record = try await LaunchItems.remove(item, allowAdministrator: true)
        }
        return record
    }

    private func perform(on item: LaunchItem, _ action: () async throws -> Void) async {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        message = nil
        do {
            try await action()
        } catch {
            // Cancelling the password prompt isn't an error worth showing.
            let text = error.localizedDescription
            if !text.contains("(-128)") { message = text }
        }
        busy.remove(item.id)
        await load()
    }
}
