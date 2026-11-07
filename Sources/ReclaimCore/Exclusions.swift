import Foundation

/// Paths the user never wants cleaned. Shared by the app and the CLI
/// (stored in ~/Library/Application Support/Reclaim/exclusions.json).
public struct Exclusions: Codable, Sendable, Equatable {
    public var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }

    static var file: URL { ReclaimPaths.supportDirectory.appending(path: "exclusions.json") }

    public static func load() -> Exclusions {
        guard let data = try? Data(contentsOf: file),
              let exclusions = try? JSONDecoder().decode(Exclusions.self, from: data)
        else { return Exclusions() }
        return exclusions
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    /// True if the URL is an excluded path or inside one.
    public func excludes(_ url: URL) -> Bool {
        let path = url.normalizedPath
        return paths.contains { excluded in
            let base = URL(filePath: excluded).normalizedPath
            return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
        }
    }

    public mutating func add(_ url: URL) {
        let path = url.normalizedPath
        guard !paths.contains(path) else { return }
        paths.append(path)
        paths.sort()
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }
}
