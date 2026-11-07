import Foundation

public enum CleanupError: Error, LocalizedError, Sendable {
    case outsideCategoryRoots(URL)

    public var errorDescription: String? {
        switch self {
        case .outsideCategoryRoots(let url):
            "Refusing to remove \(url.abbreviatedPath): it isn't directly inside one of the category's folders."
        }
    }
}

public struct CleanupFailure: Sendable {
    public let item: CleanupItem
    public let message: String
}

public struct CleanupReport: Sendable {
    public var removed: [CleanupItem] = []
    public var failures: [CleanupFailure] = []
    public var dryRun: Bool

    public var bytesFreed: Int64 { removed.reduce(0) { $0 + $1.size } }
}

/// Removes items found by the `Scanner`.
///
/// As a safety net, an item is only removed if it is a *direct child* of one of its
/// category's roots, so a bad path can never take out a whole folder like ~/Library.
public struct Cleaner: Sendable {
    public init() {}

    public func clean(
        _ items: [CleanupItem],
        in category: CleanupCategory,
        method: CleanupMethod,
        dryRun: Bool = false
    ) -> CleanupReport {
        var report = CleanupReport(dryRun: dryRun)
        let effectiveMethod: CleanupMethod = category.deletesPermanently ? .deletePermanently : method

        for item in items {
            do {
                try validate(item.url, in: category)
                if !dryRun {
                    try remove(item.url, using: effectiveMethod)
                }
                report.removed.append(item)
            } catch {
                report.failures.append(CleanupFailure(item: item, message: error.localizedDescription))
            }
        }
        return report
    }

    func validate(_ url: URL, in category: CleanupCategory) throws {
        let parent = url.deletingLastPathComponent().normalizedPath
        let isDirectChild = category.roots.contains { $0.normalizedPath == parent }
        let name = url.lastPathComponent
        guard isDirectChild, !name.isEmpty, name != ".", name != "..", !category.excludedNames.contains(name) else {
            throw CleanupError.outsideCategoryRoots(url)
        }
    }

    private func remove(_ url: URL, using method: CleanupMethod) throws {
        let fileManager = FileManager.default
        switch method {
        case .moveToTrash:
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        case .deletePermanently:
            try fileManager.removeItem(at: url)
        }
    }
}
