import Foundation

public enum CleanupError: Error, LocalizedError, Sendable {
    case outsideCategoryRoots(URL)
    case excluded(URL)

    public var errorDescription: String? {
        switch self {
        case .outsideCategoryRoots(let url):
            "Refusing to remove \(url.abbreviatedPath): it isn't directly inside one of the category's folders."
        case .excluded(let url):
            "Skipped \(url.abbreviatedPath): it's on your exclusion list."
        }
    }
}

public struct CleanupFailure: Sendable {
    public let item: CleanupItem
    public let message: String

    public init(item: CleanupItem, message: String) {
        self.item = item
        self.message = message
    }
}

public struct CleanupReport: Sendable {
    public var removed: [CleanupItem] = []
    public var failures: [CleanupFailure] = []
    /// Items moved to the Trash, so they can be put back.
    public var trashed: [TrashRecord] = []
    public var dryRun: Bool

    public init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    public var bytesFreed: Int64 { removed.reduce(0) { $0 + $1.size } }
}

/// Removes items found by the `Scanner`.
///
/// As a safety net, an item is only removed if it is a *direct child* of one of its
/// category's roots, so a bad path can never take out a whole folder like ~/Library.
public struct Cleaner: Sendable {
    private let exclusions: Exclusions

    public init(exclusions: Exclusions = .load()) {
        self.exclusions = exclusions
    }

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
                    switch effectiveMethod {
                    case .moveToTrash:
                        report.trashed.append(try Trash.move(item.url, size: item.size))
                    case .deletePermanently:
                        try FileManager.default.removeItem(at: item.url)
                    }
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
        guard isDirectChild, !name.isEmpty, name != ".", name != "..",
              !category.excludedNames.contains(name), category.selector.allows(name)
        else {
            throw CleanupError.outsideCategoryRoots(url)
        }
        if exclusions.excludes(url) { throw CleanupError.excluded(url) }
    }
}
