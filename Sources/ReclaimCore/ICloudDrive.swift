import Foundation

// MARK: - Metadata

/// Whether an iCloud item has a local copy.
public enum ICloudDownloadState: Sendable, Equatable {
    /// Downloaded, and the latest version.
    case current
    /// Downloaded, but a newer version exists in iCloud.
    case downloaded
    /// Only in iCloud (a placeholder on this Mac).
    case notDownloaded
    case unknown

    public var hasLocalCopy: Bool { self == .current || self == .downloaded }

    init(_ status: URLUbiquitousItemDownloadingStatus?) {
        switch status {
        case .current?: self = .current
        case .downloaded?: self = .downloaded
        case .notDownloaded?: self = .notDownloaded
        default: self = .unknown
        }
    }
}

/// What Reclaim needs to know about a file in iCloud Drive. Injectable so the logic can be tested without iCloud.
public struct ICloudFileMetadata: Sendable, Equatable {
    public var isUbiquitous: Bool
    public var downloadState: ICloudDownloadState
    public var isUploaded: Bool
    public var isUploading: Bool
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isSymbolicLink: Bool
    public var isHidden: Bool
    /// Space the local copy takes up. For packages, the total of their contents.
    public var allocatedSize: Int64
    public var contentAccessDate: Date?
    public var modificationDate: Date?

    public init(
        isUbiquitous: Bool = true,
        downloadState: ICloudDownloadState = .current,
        isUploaded: Bool = true,
        isUploading: Bool = false,
        isDirectory: Bool = false,
        isPackage: Bool = false,
        isSymbolicLink: Bool = false,
        isHidden: Bool = false,
        allocatedSize: Int64 = 0,
        contentAccessDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.isUbiquitous = isUbiquitous
        self.downloadState = downloadState
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isHidden = isHidden
        self.allocatedSize = allocatedSize
        self.contentAccessDate = contentAccessDate
        self.modificationDate = modificationDate
    }

    /// When the file was last opened. Uses the later of the access and modification dates,
    /// so a file that was edited recently never counts as unused.
    public var lastUsed: Date? {
        switch (contentAccessDate, modificationDate) {
        case let (access?, modified?): max(access, modified)
        case let (access?, nil): access
        case let (nil, modified?): modified
        case (nil, nil): nil
        }
    }

    /// A single item from the user's point of view: a regular file or a package (e.g. a `.pages` document).
    var isItem: Bool { !isDirectory || isPackage }
}

/// Why a file can't have its download removed.
public enum ICloudIneligibility: Sendable, Equatable {
    case notInICloud
    case symbolicLink
    case notDownloaded
    case notUploaded
    case uploading
    case usedRecently
    case unknownLastUse
    case empty
}

/// File system access for `ICloudDrive`. The live implementation reads URL resource values.
public protocol ICloudFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    /// Direct children of a folder (including hidden ones; the caller filters).
    func contents(of directory: URL) throws -> [URL]
    /// Metadata for one item, without following symbolic links. Nil if it can't be read.
    func metadata(for url: URL) -> ICloudFileMetadata?
    /// Like `metadata(for:)`, but never from a cache. Used for the check right before evicting.
    func currentMetadata(for url: URL) -> ICloudFileMetadata?
    /// A friendly, localized name for a top-level folder in Mobile Documents (e.g. "iCloud Drive", "Pages").
    func localizedName(of url: URL) -> String?
    /// Removes the local copy, keeping the item in iCloud.
    func evict(_ url: URL) throws
}

extension ICloudFileSystem {
    public func currentMetadata(for url: URL) -> ICloudFileMetadata? { metadata(for: url) }
}

public struct LiveICloudFileSystem: ICloudFileSystem {
    static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey,
    ]

    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    public func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(Self.keys), options: [])
    }

    public func currentMetadata(for url: URL) -> ICloudFileMetadata? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return metadata(for: fresh)
    }

    public func metadata(for url: URL) -> ICloudFileMetadata? {
        guard let values = try? url.resourceValues(forKeys: Self.keys) else { return nil }
        let isPackage = values.isPackage == true && values.isDirectory == true
        var size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        if isPackage && values.isSymbolicLink != true {
            size = DirectorySizer().size(of: url).bytes
        }
        return ICloudFileMetadata(
            isUbiquitous: values.isUbiquitousItem == true,
            downloadState: ICloudDownloadState(values.ubiquitousItemDownloadingStatus),
            isUploaded: values.ubiquitousItemIsUploaded == true,
            isUploading: values.ubiquitousItemIsUploading == true,
            isDirectory: values.isDirectory == true,
            isPackage: isPackage,
            isSymbolicLink: values.isSymbolicLink == true,
            isHidden: values.isHidden == true || url.lastPathComponent.hasPrefix("."),
            allocatedSize: size,
            contentAccessDate: values.contentAccessDate,
            modificationDate: values.contentModificationDate
        )
    }

    public func localizedName(of url: URL) -> String? {
        try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName
    }

    public func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

