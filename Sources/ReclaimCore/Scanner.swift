import Foundation

/// Scans cleanup categories and reports what can be reclaimed.
public struct Scanner: Sendable {
    private let sizer = DirectorySizer()
    private let now: @Sendable () -> Date
    private let exclusions: Exclusions

    public init(exclusions: Exclusions = .load(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.exclusions = exclusions
        self.now = now
    }

    /// Scans all categories concurrently. Results keep the order of `categories`.
    public func scan(
        _ categories: [CleanupCategory],
        progress: (@Sendable (CleanupCategory) -> Void)? = nil
    ) async -> [CategoryScan] {
        await withTaskGroup(of: (Int, CategoryScan).self) { group in
            for (index, category) in categories.enumerated() {
                group.addTask {
                    let result = scan(category)
                    progress?(category)
                    return (index, result)
                }
            }
            var results = [(Int, CategoryScan)]()
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func scan(_ category: CleanupCategory) -> CategoryScan {
        let fileManager = FileManager.default
        var items = [CleanupItem]()
        var inaccessible = 0
        var isPresent = false
        let cutoff = category.minimumAge.map { now().addingTimeInterval(-$0) }

        for root in category.roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            isPresent = true

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: []
                )
            } catch {
                inaccessible += 1
                continue
            }

            let selected = category.selector.select(children.map(\.lastPathComponent))
            for child in children
            where child.lastPathComponent != ".DS_Store"
                && !category.excludedNames.contains(child.lastPathComponent)
                && selected.contains(child.lastPathComponent)
                && !exclusions.excludes(child) {
                let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let cutoff, let modified, modified > cutoff { continue }

                let measured = sizer.size(of: child)
                inaccessible += measured.inaccessibleCount
                guard measured.bytes > 0 else { continue }
                items.append(CleanupItem(url: child, size: measured.bytes, modified: modified))
            }
        }

        items.sort { $0.size > $1.size }
        return CategoryScan(category: category, items: items, isPresent: isPresent, inaccessibleCount: inaccessible)
    }
}
