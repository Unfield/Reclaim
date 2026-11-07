import CryptoKit
import Darwin
import Foundation

// MARK: - Model

/// Which copy of a duplicate to keep when the others are selected for removal.
public enum DuplicateKeepRule: String, CaseIterable, Sendable {
    case oldest
    case newest
    case shortestPath = "shortest"

    public var title: String {
        switch self {
        case .oldest: "Oldest"
        case .newest: "Newest"
        case .shortestPath: "Shortest Path"
        }
    }

    /// True if `a` is a better copy to keep than `b`. Always a strict, total order so the choice is stable.
    func prefers(_ a: DuplicateFile, over b: DuplicateFile) -> Bool {
        switch self {
        case .oldest:
            if let order = Self.compareDates(a, b) { return order }
        case .newest:
            if let order = Self.compareDates(b, a) { return order }
        case .shortestPath:
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            if let order = Self.compareDates(a, b) { return order }
        }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.path < b.path
    }

    /// Modification date first (what the user sees), then creation date. Nil when they're equal.
    private static func compareDates(_ a: DuplicateFile, _ b: DuplicateFile) -> Bool? {
        if a.modified != b.modified { return a.modified < b.modified }
        if let ac = a.created, let bc = b.created, ac != bc { return ac < bc }
        return nil
    }
}

/// One copy of a duplicated file, with the facts needed to re-check it before removal.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    public let created: Date?
    let device: Int32
    let inode: UInt64
    /// Physical location of the first block on disk. Equal values on the same device mean the
    /// files are APFS clones that share storage.
    var storageOffset: Int64?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var folder: URL { url.deletingLastPathComponent() }
    var path: String { url.normalizedPath }

    var storageKey: StorageKey? { storageOffset.map { StorageKey(device: device, offset: $0) } }

    struct StorageKey: Hashable {
        let device: Int32
        let offset: Int64
    }
}

/// A set of files with identical contents.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public let id: String
    /// Size of each copy.
    public let size: Int64
    /// Every copy, sorted by path.
    public internal(set) var files: [DuplicateFile]

    init(id: String, size: Int64, files: [DuplicateFile]) {
        self.id = id
        self.size = size
        self.files = files.sorted { $0.path < $1.path }
    }

    /// Space used by the extra copies: size × (copies − 1).
    public var wastedSpace: Int64 { size * Int64(max(0, files.count - 1)) }

    /// The copy a rule would keep.
    public func keeper(for rule: DuplicateKeepRule) -> DuplicateFile? {
        files.min { rule.prefers($0, over: $1) }
    }

    /// True if this copy is an APFS clone of another copy in the group (they share storage).
    public func sharesStorage(_ file: DuplicateFile) -> Bool {
        guard let key = file.storageKey else { return false }
        return files.contains { $0.url != file.url && $0.storageKey == key }
    }

    public var hasClones: Bool { files.contains(where: sharesStorage) }

    /// Roughly how much space removing these copies frees. Clones only free space once no remaining
    /// copy shares their storage, and removing every copy is never allowed, so that counts as zero.
    public func estimatedSavings(removing urls: Set<URL>) -> Int64 {
        let removed = files.filter { urls.contains($0.url) }
        guard !removed.isEmpty, removed.count < files.count else { return 0 }
        var occupied = Set(files.filter { !urls.contains($0.url) }.compactMap(\.storageKey))
        var savings: Int64 = 0
        for file in removed {
            guard let key = file.storageKey else {
                savings += size
                continue
            }
            if occupied.insert(key).inserted { savings += size }
        }
        return savings
    }

    /// Drops removed files from the groups; groups left with a single copy disappear.
    public static func removing(_ urls: Set<URL>, from groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.compactMap { group in
            var group = group
            group.files.removeAll { urls.contains($0.url) }
            return group.files.count > 1 ? group : nil
        }
        .sorted(by: DuplicateGroup.isOrderedBefore)
    }

    /// Most wasted space first, with a stable tie-break.
    static func isOrderedBefore(_ a: DuplicateGroup, _ b: DuplicateGroup) -> Bool {
        if a.wastedSpace != b.wastedSpace { return a.wastedSpace > b.wastedSpace }
        return a.id < b.id
    }
}