// MARK: - Results

/// A top-level folder in Mobile Documents: iCloud Drive itself, or an app's folder.
public struct ICloudFolder: Identifiable, Sendable, Hashable {
    public let url: URL
    public let name: String
    /// True for iCloud Drive's main folder (`com~apple~CloudDocs`).
    public let isDrive: Bool

    public init(url: URL, name: String, isDrive: Bool) {
        self.url = url
        self.name = name
        self.isDrive = isDrive
    }

    public var id: URL { url }
}

/// A downloaded, fully uploaded file (or package) whose local copy could be removed.
public struct ICloudItem: Identifiable, Sendable, Hashable {
    public let url: URL
    public let folder: URL
    public let size: Int64
    public let lastUsed: Date?
    public let isPackage: Bool

    public init(url: URL, folder: URL, size: Int64, lastUsed: Date?, isPackage: Bool = false) {
        self.url = url
        self.folder = folder
        self.size = size
        self.lastUsed = lastUsed
        self.isPackage = isPackage
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// The folder path as Finder shows it, e.g. "Documents/Taxes" in iCloud Drive (empty at the top).
    /// An app's files live in its `Documents` folder, which Finder shows as the app's folder itself.
    public var subfolderPath: String {
        var base = folder.normalizedPath
        if folder.lastPathComponent != ICloudDrive.driveFolderName { base += "/Documents" }
        let parent = url.deletingLastPathComponent().normalizedPath
        guard parent.hasPrefix(base + "/") else { return "" }
        return String(parent.dropFirst(base.count + 1))
    }

    public func isUnused(days: Int, now: Date = Date()) -> Bool {
        guard let lastUsed else { return false }
        return lastUsed < ICloudDrive.cutoff(days: days, now: now)
    }
}

public struct ICloudGroup: Identifiable, Sendable {
    public let folder: ICloudFolder
    /// Largest first.
    public let items: [ICloudItem]

    public var id: URL { folder.url }
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct ICloudScan: Sendable {
    public let folders: [ICloudFolder]
    /// Every downloaded, fully uploaded item, regardless of when it was last used.
    public let candidates: [ICloudItem]
    /// Items that couldn't be read.
    public let inaccessibleCount: Int

    public init(folders: [ICloudFolder], candidates: [ICloudItem], inaccessibleCount: Int) {
        self.folders = folders
        self.candidates = candidates
        self.inaccessibleCount = inaccessibleCount
    }

    /// Space used by downloaded iCloud files on this Mac (that are safely in iCloud).
    public var downloadedSize: Int64 { candidates.reduce(0) { $0 + $1.size } }

    /// Items not opened in `days`, grouped by top-level folder. iCloud Drive comes first, then the largest groups.
    public func groups(unusedFor days: Int, now: Date = Date()) -> [ICloudGroup] {
        let unused = candidates.filter { $0.isUnused(days: days, now: now) }
        let byFolder = Dictionary(grouping: unused, by: \.folder)
        let groups = folders.compactMap { folder -> ICloudGroup? in
            guard let items = byFolder[folder.url], !items.isEmpty else { return nil }
            return ICloudGroup(folder: folder, items: items.sorted { ($0.size, $1.url.path) > ($1.size, $0.url.path) })
        }
        return groups.sorted { lhs, rhs in
            if lhs.folder.isDrive != rhs.folder.isDrive { return lhs.folder.isDrive }
            if lhs.totalSize != rhs.totalSize { return lhs.totalSize > rhs.totalSize }
            return lhs.folder.name.localizedStandardCompare(rhs.folder.name) == .orderedAscending
        }
    }

    /// The same scan without the given items (e.g. after their downloads were removed).
    public func removing(_ urls: Set<URL>) -> ICloudScan {
        ICloudScan(folders: folders, candidates: candidates.filter { !urls.contains($0.url) }, inaccessibleCount: inaccessibleCount)
    }
}

public enum ICloudAvailability: Sendable, Equatable {
    case available
    /// No iCloud folder at all: not signed in to iCloud, or iCloud Drive is turned off.
    case unavailable
}

public enum ICloudEvictionError: Error, LocalizedError, Sendable {
    case outsideICloud(URL)
    case excluded(URL)
    case notEligible(URL, ICloudIneligibility)
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .outsideICloud(let url):
            "Skipped \(url.lastPathComponent): it isn't inside iCloud Drive."
        case .excluded(let url):
            "Skipped \(url.lastPathComponent): it's on your exclusion list."
        case .unreadable(let url):
            "Skipped \(url.lastPathComponent): it couldn't be read."
        case .notEligible(let url, let reason):
            "Skipped \(url.lastPathComponent): " + {
                switch reason {
                case .notInICloud: "it isn't stored in iCloud."
                case .symbolicLink: "it's a symbolic link."
                case .notDownloaded: "it's already only in iCloud."
                case .notUploaded, .uploading: "it hasn't finished uploading to iCloud."
                case .usedRecently, .unknownLastUse: "it was opened recently."
                case .empty: "it doesn't use any space."
                }
            }()
        }
    }
}

