import Foundation

/// Restricts which file names a category includes.
///
/// A name is included if it has one of `extensions` *or* fully matches one of `patterns`
/// (if both are empty, every name is included), and doesn't have an excluded extension.
public struct NameFilter: Sendable, Hashable {
    /// Lowercase extensions without the dot.
    public var extensions: Set<String>
    /// Regular expressions matched against the whole name.
    public var patterns: [String]
    public var excludedExtensions: Set<String>
    public var excludedPatterns: [String]

    public init(
        extensions: Set<String> = [], patterns: [String] = [],
        excludedExtensions: Set<String> = [], excludedPatterns: [String] = []
    ) {
        self.extensions = extensions
        self.patterns = patterns
        self.excludedExtensions = excludedExtensions
        self.excludedPatterns = excludedPatterns
    }

    public func matches(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if excludedExtensions.contains(ext) { return false }
        if excludedPatterns.contains(where: { (try? Regex($0).wholeMatch(in: name)) != nil }) { return false }
        if extensions.isEmpty && patterns.isEmpty { return true }
        if extensions.contains(ext) { return true }
        return patterns.contains { pattern in
            (try? Regex(pattern).wholeMatch(in: name)) != nil
        }
    }
}

/// How a category picks items from the direct children of its roots.
public enum ItemSelector: Sendable, Hashable {
    /// Every child.
    case allChildren
    /// Children whose names pass the filter.
    case matching(NameFilter)
    /// For versioned folders (e.g. `IntelliJIdea2024.3`, `ms-python.python-2024.2.1`), every version except the newest
    /// of each product. `pattern` is a regex whose first capture is the product and second the version.
    case olderVersions(pattern: String)

    /// Picks the cleanable names out of a folder's children.
    public func select(_ names: [String]) -> Set<String> {
        switch self {
        case .allChildren:
            return Set(names)
        case .matching(let filter):
            return Set(names.filter(filter.matches))
        case .olderVersions(let pattern):
            guard let regex = try? Regex(pattern) else { return [] }
            var products: [String: [(name: String, version: String)]] = [:]
            for name in names {
                guard let match = try? regex.wholeMatch(in: name), match.output.count >= 3,
                      let product = match.output[1].substring, let version = match.output[2].substring
                else { continue }
                products[String(product), default: []].append((name, String(version)))
            }
            var old = Set<String>()
            for versions in products.values where versions.count > 1 {
                let sorted = versions.sorted { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
                old.formUnion(sorted.dropLast().map(\.name))
            }
            return old
        }
    }

    /// Whether a single name could ever be selected (used as a safety check before removal).
    public func allows(_ name: String) -> Bool {
        switch self {
        case .allChildren:
            return true
        case .matching(let filter):
            return filter.matches(name)
        case .olderVersions(let pattern):
            guard let regex = try? Regex(pattern) else { return false }
            return (try? regex.wholeMatch(in: name)) != nil
        }
    }
}
