import Foundation
import Testing
@testable import ReclaimCore

@Suite struct ToolParsingTests {
    @Test func parsesBinarySizes() {
        #expect(ByteSize.parse("1KB", binary: true) == 1_024)
        #expect(ByteSize.parse("34.6MB", binary: true) == 36_280_730)
    }

    @Test func parsesHomebrewDryRun() {
        let output = """
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--node.bottle.tar.gz (12.5MB)
        Would remove: /Users/me/Library/Caches/Homebrew/Cask/firefox.dmg (100MB)
        Would remove: /opt/homebrew/Cellar/node/20.1.0 (2,345 files, 50MB)
        Would remove (empty directory): /opt/homebrew/lib/gio
        Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.6 (1,707 files, 34.6MB)
        ==> This operation would free approximately 197.1MB of disk space.
        """
        let entries = HomebrewTool.parseCleanupDryRun(output, cachePath: "/Users/me/Library/Caches/Homebrew")
        #expect(entries.map(\.title) == ["Download cache", "Old versions", "Other files"])
        #expect(entries[0].size == ByteSize.parse("112.5MB", binary: true))
        #expect(entries[1].size == ByteSize.parse("50MB", binary: true))
        #expect(HomebrewTool.parseFreedSpace(output) == ByteSize.parse("197.1MB", binary: true))
    }

    @Test func parsesHomebrewAutoremove() {
        let output = "==> Would autoremove 2 unneeded formulae:\nlibfoo\nlibbar\n"
        #expect(HomebrewTool.parseAutoremoveDryRun(output) == ["libfoo", "libbar"])
    }

    @Test func parsesDockerSystemDF() {
        let output = """
        {"Active":"8","Reclaimable":"1.5GB (50%)","Size":"2.959GB","TotalCount":"10","Type":"Images"}
        {"Active":"8","Reclaimable":"8.192kB (0%)","Size":"4.321MB","TotalCount":"9","Type":"Containers"}
        {"Active":"8","Reclaimable":"0B (0%)","Size":"683.9MB","TotalCount":"10","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"20.53GB","Size":"20.67GB","TotalCount":"160","Type":"Build Cache"}
        """
        let entries = DockerTool.parseSystemDF(output)
        #expect(entries.count == 4)
        #expect(entries[0].size == 1_500_000_000)
        #expect(entries[0].optionID == "all-images")
        #expect(entries[1].size == 8_192)
        #expect(entries[3].size == 20_530_000_000)

        let status = ToolStatus(availability: .ready, entries: entries)
        #expect(status.reclaimable(options: ["build-cache"]) == 20_530_008_192)
        #expect(status.reclaimable(options: []) == 8_192)
    }

    @Test func parsesDockerReclaimed() {
        #expect(DockerTool.parseReclaimed("Deleted build cache objects:\nabc\n\nTotal reclaimed space: 2.5GB\n") == 2_500_000_000)
    }