/// The copies the user wants to remove. Enforces that at least one copy of every group remains.
public struct DuplicateSelection: Sendable, Equatable {
    public private(set) var urls: Set<URL> = []

    public init() {}

    /// Selects every copy except the one the rule keeps.
    public init(groups: [DuplicateGroup], keeping rule: DuplicateKeepRule) {
        apply(rule, to: groups)
    }

    public var isEmpty: Bool { urls.isEmpty }

    public func contains(_ file: DuplicateFile) -> Bool { urls.contains(file.url) }

    public mutating func apply(_ rule: DuplicateKeepRule, to groups: [DuplicateGroup]) {
        urls = []
        for group in groups { setGroup(group, selected: true, keeping: rule) }
    }

    /// Selects all copies but the kept one, or none.
    public mutating func setGroup(_ group: DuplicateGroup, selected: Bool, keeping rule: DuplicateKeepRule) {
        urls.subtract(group.files.map(\.url))
        guard selected, let keeper = group.keeper(for: rule) else { return }
        urls.formUnion(group.files.lazy.filter { $0.url != keeper.url }.map(\.url))
    }

    /// Selects or deselects one copy. Refuses (returns false) if that would select every copy.
    @discardableResult
    public mutating func set(_ file: DuplicateFile, selected: Bool, in group: DuplicateGroup) -> Bool {
        guard selected else {
            urls.remove(file.url)
            return true
        }
        let others = group.files.filter { $0.url != file.url }
        guard others.contains(where: { !urls.contains($0.url) }) else { return false }
        urls.insert(file.url)
        return true
    }

    /// Keeps only this copy and selects all others.
    public mutating func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        urls.subtract(group.files.map(\.url))
        urls.formUnion(group.files.lazy.filter { $0.url != file.url }.map(\.url))
    }

    public func selectedFiles(in group: DuplicateGroup) -> [DuplicateFile] {
        group.files.filter { urls.contains($0.url) }
    }

    public func count(in groups: [DuplicateGroup]) -> Int {
        groups.reduce(0) { $0 + selectedFiles(in: $1).count }
    }

    public func estimatedSavings(in groups: [DuplicateGroup]) -> Int64 {
        groups.reduce(0) { $0 + $1.estimatedSavings(removing: urls) }
    }

    /// Forgets files that are no longer part of any group.
    public mutating func prune(to groups: [DuplicateGroup]) {
        urls.formIntersection(groups.flatMap { $0.files.map(\.url) })
    }
}

public struct DuplicateScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Listing files and grouping them by size.
        case searching
        /// Comparing the beginning and end of same-size files.
        case comparing
        /// Hashing complete files that look identical.
        case verifying
    }

    public var phase: Phase = .searching
    /// Files looked at so far, of any size.
    public var filesExamined = 0
    /// Files compared or verified in the current phase.
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesHashed: Int64 = 0
    public var bytesToHash: Int64 = 0

    public init() {}

    /// Progress of the current phase, or nil while searching (the total isn't known yet).
    public var fraction: Double? {
        switch phase {
        case .searching: nil
        case .comparing: filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
        case .verifying: bytesToHash > 0 ? Double(bytesHashed) / Double(bytesToHash) : 0
        }
    }
}

public struct DuplicateScanResult: Sendable {
    /// Most wasted space first.
    public var groups: [DuplicateGroup]
    public var filesExamined: Int
    /// Files and folders that couldn't be read (often a missing Full Disk Access grant).
    public var unreadableCount: Int

