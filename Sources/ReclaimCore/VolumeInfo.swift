import Foundation

public struct VolumeInfo: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable {
        case startup
        case internalDisk
        case external
        case network
        case diskImage
    }

    public let url: URL
    public let name: String
    public let totalCapacity: Int64
    /// Free space right now, not counting purgeable data.
    public let availableCapacity: Int64
    /// Free space including purgeable data macOS can clear on demand (what Finder shows).
    public let availableForImportantUsage: Int64
    public let kind: Kind
    public let isEjectable: Bool
    public let isReadOnly: Bool
    /// File system, e.g. "APFS" or "ExFAT".
    public let format: String?

    public var id: URL { url }
    public var isStartup: Bool { kind == .startup }
    public var usedCapacity: Int64 { max(0, totalCapacity - availableForImportantUsage) }
    public var purgeableCapacity: Int64 { max(0, availableForImportantUsage - availableCapacity) }
    public var usedFraction: Double {
        totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0
    }

    static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey,
        .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey, .volumeURLKey,
    ]

    public static func forVolume(containing url: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: keys)
        return VolumeInfo(volumeURL: values.volume ?? url, values: values)
    }

    /// All user-visible mounted volumes, startup disk first, then by name.
    public static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var volumes = urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsBrowsable != false else { return nil }
            let info = VolumeInfo(volumeURL: url, values: values)
            return info.totalCapacity > 0 ? info : nil
        }
        if !volumes.contains(where: \.isStartup), let startup = try? forVolume() {
            volumes.append(startup)
        }
        return volumes.sorted { lhs, rhs in
            if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    init(volumeURL: URL, values: URLResourceValues) {
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        url = volumeURL
        name = values.volumeLocalizedName ?? values.volumeName ?? volumeURL.lastPathComponent
        totalCapacity = Int64(values.volumeTotalCapacity ?? 0)
        availableCapacity = available
        availableForImportantUsage = max(values.volumeAvailableCapacityForImportantUsage ?? 0, available)
        // External SSD enclosures report neither ejectable nor removable, but Finder still offers Eject.
        isEjectable = values.volumeIsRootFileSystem != true
            && (values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false)
        isReadOnly = values.volumeIsReadOnly == true
        format = values.volumeLocalizedFormatDescription

        if values.volumeIsRootFileSystem == true {
            kind = .startup
        } else if values.volumeIsLocal == false {
            kind = .network
        } else if values.volumeIsInternal == true {
            kind = .internalDisk
        } else if format?.localizedCaseInsensitiveContains("image") == true {
            kind = .diskImage
        } else {
            kind = .external
        }
    }

    /// Memberwise initializer for tests and previews.
    public init(
        url: URL, name: String, totalCapacity: Int64, availableCapacity: Int64, availableForImportantUsage: Int64,
        kind: Kind, isEjectable: Bool = false, isReadOnly: Bool = false, format: String? = nil
    ) {
        self.url = url
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.kind = kind
        self.isEjectable = isEjectable
        self.isReadOnly = isReadOnly
        self.format = format
    }

    /// The volume a path lives on: the one with the longest matching mount path.
    public static func volume(containing url: URL, in volumes: [VolumeInfo]) -> VolumeInfo? {
        let path = url.normalizedPath
        return volumes
            .filter { path == $0.url.normalizedPath || path.hasPrefix($0.url.normalizedPath == "/" ? "/" : $0.url.normalizedPath + "/") }
            .max { $0.url.normalizedPath.count < $1.url.normalizedPath.count }
    }
}
