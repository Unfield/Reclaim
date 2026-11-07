import Darwin
import Foundation
import Testing
@testable import ReclaimCore

private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ReclaimDuplicates-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deterministic, non-repeating content so chunks at different offsets differ.
private func content(_ count: Int, seed: UInt8 = 1) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        var value = UInt32(seed) &* 2_654_435_761
        for index in 0..<count {
            value = value &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: value >> 24)
        }
    }
    return data
}

@discardableResult
private func write(_ data: Data, to url: URL, modified: Date? = nil) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    if let modified {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    return url
}

private func finder(minimumSize: Int64 = 1, exclusions: Exclusions = Exclusions()) -> DuplicateFinder {
    DuplicateFinder(options: .init(minimumSize: minimumSize), exclusions: exclusions)
}

private func paths(_ group: DuplicateGroup) -> Set<String> { Set(group.files.map(\.url.normalizedPath)) }

/// Comparable form of a digest.
private struct SHA256DigestString: Equatable {
    let value: String
    init(_ digest: some Sequence<UInt8>) { value = digest.map { String(format: "%02x", $0) }.joined() }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

/// Stands in for the real Trash so tests never touch the user's.
private func fakeTrash(in root: URL) throws -> (URL, Int64) throws -> TrashRecord {
    let bin = root.appending(path: "_trash", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    return { url, size in
        let destination = bin.appending(path: UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        return TrashRecord(original: url, trashed: destination, size: size)
    }
}

@Suite struct DuplicateFinderTests {
    @Test func findsIdenticalFilesInDifferentFolders() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(400_000)
        let a = try write(data, to: root.appending(path: "One/movie.mov"))
        let b = try write(data, to: root.appending(path: "Two/Nested/movie copy.mov"))
        try write(content(400_000, seed: 2), to: root.appending(path: "Two/other.mov"))

        let result = try finder().find(in: [root])
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(paths(group) == [a.normalizedPath, b.normalizedPath])
        #expect(group.size == 400_000)
        #expect(group.wastedSpace == 400_000)
        #expect(result.filesExamined == 3)
    }

    @Test func groupsSmallFilesAndSortsByWastedSpace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let small = content(10_000, seed: 3)
        for index in 0..<3 { try write(small, to: root.appending(path: "small\(index).txt")) }
        let large = content(200_000, seed: 4)
        for index in 0..<2 { try write(large, to: root.appending(path: "large\(index).bin")) }

        let groups = try finder().find(in: [root]).groups
        #expect(groups.map(\.files.count) == [2, 3])
        #expect(groups.map(\.wastedSpace) == [200_000, 20_000])
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(content(50_000, seed: 1), to: root.appending(path: "a"))
        try write(content(50_000, seed: 2), to: root.appending(path: "b"))
        try write(content(500_000, seed: 1), to: root.appending(path: "c"))
        try write(content(500_000, seed: 2), to: root.appending(path: "d"))
        #expect(try finder().find(in: [root]).groups.isEmpty)
    }

    @Test func sameEndsButDifferentMiddleIsNotADuplicate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = content(1_000_000)
        var changed = original
        changed[500_000] ^= 0xFF
        let a = try write(original, to: root.appending(path: "a"))
        let b = try write(changed, to: root.appending(path: "b"))

        // The quick check alone can't tell them apart…
        let finder = finder()
        let buffer = try #require(ReadBuffer(byteCount: 1 << 16))
        defer { buffer.deallocate() }
        func quick(_ url: URL) throws -> SHA256DigestString {
            let info = try #require(FileInfo(url))
            var file = DuplicateFile(url: url, size: info.size, modified: info.modified, created: info.created, device: info.identity.device, inode: info.identity.inode)
            return SHA256DigestString(try finder.quickDigest(of: &file, buffer: buffer))
        }
        #expect(try quick(a) == quick(b))
        // …so the full hash must.
        #expect(try finder.find(in: [root]).groups.isEmpty)
    }

    @Test func hardLinksAreTheSameFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(300_000)
        let original = try write(data, to: root.appending(path: "a/original"))
        try FileManager.default.createDirectory(at: root.appending(path: "b"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: root.appending(path: "b/hardlink"))
        #expect(try finder().find(in: [root]).groups.isEmpty)

        // A real copy is a duplicate, but the hard link still only counts once.
        try write(data, to: root.appending(path: "c/copy"))
        let groups = try finder().find(in: [root]).groups
        #expect(groups.count == 1)
        #expect(groups.first?.files.count == 2)
    }