    public var wastedSpace: Int64 { groups.reduce(0) { $0 + $1.wastedSpace } }
}

// MARK: - Finder

/// Finds files with identical contents: same size, then same first and last 64 KB, then the same
/// SHA-256 of the whole file. Hard links count as one file. Hidden files, packages (apps, photo
/// libraries…), symlinks and iCloud files that aren't downloaded are skipped.
public struct DuplicateFinder: Sendable {
    public struct Options: Sendable {
        public var minimumSize: Int64
        /// Folder names that are never descended into.
        public var skippedDirectoryNames: Set<String>

        public init(minimumSize: Int64 = 1_000_000, skippedDirectoryNames: Set<String> = ["node_modules", "Backups.backupdb"]) {
            self.minimumSize = minimumSize
            self.skippedDirectoryNames = skippedDirectoryNames
        }
    }

    public var options: Options
    private let exclusions: Exclusions
    private let home: URL

    static let quickChunkSize = 64 * 1024
    static let readBufferSize = 1 << 20

    public init(
        options: Options = Options(),
        exclusions: Exclusions = .load(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.options = options
        self.exclusions = exclusions
        self.home = home
    }

    /// Downloads, Documents and Desktop, if they exist.
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Downloads", "Documents", "Desktop"]
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
            .filter { isDirectory($0) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Locations that are never searched or cleaned: macOS itself, system and app support data.
    public static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.normalizedPath
        let protected = [
            "/System", "/Library", "/usr", "/bin", "/sbin", "/opt", "/dev", "/cores", "/etc",
            "/private/etc", "/private/var/db", "/private/var/root", "/private/var/vm",
            "/var/db", "/var/root", "/var/vm",
            home.appending(path: "Library").normalizedPath,
        ]
        return protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// System folders a search of a whole disk shouldn't wander into (temporary files, other disks),
    /// unless the user picked a folder inside them.
    static func isOffLimitsDuringDescent(_ directory: URL, root: URL) -> Bool {
        let path = directory.normalizedPath
        guard ["/private", "/var", "/tmp", "/Volumes"].contains(path) else { return false }
        let rootPath = root.normalizedPath
        return !(rootPath == path || rootPath.hasPrefix(path + "/"))
    }

    /// Searches the roots. Throws `CancellationError` if the calling task is cancelled.
    /// Progress is reported at most about ten times a second, from the calling thread.
    public func find(
        in roots: [URL],
        progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) throws -> DuplicateScanResult {
        // Never download iCloud placeholders just to compare them; reads fail instead.
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previousPolicy >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previousPolicy)
            }
        }

        var reporter = ProgressReporter(callback: progress)
        var unreadable = 0

        // 1. Group by size.
        let bySize = try enumerate(roots, reporter: &reporter, unreadable: &unreadable)
        let sameSize = bySize.values.filter { $0.count > 1 }.sorted { $0[0].size > $1[0].size }

        guard let buffer = ReadBuffer(byteCount: Self.readBufferSize) else {
            throw POSIXError(.ENOMEM)
        }
        defer { buffer.deallocate() }

        // 2. Group by a quick hash of the first and last 64 KB (the whole file if it's small).
        reporter.state.phase = .comparing
        reporter.state.filesTotal = sameSize.reduce(0) { $0 + $1.count }
        reporter.report(force: true)
        var quickGroups = [(digest: SHA256Digest, files: [DuplicateFile])]()
        for files in sameSize {
            var byDigest = [SHA256Digest: [DuplicateFile]]()
            for file in files {
                try Task.checkCancellation()
                var file = file
                do {
                    let digest = try quickDigest(of: &file, buffer: buffer)
                    byDigest[digest, default: []].append(file)
                } catch let error as ReadError {
                    if error == .unreadable { unreadable += 1 }
                }
                reporter.state.filesDone += 1
                reporter.report()
            }
            quickGroups += byDigest.filter { $0.value.count > 1 }.map { ($0.key, $0.value) }
        }