    @Test func parsesSnapshots() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-07-101010.local
        com.apple.TimeMachine.2026-11-07-111523.local
        """
        let snapshots = TimeMachineTool.parseSnapshots(output)
        #expect(snapshots.map(\.dateToken) == ["2026-11-07-101010", "2026-11-07-111523"])
        #expect(snapshots.allSatisfy { $0.date != nil })
    }
}

@Suite struct ExclusionTests {
    @Test func excludedNamesAreSkippedAndProtected() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ReclaimExcl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let homebrew = root.appending(path: "Homebrew/file.bin")
        let other = root.appending(path: "Other/file.bin")
        for url in [homebrew, other] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5_000).write(to: url)
        }

        let category = CleanupCategory(
            id: "t", name: "T", summary: "", group: .system, safety: .safe, roots: [root], excludedNames: ["Homebrew"]
        )
        let scan = Scanner().scan(category)
        #expect(scan.items.map(\.name) == ["Other"])

        let forced = CleanupItem(url: root.appending(path: "Homebrew"), size: 1, modified: nil)
        let report = Cleaner().clean([forced], in: category, method: .deletePermanently)
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: homebrew.path))
    }
}

@Suite struct AppTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "ReclaimHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func app(at url: URL, bundleID: String? = "com.example.widget", name: String = "Widget") -> InstalledApp {
        InstalledApp(url: url, name: name, bundleID: bundleID, version: "1.0", size: 1_000, lastUsed: nil, dateAdded: nil)
    }

    @Test func findsLeftoversByBundleIDAndName() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appending(path: "Library")
        for path in ["Application Support/com.example.widget/data", "Caches/com.example.widget/x", "Application Support/Widget/y", "Caches/com.example.other/z"] {
            let url = library.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 2_000).write(to: url)
        }
        try FileManager.default.createDirectory(at: library.appending(path: "Preferences"), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: library.appending(path: "Preferences/com.example.widget.plist"))

        let inventory = AppInventory(roots: [home.appending(path: "Applications")], home: home)
        let leftovers = inventory.leftovers(for: app(at: home.appending(path: "Applications/Widget.app")))
        let names = Set(leftovers.map { $0.url.path.replacingOccurrences(of: library.path + "/", with: "") })
        #expect(names == ["Application Support/com.example.widget", "Caches/com.example.widget", "Application Support/Widget", "Preferences/com.example.widget.plist"])
    }

    @Test func refusesAppleAndOutsideApps() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let uninstaller = AppUninstaller(inventory: AppInventory(roots: [home.appending(path: "Applications")], home: home))

        #expect(throws: UninstallError.self) {
            try uninstaller.validate(app(at: home.appending(path: "Applications/Safari.app"), bundleID: "com.apple.Safari"))
        }
        #expect(throws: UninstallError.self) {
            try uninstaller.validate(app(at: home.appending(path: "Desktop/Widget.app")))
        }
        #expect(throws: UninstallError.self) {
            try uninstaller.validate(app(at: home.appending(path: "Applications/Widget")))
        }
        try uninstaller.validate(app(at: home.appending(path: "Applications/Widget.app")))
    }

    @Test func uninstallRemovesOnlyKnownLeftovers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let appURL = home.appending(path: "Applications/Widget.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appURL.appending(path: "Contents"), withIntermediateDirectories: true)
        let cache = home.appending(path: "Library/Caches/com.example.widget")
        let unrelated = home.appending(path: "Documents/important.txt")
        for url in [cache.appending(path: "f"), unrelated] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        let uninstaller = AppUninstaller(inventory: AppInventory(roots: [home.appending(path: "Applications")], home: home))
        let report = uninstaller.uninstall(
            app(at: appURL),
            leftovers: [CleanupItem(url: cache, size: 1, modified: nil), CleanupItem(url: unrelated, size: 1, modified: nil)],
            method: .deletePermanently
        )
        #expect(report.removed.count == 2)
        #expect(report.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: appURL.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

@Suite struct VolumeTests {
    private func volume(_ path: String, name: String, kind: VolumeInfo.Kind, readOnly: Bool = false) -> VolumeInfo {
        VolumeInfo(
            url: URL(filePath: path, directoryHint: .isDirectory), name: name, totalCapacity: 1_000,
            availableCapacity: 400, availableForImportantUsage: 500, kind: kind, isReadOnly: readOnly
        )
    }

    @Test func computesUsage() {
        let disk = volume("/", name: "Macintosh HD", kind: .startup)
        #expect(disk.usedCapacity == 500)
        #expect(disk.purgeableCapacity == 100)
        #expect(disk.usedFraction == 0.5)
    }

    @Test func findsContainingVolume() {
        let volumes = [volume("/", name: "HD", kind: .startup), volume("/Volumes/Backup", name: "Backup", kind: .external)]
        #expect(VolumeInfo.volume(containing: URL(filePath: "/Volumes/Backup/Photos"), in: volumes)?.name == "Backup")
        #expect(VolumeInfo.volume(containing: URL(filePath: "/Volumes/Backup"), in: volumes)?.name == "Backup")
        #expect(VolumeInfo.volume(containing: URL(filePath: "/Volumes/BackupOld/x"), in: volumes)?.name == "HD")
        #expect(VolumeInfo.volume(containing: URL(filePath: "/Users/me"), in: volumes)?.name == "HD")
    }

    @Test func createsTrashCategoriesForOtherWritableDisks() {
        let volumes = [
            volume("/", name: "Macintosh HD", kind: .startup),
            volume("/Volumes/My Passport", name: "My Passport", kind: .external),
            volume("/Volumes/Installer", name: "Installer", kind: .diskImage, readOnly: true),
            volume("/Volumes/NAS", name: "NAS", kind: .network),
        ]
        let categories = CategoryCatalog.volumeCategories(for: volumes, userID: 501)
        #expect(categories.map(\.id) == ["trash-my-passport"])
        #expect(categories[0].roots.map(\.normalizedPath) == ["/Volumes/My Passport/.Trashes/501"])
        #expect(categories[0].deletesPermanently)
        #expect(categories[0].group == .otherDisks)
    }
}

@Suite struct ExplorerTests {
    @Test func measuresAndSortsChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ReclaimExplore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, size) in [("big/a.bin", 300_000), ("small.bin", 10_000)] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }
        let entries = try await FolderExplorer.measuredContents(of: root)
        #expect(entries.map(\.name) == ["big", "small.bin"])
        #expect(entries[0].isFolder)
        #expect(!entries[1].isFolder)
    }
}
