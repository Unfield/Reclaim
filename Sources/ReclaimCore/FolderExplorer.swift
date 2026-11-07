import Foundation

public struct FolderEntry: Identifiable, Sendable, Hashable {
    public let url: URL
    public let isFolder: Bool
    public let modified: Date?
    /// Nil until measured.
    public var size: Int64?
    public var inaccessibleCount: Int = 0

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// Lists a folder's contents with their total sizes, for drilling down into what uses space.
public enum FolderExplorer {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey]

    /// Lists direct children without measuring them (fast). Packages like `.app` bundles count as files.
    public static func list(_ folder: URL, includeHidden: Bool = true) throws -> [FolderEntry] {
        let children = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        return children.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let isFolder = values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true
            return FolderEntry(url: url, isFolder: isFolder, modified: values?.contentModificationDate)
        }
    }

    public static func measure(_ entry: FolderEntry) -> FolderEntry {
        var measured = entry
        let result = DirectorySizer().size(of: entry.url)
        measured.size = result.bytes
        measured.inaccessibleCount = result.inaccessibleCount
        return measured
    }

    /// Lists and measures a folder's children, largest first.
    public static func measuredContents(of folder: URL, includeHidden: Bool = true) async throws -> [FolderEntry] {
        let entries = try list(folder, includeHidden: includeHidden)
        return await withTaskGroup(of: FolderEntry.self) { group in
            for entry in entries {
                group.addTask { measure(entry) }
            }
            var results = [FolderEntry]()
            for await entry in group { results.append(entry) }
            return results.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }
    }
}