        // 3. Confirm with a SHA-256 of the whole file. Small files were already hashed completely.
        let isSmall = { (files: [DuplicateFile]) in files[0].size <= Int64(2 * Self.quickChunkSize) }
        var groups = quickGroups.filter { isSmall($0.files) }.map {
            DuplicateGroup(id: Self.groupID(size: $0.files[0].size, digest: $0.digest), size: $0.files[0].size, files: $0.files)
        }
        let needsFullHash = quickGroups.filter { !isSmall($0.files) }.map(\.files)

        reporter.state.phase = .verifying
        reporter.state.filesDone = 0
        reporter.state.filesTotal = needsFullHash.reduce(0) { $0 + $1.count }
        reporter.state.bytesToHash = needsFullHash.reduce(0) { $0 + $1[0].size * Int64($1.count) }
        reporter.report(force: true)
        for files in needsFullHash {
            var byDigest = [SHA256Digest: [DuplicateFile]]()
            for file in files {
                let start = reporter.state.bytesHashed
                do {
                    let digest = try fullDigest(of: file, buffer: buffer, reporter: &reporter)
                    byDigest[digest, default: []].append(file)
                } catch let error as ReadError {
                    if error == .unreadable { unreadable += 1 }
                }
                // Keep the total honest when a file was skipped or changed size.
                reporter.state.bytesHashed = start + file.size
                reporter.state.filesDone += 1
                reporter.report()
            }
            for (digest, matches) in byDigest where matches.count > 1 {
                groups.append(DuplicateGroup(id: Self.groupID(size: matches[0].size, digest: digest), size: matches[0].size, files: matches))
            }
        }
        reporter.report(force: true)

