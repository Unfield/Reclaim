import Foundation
import Testing
@testable import ReclaimCore

/// Creates a throwaway directory tree for each test.
private struct Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ReclaimTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, modified: Date? = nil) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func dir(_ relative: String) -> URL { root.appending(path: relative, directoryHint: .isDirectory) }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ByteSizeTests {
    @Test(arguments: [
        ("100", Int64(100)),
        ("1k", 1_000),
        ("500MB", 500_000_000),
        ("1.5g", 1_500_000_000),
        (" 2 TB ", 2_000_000_000_000),
    ])
    func parsesSizes(input: String, expected: Int64) {
        #expect(ByteSize.parse(input) == expected)
    }

    @Test(arguments: ["", "abc", "10 parsecs", "-5MB"])
    func rejectsInvalidSizes(input: String) {
        #expect(ByteSize.parse(input) == nil)
    }
}

@Suite struct CatalogTests {
    @Test func idsAreUnique() {
        let ids = CategoryCatalog.all().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func rootsDoNotOverlap() {
        let roots = CategoryCatalog.all().flatMap(\.roots).map(\.normalizedPath)
        for a in roots {
            for b in roots where a != b {
                #expect(!a.hasPrefix(b + "/"), "\(a) is nested inside \(b)")
            }
        }
    }

    @Test func rootsStayInsideHome() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        for category in CategoryCatalog.all(home: home) {
            for root in category.roots {
                #expect(root.normalizedPath.hasPrefix("/Users/test/"))
                #expect(root.normalizedPath != "/Users/test")
            }
        }
    }
}

@Suite struct ScannerTests {
    @Test func measuresChildrenOfRoots() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        try sandbox.file("caches/big/a.bin", bytes: 200_000)
        try sandbox.file("caches/big/nested/b.bin", bytes: 100_000)
        try sandbox.file("caches/small.bin", bytes: 10_000)

        let category = CleanupCategory(
            id: "test", name: "Test", summary: "", group: .system, safety: .safe,
            roots: [sandbox.dir("caches"), sandbox.dir("missing")]
        )
        let scan = Scanner().scan(category)

        #expect(scan.isPresent)
        #expect(scan.items.map(\.name) == ["big", "small.bin"])
        #expect(scan.items[0].size >= 300_000)
        #expect(scan.totalSize == scan.items.reduce(0) { $0 + $1.size })
    }

    @Test func reportsMissingRoots() {
        let category = CleanupCategory(
            id: "test", name: "Test", summary: "", group: .system, safety: .safe,
            roots: [URL(filePath: "/nonexistent/\(UUID().uuidString)")]
        )
        let scan = Scanner().scan(category)
        #expect(!scan.isPresent)
        #expect(scan.items.isEmpty)
    }

    @Test func respectsMinimumAge() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let now = Date()
        try sandbox.file("dl/old.zip", bytes: 5_000, modified: now.addingTimeInterval(-100 * 86_400))
        try sandbox.file("dl/new.zip", bytes: 5_000, modified: now.addingTimeInterval(-1 * 86_400))

        let category = CleanupCategory(
            id: "test", name: "Test", summary: "", group: .personal, safety: .caution,
            roots: [sandbox.dir("dl")], minimumAge: 90 * 86_400
        )
        let scan = Scanner(now: { now }).scan(category)
        #expect(scan.items.map(\.name) == ["old.zip"])
    }
}

@Suite struct CleanerTests {
    @Test func deletesOnlyDirectChildren() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let inside = try sandbox.file("root/item.bin", bytes: 1_000)
        let nested = try sandbox.file("root/sub/deep.bin", bytes: 1_000)
        let outside = try sandbox.file("elsewhere.bin", bytes: 1_000)

        let category = CleanupCategory(
            id: "test", name: "Test", summary: "", group: .system, safety: .safe, roots: [sandbox.dir("root")]
        )
        let items = [inside, nested, outside].map { CleanupItem(url: $0, size: 1_000, modified: nil) }
        let report = Cleaner().clean(items, in: category, method: .deletePermanently)

        #expect(report.removed.map(\.url) == [inside])
        #expect(report.failures.count == 2)
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func dryRunLeavesFilesInPlace() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let file = try sandbox.file("root/item.bin", bytes: 1_000)
        let category = CleanupCategory(
            id: "test", name: "Test", summary: "", group: .system, safety: .safe, roots: [sandbox.dir("root")]
        )
        let report = Cleaner().clean(
            [CleanupItem(url: file, size: 1_000, modified: nil)], in: category, method: .deletePermanently, dryRun: true
        )
        #expect(report.bytesFreed == 1_000)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct LargeFileFinderTests {
    @Test func findsLargestFilesAboveThreshold() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        try sandbox.file("a/huge.bin", bytes: 300_000)
        try sandbox.file("b/c/large.bin", bytes: 200_000)
        try sandbox.file("tiny.bin", bytes: 1_000)
        try sandbox.file("node_modules/skipped.bin", bytes: 500_000)

        let files = LargeFileFinder().find(in: sandbox.root, options: .init(minimumSize: 100_000, limit: 10))
        #expect(files.map(\.name) == ["huge.bin", "large.bin"])
    }
}
