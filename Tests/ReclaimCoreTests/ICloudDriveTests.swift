import Foundation
import Testing
@testable import ReclaimCore

/// An in-memory iCloud Drive, so tests never touch real iCloud files.
private final class FakeICloud: ICloudFileSystem, @unchecked Sendable {
    let root = URL(filePath: "/Fake/Mobile Documents", directoryHint: .isDirectory)
    private let lock = NSLock()
    private var children: [String: [URL]] = [:]
    private var metadata: [String: ICloudFileMetadata] = [:]
    private var names: [String: String] = [:]
    private(set) var evicted: [URL] = []

    init() {
        children[root.normalizedPath] = []
    }

    @discardableResult
    func folder(_ path: String, localizedName: String? = nil) -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        add(url, ICloudFileMetadata(isDirectory: true))
        children[url.normalizedPath] = children[url.normalizedPath] ?? []
        if let localizedName { names[url.normalizedPath] = localizedName }
        return url
    }

    @discardableResult
    func file(_ path: String, _ metadata: ICloudFileMetadata) -> URL {
        let url = root.appending(path: path)
        add(url, metadata)
        if metadata.isDirectory { children[url.normalizedPath] = children[url.normalizedPath] ?? [] }
        return url
    }

    func update(_ url: URL, _ change: (inout ICloudFileMetadata) -> Void) {
        lock.withLock {
            if var value = metadata[url.normalizedPath] {
                change(&value)
                metadata[url.normalizedPath] = value
            }
        }
    }

    private func add(_ url: URL, _ value: ICloudFileMetadata) {
        lock.withLock {
            metadata[url.normalizedPath] = value
            let parent = url.deletingLastPathComponent().normalizedPath
            if !(children[parent] ?? []).contains(url) { children[parent, default: []].append(url) }
        }
    }

    func fileExists(at url: URL) -> Bool {
        lock.withLock { metadata[url.normalizedPath] != nil || children[url.normalizedPath] != nil }
    }

    func contents(of directory: URL) throws -> [URL] {
        try lock.withLock {
            guard let urls = children[directory.normalizedPath] else { throw CocoaError(.fileReadNoSuchFile) }
            return urls
        }
    }

    func metadata(for url: URL) -> ICloudFileMetadata? {
        lock.withLock { metadata[url.normalizedPath] }
    }

    func localizedName(of url: URL) -> String? {
        lock.withLock { names[url.normalizedPath] }
    }

    func evict(_ url: URL) throws {
        lock.withLock {
            evicted.append(url)
            metadata[url.normalizedPath]?.downloadState = .notDownloaded
            metadata[url.normalizedPath]?.allocatedSize = 0
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func old(_ size: Int64 = 1_000, days: Double = 100) -> ICloudFileMetadata {
    ICloudFileMetadata(allocatedSize: size, contentAccessDate: daysAgo(days), modificationDate: daysAgo(days + 10))
}

@Suite struct ICloudEligibilityTests {
    @Test func onlyDownloadedUploadedUnusedFilesAreEligible() {
        #expect(ICloudDrive.ineligibility(of: old(), unusedFor: 60, now: now) == nil)

        var metadata = old()
        metadata.downloadState = .downloaded
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == nil)

        metadata = old(); metadata.isUbiquitous = false
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .notInICloud)

        metadata = old(); metadata.downloadState = .notDownloaded
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .notDownloaded)

        metadata = old(); metadata.downloadState = .unknown
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .notDownloaded)

        metadata = old(); metadata.isUploaded = false
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .notUploaded)

        metadata = old(); metadata.isUploading = true
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .uploading)

        metadata = old(); metadata.isSymbolicLink = true
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .symbolicLink)

        metadata = old(0)
        #expect(ICloudDrive.ineligibility(of: metadata, unusedFor: 60, now: now) == .empty)
    }

    @Test func ageUsesTheLaterOfAccessAndModification() {
        // Opened long ago but edited recently: not unused.
        let edited = ICloudFileMetadata(allocatedSize: 1, contentAccessDate: daysAgo(200), modificationDate: daysAgo(5))
        #expect(edited.lastUsed == daysAgo(5))
        #expect(ICloudDrive.ineligibility(of: edited, unusedFor: 60, now: now) == .usedRecently)

        // No access date: falls back to the modification date.
        let modifiedOnly = ICloudFileMetadata(allocatedSize: 1, modificationDate: daysAgo(90))
        #expect(ICloudDrive.ineligibility(of: modifiedOnly, unusedFor: 60, now: now) == nil)
        #expect(ICloudDrive.ineligibility(of: modifiedOnly, unusedFor: 180, now: now) == .usedRecently)

        let unknown = ICloudFileMetadata(allocatedSize: 1)
        #expect(ICloudDrive.ineligibility(of: unknown, unusedFor: 30, now: now) == .unknownLastUse)
    }

    @Test func fallbackNamesComeFromContainerIdentifiers() {
        #expect(ICloudDrive.fallbackName(forFolderNamed: "com~apple~CloudDocs") == "iCloud Drive")
        #expect(ICloudDrive.fallbackName(forFolderNamed: "iCloud~com~vendor~notes") == "Notes")
        #expect(ICloudDrive.fallbackName(forFolderNamed: "57T9237FN3~net~whatsapp~WhatsApp") == "WhatsApp")
        #expect(ICloudDrive.fallbackName(forFolderNamed: "com~apple~Pages") == "Pages")
        #expect(ICloudDrive.fallbackName(forFolderNamed: "plain") == "Plain")
    }
}