        return DuplicateScanResult(
            groups: groups.sorted(by: DuplicateGroup.isOrderedBefore),
            filesExamined: reporter.state.filesExamined,
            unreadableCount: unreadable
        )
    }

    // MARK: Enumeration

    private static let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .nameKey]

    private func enumerate(_ roots: [URL], reporter: inout ProgressReporter, unreadable: inout Int) throws -> [Int64: [DuplicateFile]] {
        let minimumSize = max(1, options.minimumSize)
        var bySize = [Int64: [DuplicateFile]]()
        var seen = Set<FileIdentity>()
        let errors = ErrorCounter()

        for root in roots {
            guard !Self.isProtected(root, home: home), !exclusions.excludes(root) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in errors.increment(); return true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else { continue }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if values.isPackage == true
                        || values.name.map(options.skippedDirectoryNames.contains) == true
                        || Self.isProtected(url, home: home)
                        || Self.isOffLimitsDuringDescent(url, root: root)
                        || exclusions.excludes(url) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }

                reporter.state.filesExamined += 1
                reporter.report()

                guard let info = FileInfo(url), info.isRegular, !info.isDataless, info.size >= minimumSize,
                      seen.insert(info.identity).inserted, // Hard links (and overlapping roots) are the same file.
                      !exclusions.excludes(url)
                else { continue }
                bySize[info.size, default: []].append(
                    DuplicateFile(url: url, size: info.size, modified: info.modified, created: info.created, device: info.identity.device, inode: info.identity.inode)
                )
            }
        }
        unreadable += errors.count
        return bySize
    }

    // MARK: Hashing

    enum ReadError: Error, Equatable {
        /// Couldn't be opened or read.
        case unreadable
        /// Changed since it was listed; ignore it.
        case changed
    }

    /// Hashes the first and last 64 KB (or the whole file if it's at most 128 KB), and records where its
    /// data lives on disk to detect APFS clones.
    func quickDigest(of file: inout DuplicateFile, buffer: ReadBuffer) throws -> SHA256Digest {
        let fd = try Self.open(file)
        defer { close(fd) }
        file.storageOffset = Self.physicalOffset(fd)

        var hasher = SHA256()
        let chunk = Self.quickChunkSize
        if file.size <= Int64(2 * chunk) {
            try Self.hash(fd, from: 0, length: file.size, into: &hasher, buffer: buffer)
        } else {
            try Self.hash(fd, from: 0, length: Int64(chunk), into: &hasher, buffer: buffer)
            try Self.hash(fd, from: file.size - Int64(chunk), length: Int64(chunk), into: &hasher, buffer: buffer)
        }
        return hasher.finalize()
    }

    /// Streams the whole file through SHA-256 without loading it into memory.
    private func fullDigest(of file: DuplicateFile, buffer: ReadBuffer, reporter: inout ProgressReporter) throws -> SHA256Digest {
        let fd = try Self.open(file)
        defer { close(fd) }
        var hasher = SHA256()
        try Self.hash(fd, from: 0, length: file.size, into: &hasher, buffer: buffer) { bytes in
            reporter.state.bytesHashed += Int64(bytes)
            reporter.report()
        }
        return hasher.finalize()
    }

    private static func open(_ file: DuplicateFile) throws -> Int32 {
        let fd = Darwin.open(file.url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? ReadError.changed : ReadError.unreadable }
        var info = stat()
        guard fstat(fd, &info) == 0, FileInfo(info).matches(file) else {
            close(fd)
            throw ReadError.changed
        }
        _ = fcntl(fd, F_NOCACHE, 1) // Don't push useful data out of the file cache.
        return fd
    }

    private static func hash(
        _ fd: Int32,
        from start: Int64,
        length: Int64,
        into hasher: inout SHA256,
        buffer: ReadBuffer,
        onRead: (Int) -> Void = { _ in }
    ) throws {
        var offset = start
        let end = start + length
        while offset < end {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(buffer.byteCount), end - offset))
            let count = pread(fd, buffer.base, wanted, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadError.unreadable
            }
            // A file that got shorter since it was listed isn't the file we compared.
            guard count > 0 else { throw ReadError.changed }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.base, count: count))
            offset += Int64(count)
            onRead(count)
        }
    }

    /// Where the file's first block is on the device, via `F_LOG2PHYS_EXT`. Nil if unknown.
    static func physicalOffset(_ fd: Int32) -> Int64? {
        var info = log2phys()
        info.l2p_contigbytes = 4096
        info.l2p_devoffset = 0
        guard fcntl(fd, F_LOG2PHYS_EXT, &info) == 0, info.l2p_devoffset > 0 else { return nil }
        return info.l2p_devoffset
    }

    static func groupID(size: Int64, digest: SHA256Digest) -> String {
        "\(size)-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Removal

/// Why a selected copy wasn't removed.
public enum DuplicateSkipReason: Error, Sendable, Equatable, LocalizedError {
    case wouldRemoveAllCopies
    case keptCopyMissing
    case missing
    case changed
    case notRegularFile
    case excluded
    case protectedLocation
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .wouldRemoveAllCopies: "Every copy was selected, so all were kept."
        case .keptCopyMissing: "The copy you're keeping is gone or has changed."
        case .missing: "It's no longer there."
        case .changed: "It changed since the scan."
        case .notRegularFile: "It's no longer a regular file."
        case .excluded: "It's on your exclusion list."
        case .protectedLocation: "It's in a protected location."
        case .failed(let message): message
        }
    }
}

public struct DuplicateRemovalResult: Sendable {
    public var removed: [DuplicateFile] = []
    public var skipped: [(file: DuplicateFile, reason: DuplicateSkipReason)] = []
    /// Records for "Put Back".
    public var trashed: [TrashRecord] = []

    public var bytesRemoved: Int64 { removed.reduce(0) { $0 + $1.size } }
}

/// Moves selected duplicates to the Trash after re-checking each one.
public struct DuplicateRemover: Sendable {
    private let exclusions: Exclusions
    private let home: URL

