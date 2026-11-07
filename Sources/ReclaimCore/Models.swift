import Foundation

/// How confident we are that removing a category is harmless.
public enum SafetyLevel: Int, Sendable, CaseIterable, Comparable {
    /// Regenerated automatically by apps or tools.
    case safe
    /// Usually fine to remove, but worth a quick look first.
    case review
    /// May contain data you care about.
    case caution

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .safe: String(localized: "Safe")
        case .review: String(localized: "Review")
        case .caution: String(localized: "Caution")
        }
    }

    public var explanation: String {
        switch self {
        case .safe: String(localized: "Rebuilt automatically when needed.")
        case .review: String(localized: "Usually safe, but may need re-downloading or rebuilding.")
        case .caution: String(localized: "May contain personal data. Review before removing.")
        }
    }
}

public enum CategoryGroup: String, Sendable, CaseIterable {
    case system = "System & Apps"
    case developer = "Developer"
    case personal = "Personal Files"
    case otherDisks = "Other Disks"

    /// The section title shown in the app. The raw value stays English, since it's used as an identifier.
    public var title: String {
        switch self {
        case .system: String(localized: "System & Apps")
        case .developer: String(localized: "Developer")
        case .personal: String(localized: "Personal Files")
        case .otherDisks: String(localized: "Other Disks")
        }
    }
}

public enum CleanupMethod: String, Sendable, CaseIterable {
    case moveToTrash
    case deletePermanently
}

/// A kind of reclaimable data. Every direct child of each root is a cleanable item.
public struct CleanupCategory: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let summary: String
    public let group: CategoryGroup
    public let safety: SafetyLevel
    public let roots: [URL]
    /// Only include items not modified within this interval.
    public let minimumAge: TimeInterval?
    /// Items are removed permanently regardless of the chosen method (e.g. the Trash itself).
    public let deletesPermanently: Bool
    /// Names of direct children that are never included (e.g. handled by a dedicated tool instead).
    public let excludedNames: Set<String>
    /// Which direct children count as items.
    public let selector: ItemSelector

    public init(
        id: String,
        name: String,
        summary: String,
        group: CategoryGroup,
        safety: SafetyLevel,
        roots: [URL],
        minimumAge: TimeInterval? = nil,
        deletesPermanently: Bool = false,
        excludedNames: Set<String> = [],
        selector: ItemSelector = .allChildren
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.group = group
        self.safety = safety
        self.roots = roots
        self.minimumAge = minimumAge
        self.deletesPermanently = deletesPermanently
        self.excludedNames = excludedNames
        self.selector = selector
    }
}

public struct CleanupItem: Identifiable, Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let modified: Date?

    public init(url: URL, size: Int64, modified: Date?) {
        self.url = url
        self.size = size
        self.modified = modified
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

public struct CategoryScan: Identifiable, Sendable {
    public let category: CleanupCategory
    /// Sorted largest first.
    public let items: [CleanupItem]
    /// Whether at least one of the category's roots exists.
    public let isPresent: Bool
    /// Files or folders that couldn't be read (often due to missing Full Disk Access).
    public let inaccessibleCount: Int

    public init(category: CleanupCategory, items: [CleanupItem], isPresent: Bool, inaccessibleCount: Int) {
        self.category = category
        self.items = items
        self.isPresent = isPresent
        self.inaccessibleCount = inaccessibleCount
    }

    public var id: String { category.id }
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}