@Suite struct ICloudScanTests {
    private func makeDrive() -> FakeICloud {
        let fake = FakeICloud()
        fake.folder("com~apple~CloudDocs")
        fake.folder("iCloud~com~vendor~App", localizedName: "\u{200E}Vendor App")
        fake.folder("ABCDE12345~com~other~Thing")

        fake.file("com~apple~CloudDocs/old.pdf", old(5_000))
        fake.file("com~apple~CloudDocs/Documents", ICloudFileMetadata(isDirectory: true))
        fake.file("com~apple~CloudDocs/Documents/report.docx", old(2_000, days: 70))
        fake.file("com~apple~CloudDocs/Documents/recent.txt", old(9_000, days: 3))
        fake.file("com~apple~CloudDocs/Documents/cloud-only.mov", {
            var metadata = old(0); metadata.downloadState = .notDownloaded; return metadata
        }())
        fake.file("com~apple~CloudDocs/Documents/uploading.zip", {
            var metadata = old(7_000); metadata.isUploading = true; metadata.isUploaded = false; return metadata
        }())
        fake.file("com~apple~CloudDocs/.DS_Store", old(4_000))
        fake.file("com~apple~CloudDocs/link", { var metadata = old(10); metadata.isSymbolicLink = true; return metadata }())
        // A package is one item; its contents are never listed.
        fake.file("com~apple~CloudDocs/Talk.key", ICloudFileMetadata(isDirectory: true, isPackage: true, allocatedSize: 30_000, contentAccessDate: daysAgo(400)))
        fake.file("com~apple~CloudDocs/Talk.key/Data/image.png", old(29_000))

        fake.file("iCloud~com~vendor~App/Documents", ICloudFileMetadata(isDirectory: true))
        fake.file("iCloud~com~vendor~App/Documents/big.db", old(50_000, days: 200))
        // App data outside Documents is private to the app and never listed.
        fake.file("iCloud~com~vendor~App/Library", ICloudFileMetadata(isDirectory: true))
        fake.file("iCloud~com~vendor~App/Library/cache.db", old(80_000, days: 300))
        fake.file("ABCDE12345~com~other~Thing/settings.plist", old(100, days: 300))
        fake.file("ABCDE12345~com~other~Thing/Documents", ICloudFileMetadata(isDirectory: true))
        fake.file("ABCDE12345~com~other~Thing/Documents/notes.txt", old(100, days: 10))
        return fake
    }

    @Test func listsOnlyDownloadedUploadedItemsAndTreatsPackagesAsOne() {
        let fake = makeDrive()
        let drive = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions())
        #expect(drive.availability == .available)

        let scan = drive.scan()
        let names = Set(scan.candidates.map(\.name))
        #expect(names == ["old.pdf", "report.docx", "recent.txt", "Talk.key", "big.db", "notes.txt"])
        #expect(scan.candidates.first { $0.name == "Talk.key" }?.isPackage == true)
        #expect(scan.candidates.first { $0.name == "Talk.key" }?.size == 30_000)
        #expect(scan.candidates.first { $0.name == "report.docx" }?.subfolderPath == "Documents")
        #expect(scan.candidates.first { $0.name == "old.pdf" }?.subfolderPath == "")
        #expect(scan.candidates.first { $0.name == "big.db" }?.subfolderPath == "")
    }

    @Test func groupsByFolderWithFriendlyNamesAndFiltersByAge() {
        let fake = makeDrive()
        let scan = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions()).scan()

        let groups = scan.groups(unusedFor: 60, now: now)
        #expect(groups.map(\.folder.name) == ["iCloud Drive", "Vendor App"])
        #expect(groups[0].items.map(\.name) == ["Talk.key", "old.pdf", "report.docx"])
        #expect(groups[0].totalSize == 37_000)
        #expect(groups[1].totalSize == 50_000)

        let strict = scan.groups(unusedFor: 180, now: now)
        #expect(strict.flatMap(\.items).map(\.name).sorted() == ["Talk.key", "big.db"])

        let loose = scan.groups(unusedFor: 7, now: now)
        #expect(loose.map(\.folder.name) == ["iCloud Drive", "Vendor App", "Thing"])
    }

    @Test func scanHonorsExclusions() {
        let fake = makeDrive()
        var exclusions = Exclusions()
        exclusions.add(fake.root.appending(path: "iCloud~com~vendor~App/Documents"))
        let scan = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: exclusions).scan()
        #expect(!scan.candidates.contains { $0.name == "big.db" })
    }

    @Test func unavailableWithoutICloudDrive() {
        let fake = FakeICloud()
        fake.folder("com~apple~Pages")
        #expect(ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions()).availability == .unavailable)
    }
}

