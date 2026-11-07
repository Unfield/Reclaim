import Foundation

/// Measures on-disk usage of files and folders without following symbolic links.
public struct DirectorySizer: Sendable {
    public struct Result: Sendable {
        public var bytes: Int64
        public var inaccessibleCount: Int
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    public init() {}

    public func size(of url: URL) -> Result {
        guard let values = try? url.resourceValues(forKeys: Self.keys) else {
            return Result(bytes: 0, inaccessibleCount: 1)
        }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Result(bytes: Self.allocatedSize(values), inaccessibleCount: 0)
        }

        // Errors are collected from a synchronous callback; a reference box keeps the closure non-escaping-friendly.
        final class Counter: @unchecked Sendable { var value = 0 }
        let errors = Counter()

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(Self.keys),
            options: [],
            errorHandler: { _, _ in
                errors.value += 1
                return true
            }
        )

        var total: Int64 = 0
        while let child = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let childValues = try? child.resourceValues(forKeys: Self.keys) else {
                errors.value += 1
                continue
            }
            if childValues.isDirectory == true && childValues.isSymbolicLink != true { continue }
            total += Self.allocatedSize(childValues)
        }
        return Result(bytes: total, inaccessibleCount: errors.value)
    }

    private static func allocatedSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