    @Test func overlappingRootsDontDoubleCount() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(20_000)
        try write(data, to: root.appending(path: "sub/a"))
        try write(data, to: root.appending(path: "sub/b"))
        let groups = try finder().find(in: [root, root.appending(path: "sub")]).groups
        #expect(groups.count == 1)
        #expect(groups.first?.files.count == 2)
    }

    @Test func respectsMinimumSize() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let small = content(1_000)
        try write(small, to: root.appending(path: "a"))
        try write(small, to: root.appending(path: "b"))
        #expect(try finder(minimumSize: 1_001).find(in: [root]).groups.isEmpty)
        #expect(try finder(minimumSize: 1_000).find(in: [root]).groups.count == 1)
    }

    @Test func skipsHiddenFilesSymlinksAndPackages() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(30_000)
        let visible = try write(data, to: root.appending(path: "visible"))
        try write(data, to: root.appending(path: ".hidden"))
        try write(data, to: root.appending(path: ".git/objects/blob"))
        try write(data, to: root.appending(path: "Some.app/Contents/Resources/blob"))
        try write(data, to: root.appending(path: "node_modules/pkg/blob"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: visible)
        #expect(try finder().find(in: [root]).groups.isEmpty)
    }

    @Test func honorsExclusionsAndProtectedLocations() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(30_000)
        try write(data, to: root.appending(path: "a"))
        try write(data, to: root.appending(path: "Excluded/b"))
        #expect(try finder(exclusions: Exclusions(paths: [root.appending(path: "Excluded").normalizedPath])).find(in: [root]).groups.isEmpty)
        #expect(try finder().find(in: [root]).groups.count == 1)

        let home = URL(filePath: "/Users/someone")
        #expect(DuplicateFinder.isProtected(URL(filePath: "/System/Library/foo"), home: home))
        #expect(DuplicateFinder.isProtected(URL(filePath: "/usr/lib/x"), home: home))
        #expect(DuplicateFinder.isProtected(URL(filePath: "/Users/someone/Library/Caches/x"), home: home))
        #expect(!DuplicateFinder.isProtected(URL(filePath: "/Users/someone/Documents/x"), home: home))
        #expect(!DuplicateFinder.isProtected(URL(filePath: "/SystemStuff/x"), home: home))
        #expect(!DuplicateFinder.isProtected(root, home: home))

        // Searching a whole disk doesn't wander into temporary files or other disks…
        #expect(DuplicateFinder.isOffLimitsDuringDescent(URL(filePath: "/private"), root: URL(filePath: "/")))
        #expect(DuplicateFinder.isOffLimitsDuringDescent(URL(filePath: "/Volumes"), root: URL(filePath: "/")))
        #expect(!DuplicateFinder.isOffLimitsDuringDescent(URL(filePath: "/Users"), root: URL(filePath: "/")))
        // …but a folder the user picked inside them is fine.
        #expect(!DuplicateFinder.isOffLimitsDuringDescent(URL(filePath: "/Volumes"), root: URL(filePath: "/Volumes/Backup")))
        #expect(!DuplicateFinder.isOffLimitsDuringDescent(URL(filePath: "/private"), root: URL(filePath: "/private/var/folders/x")))
        #expect(DuplicateFinder.isOffLimitsDuringDescent(URL(filePath: "/tmp"), root: URL(filePath: "/")))
    }

    @Test func detectsAPFSClones() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try write(content(300_000), to: root.appending(path: "original"))
        let clone = root.appending(path: "clone")
        guard clonefile(original.path, clone.path, 0) == 0 else { return } // Not APFS; nothing to test.
        let copy = try write(content(300_000), to: root.appending(path: "copy"))

        let group = try #require(try finder().find(in: [root]).groups.first)
        #expect(group.files.count == 3)
        #expect(group.hasClones)
        let files = Dictionary(uniqueKeysWithValues: group.files.map { ($0.url.lastPathComponent, $0) })
        let cloned = try #require(files["clone"]).url
        let copied = try #require(files["copy"]).url
        #expect(copied.normalizedPath == copy.normalizedPath)
        #expect(try group.sharesStorage(#require(files["clone"])))
        #expect(try !group.sharesStorage(#require(files["copy"])))
        // Removing a clone while its twin stays frees nothing; removing the real copy frees its size.
        #expect(group.estimatedSavings(removing: [cloned]) == 0)
        #expect(group.estimatedSavings(removing: [copied]) == 300_000)
        #expect(group.estimatedSavings(removing: [copied, cloned]) == 300_000)
        #expect(group.wastedSpace == 600_000)
    }

    @Test func reportsProgressAndCanBeCancelled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(400_000)
        try write(data, to: root.appending(path: "a"))
        try write(data, to: root.appending(path: "b"))

        let last = LockedBox<DuplicateScanProgress?>(nil)
        _ = try finder().find(in: [root]) { progress in last.set(progress) }
        let final = try #require(last.value)
        #expect(final.phase == .verifying)
        #expect(final.bytesHashed == 800_000)
        #expect(final.bytesToHash == 800_000)
        #expect(final.fraction == 1)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try finder().find(in: [root])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct DuplicateSelectionTests {
    private func group(_ files: [(String, TimeInterval)]) -> DuplicateGroup {
        DuplicateGroup(id: "g", size: 100, files: files.enumerated().map { index, file in
            DuplicateFile(
                url: URL(filePath: file.0), size: 100, modified: Date(timeIntervalSince1970: file.1),
                created: nil, device: 1, inode: UInt64(index + 1), storageOffset: nil
            )
        })
    }

    @Test func keepRules() {
        let group = group([("/a/deep/folder/old.txt", 100), ("/b/new.txt", 300), ("/c/mid/mid.txt", 200)])
        #expect(group.keeper(for: .oldest)?.name == "old.txt")
        #expect(group.keeper(for: .newest)?.name == "new.txt")
        #expect(group.keeper(for: .shortestPath)?.name == "new.txt")

        let selection = DuplicateSelection(groups: [group], keeping: .oldest)
        #expect(Set(selection.urls.map(\.lastPathComponent)) == ["new.txt", "mid.txt"])
        #expect(selection.estimatedSavings(in: [group]) == 200)
    }

    @Test func keepRuleTieBreaksAreStable() {
        let group = group([("/x/long/b.txt", 100), ("/x/a.txt", 100), ("/y/a.txt", 100)])
        #expect(group.keeper(for: .oldest)?.url.path == "/x/a.txt")
        #expect(group.keeper(for: .newest)?.url.path == "/x/a.txt")
    }

    @Test func neverSelectsEveryCopy() {
        let group = group([("/a", 1), ("/b", 2), ("/c", 3)])
        var selection = DuplicateSelection(groups: [group], keeping: .oldest)
        let kept = group.files[0]
        #expect(!selection.contains(kept))
        let selectedLast = selection.set(kept, selected: true, in: group)
        #expect(!selectedLast)
        #expect(!selection.contains(kept))

        let deselected = selection.set(group.files[1], selected: false, in: group)
        let swapped = selection.set(kept, selected: true, in: group)
        let selectedAll = selection.set(group.files[1], selected: true, in: group)
        #expect(deselected && swapped && !selectedAll)
        #expect(selection.count(in: [group]) == 2)

        selection.keepOnly(group.files[2], in: group)
        #expect(selection.selectedFiles(in: group).map(\.url.path) == ["/a", "/b"])
        selection.setGroup(group, selected: false, keeping: .oldest)
        #expect(selection.isEmpty)
        #expect(group.estimatedSavings(removing: Set(group.files.map(\.url))) == 0)
    }

    @Test func pruningDropsRemovedFilesAndSingletonGroups() {
        let first = group([("/a", 1), ("/b", 2), ("/c", 3)])
        let remaining = DuplicateGroup.removing([URL(filePath: "/a")], from: [first])
        #expect(remaining.first?.files.map(\.url.path) == ["/b", "/c"])
        #expect(DuplicateGroup.removing([URL(filePath: "/a"), URL(filePath: "/b")], from: [first]).isEmpty)

        var selection = DuplicateSelection(groups: [first], keeping: .oldest)
        selection.prune(to: remaining)
        #expect(selection.urls.map(\.path).sorted() == ["/b", "/c"])
    }
}