public struct ICloudEvictionReport: Sendable {
    public var evicted: [ICloudItem] = []
    public var failures: [(item: ICloudItem, message: String)] = []

    public init() {}

    public var bytesFreed: Int64 { evicted.reduce(0) { $0 + $1.size } }
}

// MARK: - Scanner

/// Finds iCloud Drive files that are downloaded but haven't been opened in a while, and removes their
/// local copies ("Remove Download" in Finder). Nothing is deleted from iCloud.
public struct ICloudDrive: Sendable {
    public static let defaultIdleDays = 60
    public static let idleDayChoices = [30, 60, 90, 180]
    static let driveFolderName = "com~apple~CloudDocs"

    public let root: URL
    private let fileSystem: any ICloudFileSystem
    private let exclusions: Exclusions

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
    }

    public init(root: URL = ICloudDrive.defaultRoot, fileSystem: any ICloudFileSystem = LiveICloudFileSystem(), exclusions: Exclusions = .load()) {
        self.root = root
        self.fileSystem = fileSystem
        self.exclusions = exclusions
    }

    public static func cutoff(days: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(max(0, days)) * 86_400)
    }

    public var availability: ICloudAvailability {
        fileSystem.fileExists(at: root.appending(path: Self.driveFolderName)) ? .available : .unavailable
    }

    /// Checks whether an item's local copy can be removed. Returns nil if it can.
    public static func ineligibility(of metadata: ICloudFileMetadata, unusedFor days: Int, now: Date = Date()) -> ICloudIneligibility? {
        if let reason = syncIneligibility(of: metadata) { return reason }
        guard let lastUsed = metadata.lastUsed else { return .unknownLastUse }
        return lastUsed < cutoff(days: days, now: now) ? nil : .usedRecently
    }

    /// Everything except the age check: the item is in iCloud, downloaded, and safely uploaded.
    static func syncIneligibility(of metadata: ICloudFileMetadata) -> ICloudIneligibility? {
        if metadata.isSymbolicLink { return .symbolicLink }
        guard metadata.isUbiquitous else { return .notInICloud }
        guard metadata.downloadState.hasLocalCopy else { return .notDownloaded }
        if metadata.isUploading { return .uploading }
        guard metadata.isUploaded else { return .notUploaded }
        guard metadata.allocatedSize > 0 else { return .empty }
        return nil
    }

    /// Top-level folders: iCloud Drive and each app's folder.
    public func folders() -> [ICloudFolder] {
        guard let children = try? fileSystem.contents(of: root) else { return [] }
        return children.compactMap { url -> ICloudFolder? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let metadata = fileSystem.metadata(for: url),
                  metadata.isDirectory, !metadata.isSymbolicLink
            else { return nil }
            return ICloudFolder(url: url, name: displayName(for: url), isDrive: name == Self.driveFolderName)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func displayName(for folder: URL) -> String {
        if folder.lastPathComponent == Self.driveFolderName { return "iCloud Drive" }
        // Some names carry invisible direction marks (e.g. "\u{200E}WhatsApp").
        let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}").union(.whitespacesAndNewlines)
        if let localized = fileSystem.localizedName(of: folder)?.trimmingCharacters(in: invisible),
           !localized.isEmpty, localized != folder.lastPathComponent {
            return localized
        }
        return Self.fallbackName(forFolderNamed: folder.lastPathComponent)
    }

    /// Derives a name from a container folder such as `iCloud~com~vendor~App` or `ABCDE12345~com~vendor~App`.
    static func fallbackName(forFolderNamed name: String) -> String {
        if name == driveFolderName { return "iCloud Drive" }
        var parts = name.split(separator: "~").map(String.init)
        if let first = parts.first, parts.count > 1, first == "iCloud" || isTeamID(first) {
            parts.removeFirst()
        }
        guard let last = parts.last, !last.isEmpty else { return name }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
    }

    /// The part of a top-level folder that holds the user's files: all of iCloud Drive, but only the `Documents`
    /// folder of an app (what Finder shows). The rest of an app's folder is its private data, which is left alone.
    func userContentRoot(of folder: URL) -> URL {
        folder.lastPathComponent == Self.driveFolderName ? folder : folder.appending(path: "Documents", directoryHint: .isDirectory)
    }

    /// Lists every downloaded, fully uploaded item. Filter by age with `ICloudScan.groups(unusedFor:)`.
    public func scan() -> ICloudScan {
        let folders = folders()
        var candidates = [ICloudItem]()
        var inaccessible = 0

        for folder in folders {
            let start = userContentRoot(of: folder.url)
            guard start == folder.url || isRealFolder(start) else { continue }
            var stack = [start]
            while let directory = stack.popLast() {
                if Task.isCancelled { break }
                guard let children = try? fileSystem.contents(of: directory) else {
                    inaccessible += 1
                    continue
                }
                for child in children {
                    // Hidden files include old-style `.name.icloud` placeholders, `.DS_Store` and `.Trash`.
                    if child.lastPathComponent.hasPrefix(".") || exclusions.excludes(child) { continue }
                    guard let metadata = fileSystem.metadata(for: child) else {
                        inaccessible += 1
                        continue
                    }
                    if metadata.isSymbolicLink || metadata.isHidden { continue }
                    if !metadata.isItem {
                        stack.append(child)
                        continue
                    }
                    guard Self.syncIneligibility(of: metadata) == nil else { continue }
                    candidates.append(ICloudItem(
                        url: child,
                        folder: folder.url,
                        size: metadata.allocatedSize,
                        lastUsed: metadata.lastUsed,
                        isPackage: metadata.isPackage
                    ))
                }
            }
        }
        return ICloudScan(folders: folders, candidates: candidates, inaccessibleCount: inaccessible)
    }

    private func isRealFolder(_ url: URL) -> Bool {
        guard let metadata = fileSystem.metadata(for: url) else { return false }
        return metadata.isDirectory && !metadata.isPackage && !metadata.isSymbolicLink
    }

    /// Removes the local copies of items. Each item is checked again right before, so anything that was
    /// opened, changed or is still uploading since the scan is left alone.
    public func evict(_ items: [ICloudItem], unusedFor days: Int, now: Date = Date(), dryRun: Bool = false) -> ICloudEvictionReport {
        var report = ICloudEvictionReport()
        for item in items {
            do {
                try validate(item.url, unusedFor: days, now: now)
                if !dryRun { try fileSystem.evict(item.url) }
                report.evicted.append(item)
            } catch {
                report.failures.append((item, error.localizedDescription))
            }
        }
        return report
    }

    func validate(_ url: URL, unusedFor days: Int, now: Date) throws {
        // Must be inside iCloud Drive or an app's Documents folder (never one of those folders itself), with no `..` tricks.
        let rootPath = root.normalizedPath
        let path = url.normalizedPath
        guard path.hasPrefix(rootPath + "/") else { throw ICloudEvictionError.outsideICloud(url) }
        let relative = path.dropFirst(rootPath.count + 1).split(separator: "/")
        guard let top = relative.first, !relative.contains(where: { $0 == ".." || $0 == "." }) else {
            throw ICloudEvictionError.outsideICloud(url)
        }
        let isDrive = top == Self.driveFolderName
        guard isDrive ? relative.count >= 2 : relative.count >= 3 && relative[1] == "Documents" else {
            throw ICloudEvictionError.outsideICloud(url)
        }
        if exclusions.excludes(url) { throw ICloudEvictionError.excluded(url) }
        guard let metadata = fileSystem.currentMetadata(for: url) else { throw ICloudEvictionError.unreadable(url) }
        guard metadata.isItem else { throw ICloudEvictionError.outsideICloud(url) }
        if let reason = Self.ineligibility(of: metadata, unusedFor: days, now: now) {
            throw ICloudEvictionError.notEligible(url, reason)
        }
    }
}