@Suite struct ICloudEvictionTests {
    @Test func evictsEligibleItems() throws {
        let fake = FakeICloud()
        fake.folder("com~apple~CloudDocs")
        fake.file("com~apple~CloudDocs/a.pdf", old(1_000))
        fake.file("com~apple~CloudDocs/b.pdf", old(2_000))
        let drive = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions())

        let items = drive.scan().groups(unusedFor: 60, now: now).flatMap(\.items)
        let report = drive.evict(items, unusedFor: 60, now: now)
        #expect(report.failures.isEmpty)
        #expect(report.bytesFreed == 3_000)
        #expect(fake.evicted.count == 2)
    }

    @Test func rechecksEachItemRightBeforeEvicting() throws {
        let fake = FakeICloud()
        fake.folder("com~apple~CloudDocs")
        let opened = fake.file("com~apple~CloudDocs/opened.pdf", old())
        let edited = fake.file("com~apple~CloudDocs/edited.pdf", old())
        let gone = fake.file("com~apple~CloudDocs/gone.pdf", old())
        let fine = fake.file("com~apple~CloudDocs/fine.pdf", old())
        let drive = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions())
        let items = drive.scan().candidates

        // Things change between the scan and the click.
        fake.update(opened) { $0.contentAccessDate = daysAgo(1) }
        fake.update(edited) { $0.isUploading = true; $0.isUploaded = false }
        fake.update(gone) { $0.downloadState = .notDownloaded }

        let report = drive.evict(items, unusedFor: 60, now: now)
        #expect(fake.evicted == [fine])
        #expect(report.evicted.map(\.url) == [fine])
        #expect(report.failures.count == 3)
    }

    @Test func refusesPathsOutsideICloudAndExcludedItems() throws {
        let fake = FakeICloud()
        let folder = fake.folder("com~apple~CloudDocs")
        let excluded = fake.file("com~apple~CloudDocs/keep.pdf", old())
        var exclusions = Exclusions()
        exclusions.add(excluded)
        let drive = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: exclusions)

        let appFolder = fake.folder("iCloud~com~vendor~App")
        let appData = fake.file("iCloud~com~vendor~App/data.sqlite", old())
        let privateData = ICloudItem(url: appData, folder: appFolder, size: 1, lastUsed: daysAgo(100))
        let outside = ICloudItem(url: URL(filePath: "/Users/me/Documents/x.pdf"), folder: folder, size: 1, lastUsed: daysAgo(100))
        let sneaky = ICloudItem(url: fake.root.appending(path: "com~apple~CloudDocs/../../etc/passwd"), folder: folder, size: 1, lastUsed: daysAgo(100))
        let topLevel = ICloudItem(url: folder, folder: folder, size: 1, lastUsed: daysAgo(100))
        let keep = ICloudItem(url: excluded, folder: folder, size: 1, lastUsed: daysAgo(100))

        let report = drive.evict([outside, sneaky, topLevel, keep, privateData], unusedFor: 60, now: now)
        #expect(report.evicted.isEmpty)
        #expect(report.failures.count == 5)
        #expect(fake.evicted.isEmpty)
    }

    @Test func dryRunDoesNotEvict() {
        let fake = FakeICloud()
        fake.folder("com~apple~CloudDocs")
        fake.file("com~apple~CloudDocs/a.pdf", old())
        let drive = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions())
        let report = drive.evict(drive.scan().candidates, unusedFor: 60, now: now, dryRun: true)
        #expect(report.evicted.count == 1)
        #expect(fake.evicted.isEmpty)
    }

    @Test func removingItemsUpdatesTheScan() {
        let fake = FakeICloud()
        fake.folder("com~apple~CloudDocs")
        let a = fake.file("com~apple~CloudDocs/a.pdf", old(1_000))
        fake.file("com~apple~CloudDocs/b.pdf", old(2_000))
        let scan = ICloudDrive(root: fake.root, fileSystem: fake, exclusions: Exclusions()).scan()
        #expect(scan.downloadedSize == 3_000)
        #expect(scan.removing([a]).downloadedSize == 2_000)
    }
}
