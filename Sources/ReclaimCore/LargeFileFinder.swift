import Foundation

/// Finds the largest individual files under a directory.
public struct LargeFileFinder: Sendable {
    public struct Options: Sendable {
        public var minimumSize: Int64
        public var limit: Int
        public var includeHidden: Bool
        /// Folder names that are never descended into.
        public var skippedDirectoryNames: Set<String>

        public init(
            minimumSize: Int64 = 100_000_000,
            limit: Int = 50,
            includeHidden: Bool = false,
            skippedDirectoryNames: Set<String> = [".Trash", "node_modules", ".git"]
        ) {
            self.minimumSize = minimumSize
            self.limit = limit
            self.includeHidden = includeHidden
            self.skippedDirectoryNames = skippedDirectoryNames
        }
    }

    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .nameKey,
    ]

    public init() {}

    /// Returns the largest files, biggest first. Package contents (e.g. inside `.app` bundles) are skipped.
    public func find(in root: URL, options: Options = Options()) -> [CleanupItem] {
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeHidden { enumerationOptions.insert(.skipsHiddenFiles) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Self.keys),
            options: enumerationOptions,
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results = [CleanupItem]()
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Self.keys) else { continue }

            if values.isDirectory == true {
                if let name = values.name, options.skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard size >= options.minimumSize else { continue }
            results.append(CleanupItem(url: url, size: size, modified: values.contentModificationDate))
        }

        results.sort { $0.size > $1.size }
        return Array(results.prefix(options.limit))
    }
}