@Suite struct DuplicateRemoverTests {
    private func scan(_ root: URL) throws -> DuplicateGroup {
        try #require(try finder().find(in: [root]).groups.first)
    }

    @Test func removesSelectedCopiesAndKeepsOne() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(200_000)
        let old = try write(data, to: root.appending(path: "a/old"), modified: Date(timeIntervalSince1970: 1_000_000))
        try write(data, to: root.appending(path: "b/new1"), modified: Date(timeIntervalSince1970: 2_000_000))
        try write(data, to: root.appending(path: "c/new2"), modified: Date(timeIntervalSince1970: 3_000_000))

        let group = try scan(root)
        let selection = DuplicateSelection(groups: [group], keeping: .oldest)
        let result = DuplicateRemover(exclusions: Exclusions()).remove(selection.urls, from: [group], mover: try fakeTrash(in: root))
        #expect(result.removed.count == 2)
        #expect(result.skipped.isEmpty)
        #expect(result.trashed.count == 2)
        #expect(result.bytesRemoved == 400_000)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(result.trashed.allSatisfy { FileManager.default.fileExists(atPath: $0.trashed.path) })
    }

    @Test func refusesToRemoveEveryCopy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(50_000)
        let a = try write(data, to: root.appending(path: "a"))
        let b = try write(data, to: root.appending(path: "b"))

        let group = try scan(root)
        let all = Set(group.files.map(\.url))
        let result = DuplicateRemover(exclusions: Exclusions()).remove(all, from: [group], mover: try fakeTrash(in: root))
        #expect(result.removed.isEmpty)
        #expect(result.skipped.map(\.reason) == [.wouldRemoveAllCopies, .wouldRemoveAllCopies])
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test func skipsFilesThatChangedOrVanished() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(150_000)
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try write(data, to: root.appending(path: "keep"), modified: Date(timeIntervalSince1970: 1_000_000_000))
        let resized = try write(data, to: root.appending(path: "resized"), modified: date)
        let touched = try write(data, to: root.appending(path: "touched"), modified: date)
        let vanished = try write(data, to: root.appending(path: "vanished"), modified: date)
        let replaced = try write(data, to: root.appending(path: "replaced"), modified: date)
        let unchanged = try write(data, to: root.appending(path: "unchanged"), modified: date)

        let group = try scan(root)
        let selection = DuplicateSelection(groups: [group], keeping: .oldest)
        #expect(selection.count(in: [group]) == 5)

        try write(data + Data([1]), to: resized, modified: date)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: touched.path)
        try FileManager.default.removeItem(at: vanished)
        // Same size and date, but a different file (e.g. replaced by a sync tool): a symlink now.
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: unchanged)

        let result = DuplicateRemover(exclusions: Exclusions()).remove(selection.urls, from: [group], mover: try fakeTrash(in: root))
        #expect(result.removed.map(\.name) == ["unchanged"])
        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.file.name, $0.reason) })
        #expect(reasons == ["resized": .changed, "touched": .changed, "vanished": .missing, "replaced": .notRegularFile])
        #expect(FileManager.default.fileExists(atPath: resized.path))
        #expect(FileManager.default.fileExists(atPath: touched.path))
    }

    @Test func skipsGroupWhenKeptCopyIsGone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(150_000)
        let keep = try write(data, to: root.appending(path: "keep"), modified: Date(timeIntervalSince1970: 1_000_000_000))
        let other = try write(data, to: root.appending(path: "other"), modified: Date(timeIntervalSince1970: 1_600_000_000))

        let group = try scan(root)
        let selection = DuplicateSelection(groups: [group], keeping: .oldest)
        try FileManager.default.removeItem(at: keep)

        let result = DuplicateRemover(exclusions: Exclusions()).remove(selection.urls, from: [group], mover: try fakeTrash(in: root))
        #expect(result.removed.isEmpty)
        #expect(result.skipped.map(\.reason) == [.keptCopyMissing])
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func dryRunAndExclusionsRemoveNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = content(20_000)
        try write(data, to: root.appending(path: "a"), modified: Date(timeIntervalSince1970: 1_000_000_000))
        let b = try write(data, to: root.appending(path: "b"), modified: Date(timeIntervalSince1970: 1_600_000_000))

        let group = try scan(root)
        let selection = DuplicateSelection(groups: [group], keeping: .oldest)
        let mover = try fakeTrash(in: root)

        let dry = DuplicateRemover(exclusions: Exclusions()).remove(selection.urls, from: [group], dryRun: true, mover: mover)
        #expect(dry.removed.count == 1)
        #expect(dry.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: b.path))

        let excluded = DuplicateRemover(exclusions: Exclusions(paths: [b.normalizedPath])).remove(selection.urls, from: [group], mover: mover)
        #expect(excluded.removed.isEmpty)
        #expect(excluded.skipped.map(\.reason) == [.excluded])
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}