    public init(exclusions: Exclusions = .load(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.exclusions = exclusions
        self.home = home
    }

    /// For each group, keeps every unselected copy and trashes the selected ones, but only if:
    /// at least one copy stays and still exists unchanged, and each removed copy still has the size,
    /// modification date and identity it had when it was hashed. Anything else is skipped.
    public func remove(
        _ selection: Set<URL>,
        from groups: [DuplicateGroup],
        dryRun: Bool = false,
        mover: (URL, Int64) throws -> TrashRecord = { try Trash.move($0, size: $1) }
    ) -> DuplicateRemovalResult {
        var result = DuplicateRemovalResult()
        for group in groups {
            let selected = group.files.filter { selection.contains($0.url) }
            guard !selected.isEmpty else { continue }
            let kept = group.files.filter { !selection.contains($0.url) }

            guard !kept.isEmpty else {
                result.skipped += selected.map { ($0, .wouldRemoveAllCopies) }
                continue
            }
            guard kept.contains(where: { check($0) == nil }) else {
                result.skipped += selected.map { ($0, .keptCopyMissing) }
                continue
            }

            for file in selected {
                if let reason = check(file) {
                    result.skipped.append((file, reason))
                    continue
                }
                do {
                    if !dryRun { result.trashed.append(try mover(file.url, file.size)) }
                    result.removed.append(file)
                } catch {
                    result.skipped.append((file, .failed(error.localizedDescription)))
                }
            }
        }
        return result
    }

    /// Nil if the file is still exactly what was hashed and may be touched.
    func check(_ file: DuplicateFile) -> DuplicateSkipReason? {
        if DuplicateFinder.isProtected(file.url, home: home) { return .protectedLocation }
        if exclusions.excludes(file.url) { return .excluded }
        guard let info = FileInfo(file.url) else { return .missing }
        guard info.isRegular else { return .notRegularFile }
        return info.matches(file) ? nil : .changed
    }
}

// MARK: - Helpers

struct FileIdentity: Hashable {
    let device: Int32
    let inode: UInt64
}

/// `lstat` facts about a path (symlinks are reported as such, never followed).
struct FileInfo {
    let identity: FileIdentity
    let isRegular: Bool
    let isDataless: Bool
    let size: Int64
    let modified: Date
    let created: Date?

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        self.init(info)
    }

    init(_ info: stat) {
        identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        isRegular = (info.st_mode & S_IFMT) == S_IFREG
        isDataless = (info.st_flags & UInt32(SF_DATALESS)) != 0
        size = info.st_size
        modified = Self.date(info.st_mtimespec)
        created = info.st_birthtimespec.tv_sec > 0 ? Self.date(info.st_birthtimespec) : nil
    }

    func matches(_ file: DuplicateFile) -> Bool {
        isRegular && identity == FileIdentity(device: file.device, inode: file.inode)
            && size == file.size && modified == file.modified
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

/// A reusable read buffer, so hashing doesn't allocate per chunk.
struct ReadBuffer {
    let base: UnsafeMutableRawPointer
    let byteCount: Int

    init?(byteCount: Int) {
        guard byteCount > 0 else { return nil }
        base = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        self.byteCount = byteCount
    }

    func deallocate() { base.deallocate() }
}

/// Calls the progress callback at most every 0.1 s, so the UI isn't flooded.
private struct ProgressReporter {
    let callback: (@Sendable (DuplicateScanProgress) -> Void)?
    var state = DuplicateScanProgress()
    private var lastReport: UInt64 = 0

    init(callback: (@Sendable (DuplicateScanProgress) -> Void)?) {
        self.callback = callback
    }

    mutating func report(force: Bool = false) {
        guard let callback else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now - lastReport >= 100_000_000 else { return }
        lastReport = now
        callback(state)
    }
}

/// Counts enumeration errors from the enumerator's error handler.
private final class ErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
