import Foundation
import Testing
@testable import ReclaimCore

private func makeDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int = 4_096) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Suite struct SelectorTests {
    @Test func olderVersionsKeepsNewestPerProduct() {
        let selector = ItemSelector.olderVersions(pattern: #"([A-Za-z]+)(\d{4}\.\d+)"#)
        let old = selector.select(["IntelliJIdea2024.1", "IntelliJIdea2024.3", "IntelliJIdea2023.2", "PyCharm2025.1", "consentOptions", "options"])
        #expect(old == ["IntelliJIdea2024.1", "IntelliJIdea2023.2"])
    }

    @Test func olderVersionsComparesNumerically() {
        let selector = ItemSelector.olderVersions(pattern: #"(.+?)-(\d+\.\d+\.\d+.*)"#)
        let old = selector.select([
            "ms-python.python-2024.10.1", "ms-python.python-2024.9.0", "ms-python.python-2024.2.1",
            "esbenp.prettier-vscode-11.0.0", "extensions.json", ".obsolete",
        ])
        #expect(old == ["ms-python.python-2024.9.0", "ms-python.python-2024.2.1"])
    }

    @Test func nameFilterMatchesExtensionsOrPatterns() {
        let filter = NameFilter(extensions: ["dmg", "pkg"], patterns: [#"Install macOS .+\.app"#])
        #expect(filter.matches("Zed.dmg"))
        #expect(filter.matches("Setup.PKG"))
        #expect(filter.matches("Install macOS Sequoia.app"))
        #expect(!filter.matches("Zed.app"))
        #expect(!filter.matches("notes.txt"))

        let downloads = NameFilter(excludedExtensions: ["dmg"])
        #expect(downloads.matches("photo.jpg"))
        #expect(!downloads.matches("old.dmg"))
    }

    @Test func cleanerRefusesItemsTheSelectorWouldNotPick() throws {
        let root = try makeDirectory("ReclaimSelector")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Zed.app")
        try write(app.appending(path: "Contents/x"))

        let category = CleanupCategory(
            id: "t", name: "T", summary: "", group: .personal, safety: .review, roots: [root],
            selector: .matching(NameFilter(extensions: ["dmg"], patterns: [#"Install macOS .+\.app"#]))
        )
        #expect(Scanner(exclusions: Exclusions()).scan(category).items.isEmpty)
        let report = Cleaner(exclusions: Exclusions()).clean([CleanupItem(url: app, size: 1, modified: nil)], in: category, method: .deletePermanently)
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: app.path))
    }
}

@Suite struct ExclusionListTests {
    @Test func excludesPathsAndTheirContents() {
        var exclusions = Exclusions()
        exclusions.add(URL(filePath: "/Users/me/Library/Caches/com.spotify.client"))
        #expect(exclusions.excludes(URL(filePath: "/Users/me/Library/Caches/com.spotify.client")))
        #expect(exclusions.excludes(URL(filePath: "/Users/me/Library/Caches/com.spotify.client/Data")))
        #expect(!exclusions.excludes(URL(filePath: "/Users/me/Library/Caches/com.spotify.client2")))
        exclusions.remove("/Users/me/Library/Caches/com.spotify.client")
        #expect(exclusions.paths.isEmpty)
    }

    @Test func scannerAndCleanerHonorExclusions() throws {
        let root = try makeDirectory("ReclaimExclusions")
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appending(path: "keep-me")
        try write(kept.appending(path: "f"))
        try write(root.appending(path: "other/f"))

        var exclusions = Exclusions()
        exclusions.add(kept)
        let category = CleanupCategory(id: "t", name: "T", summary: "", group: .system, safety: .safe, roots: [root])

        #expect(Scanner(exclusions: exclusions).scan(category).items.map(\.name) == ["other"])
        let report = Cleaner(exclusions: exclusions).clean([CleanupItem(url: kept, size: 1, modified: nil)], in: category, method: .deletePermanently)
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}

@Suite struct TrashLedgerTests {
    @Test func putsTrashedItemsBack() throws {
        let root = try makeDirectory("ReclaimUndo")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "cache/item.bin")
        try write(file)

        let category = CleanupCategory(id: "t", name: "T", summary: "", group: .system, safety: .safe, roots: [root.appending(path: "cache")])
        let report = Cleaner(exclusions: Exclusions()).clean([CleanupItem(url: file, size: 4_096, modified: nil)], in: category, method: .moveToTrash)
        #expect(report.trashed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let ledger = TrashLedger(file: root.appending(path: "ledger.json"))
        ledger.record(title: "Test cleanup", records: report.trashed)
        let batch = try #require(ledger.batches().first)
        #expect(batch.title == "Test cleanup")
        #expect(batch.totalSize == 4_096)

        let result = ledger.putBack(batch.id)
        #expect(result.restored.count == 1)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(ledger.batches().isEmpty)
    }

    @Test func dropsBatchesWhoseItemsAreGone() throws {
        let root = try makeDirectory("ReclaimUndoGone")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = TrashLedger(file: root.appending(path: "ledger.json"))
        ledger.record(title: "Gone", records: [
            TrashRecord(original: root.appending(path: "a"), trashed: root.appending(path: "missing"), size: 1),
        ])
        #expect(ledger.batches().isEmpty)
    }
}

@Suite struct NewCategoryTests {
    @Test func installersAndOldDownloadsDoNotDoubleCount() {
        let categories = CategoryCatalog.all(home: URL(filePath: "/Users/test", directoryHint: .isDirectory))
        let installers = categories.first { $0.id == "installers" }!
        let downloads = categories.first { $0.id == "old-downloads" }!
        for name in ["Zed.dmg", "Setup.pkg", "iPhone.ipsw", "photo.jpg", "Install macOS Tahoe.app"] {
            let inBoth = installers.selector.allows(name) && downloads.selector.allows(name)
            #expect(!inBoth, "\(name) would be counted twice")
        }
    }
}
