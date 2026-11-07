import Foundation
import Testing
@testable import ReclaimCore

// MARK: - Helpers

/// A throwaway folder tree. Every path is relative to `url`.
private struct Sandbox {
    let url: URL

    init(_ name: String = "ReclaimProjects") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> URL { url.appending(path: relative) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16) throws -> URL {
        let file = path(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        return file
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let folder = path(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func link(_ relative: String, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: path(relative), withDestinationURL: destination)
    }

    func setModified(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path(relative).path(percentEncoded: false))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func finder(maxDepth: Int = 6, exclusions: Exclusions = Exclusions()) -> ProjectJunkFinder {
    ProjectJunkFinder(maxDepth: maxDepth, exclusions: exclusions)
}

/// Found folders as "relative/path=kind-id".
private func scanSummary(_ sandbox: Sandbox, maxDepth: Int = 6, exclusions: Exclusions = Exclusions()) -> Set<String> {
    let base = sandbox.url.normalizedPath + "/"
    return Set(finder(maxDepth: maxDepth, exclusions: exclusions).scan(roots: [sandbox.url]).map {
        String($0.url.normalizedPath.dropFirst(base.count)) + "=" + $0.kind.id
    })
}

private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

// MARK: - Finding

@Suite struct ProjectJunkFinderTests {
    @Test func findsEveryKindNextToItsMarker() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("web/package.json")
        for name in ["node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular"] {
            try box.folder("web/\(name)")
        }
        try box.file("rs/Cargo.toml"); try box.folder("rs/target")
        try box.file("py/.venv/pyvenv.cfg"); try box.file("py/env/pyvenv.cfg")
        try box.file("sw/Package.swift"); try box.folder("sw/.build")
        try box.file("android/settings.gradle.kts"); try box.folder("android/.gradle"); try box.folder("android/build")
        try box.file("android/app/build.gradle"); try box.folder("android/app/build")
        try box.file("ios/Podfile"); try box.folder("ios/Pods")
        try box.file("fl/pubspec.yaml"); try box.folder("fl/.dart_tool"); try box.folder("fl/build")
        try box.file("zg/build.zig"); try box.folder("zg/.zig-cache"); try box.folder("zg/zig-cache")
        try box.file("ex/mix.exs"); try box.folder("ex/_build"); try box.folder("ex/deps")
        try box.file("tf/main.tf"); try box.folder("tf/.terraform")

        #expect(scanSummary(box) == [
            "web/node_modules=node-modules", "web/.next=next", "web/.nuxt=nuxt", "web/.svelte-kit=svelte-kit",
            "web/.turbo=turbo", "web/.parcel-cache=parcel-cache", "web/.angular=angular",
            "rs/target=cargo-target",
            "py/.venv=python-venv", "py/env=python-venv",
            "sw/.build=swift-build",
            "android/.gradle=gradle-cache", "android/build=gradle-build", "android/app/build=gradle-build",
            "ios/Pods=cocoapods",
            "fl/.dart_tool=dart-tool", "fl/build=flutter-build",
            "zg/.zig-cache=zig-cache", "zg/zig-cache=zig-cache",
            "ex/_build=mix-build", "ex/deps=mix-deps",
            "tf/.terraform=terraform",
        ])
    }

    @Test func ignoresFoldersWithoutTheirMarker() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("cmake/CMakeLists.txt"); try box.folder("cmake/build")   // not Gradle or Flutter
        try box.folder("loose/node_modules")                                   // no package.json
        try box.file("rs/Cargo.lock"); try box.folder("rs/target")            // lock file isn't the marker
        try box.folder("py/venv/lib")                                          // no pyvenv.cfg
        try box.folder("py2/env/pyvenv.cfg")                                   // a folder, not a file
        try box.folder("dir/package.json"); try box.folder("dir/node_modules") // marker must be a file
        try box.file("c/Makefile"); try box.folder("c/deps")                   // deps without mix.exs
        try box.file("t/.tf"); try box.folder("t/.terraform")                  // hidden ".tf" isn't a Terraform file
        try box.file("other/package.json"); try box.folder("other/target")     // wrong marker for the name
        #expect(scanSummary(box).isEmpty)
    }

    @Test func skipsJunkGitHiddenFoldersAndPackages() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("web/package.json"); try box.folder("web/node_modules")
        try box.file("web/node_modules/dep/package.json"); try box.folder("web/node_modules/dep/node_modules")
        try box.file("web/.git/hooks/package.json"); try box.folder("web/.git/hooks/node_modules")
        try box.file(".hidden/p/package.json"); try box.folder(".hidden/p/node_modules")
        try box.file("Thing.app/p/package.json"); try box.folder("Thing.app/p/node_modules")
        try box.file("cmake/build/inner/package.json"); try box.folder("cmake/build/inner/node_modules")
        #expect(scanSummary(box) == ["web/node_modules=node-modules"])
    }

    @Test func findsNestedPackagesInMonorepos() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("mono/package.json"); try box.folder("mono/node_modules")
        try box.file("mono/packages/ui/package.json"); try box.folder("mono/packages/ui/node_modules")
        #expect(scanSummary(box) == ["mono/node_modules=node-modules", "mono/packages/ui/node_modules=node-modules"])
    }

    @Test func neverFollowsSymbolicLinks() throws {
        let box = try Sandbox()
        let outside = try Sandbox("ReclaimProjectsOutside")
        defer { box.remove(); outside.remove() }
        try outside.file("p/package.json"); try outside.folder("p/node_modules")
        try box.link("linked-project", to: outside.path("p"))
        try box.link("linked-parent", to: outside.url)
        try box.file("q/package.json"); try box.link("q/node_modules", to: outside.path("p/node_modules"))
        #expect(scanSummary(box).isEmpty)
    }

    @Test func respectsDepthLimit() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("a/package.json"); try box.folder("a/node_modules")
        try box.file("a/b/c/package.json"); try box.folder("a/b/c/node_modules")
        #expect(scanSummary(box, maxDepth: 1) == ["a/node_modules=node-modules"])
        #expect(scanSummary(box, maxDepth: 3).count == 2)
    }

    @Test func honorsExclusions() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("keep/package.json"); try box.folder("keep/node_modules")
        try box.file("deep/x/package.json"); try box.folder("deep/x/node_modules")
        try box.file("rs/Cargo.toml"); try box.folder("rs/target")
        var exclusions = Exclusions()
        exclusions.add(box.path("keep"))
        exclusions.add(box.path("deep"))
        exclusions.add(box.path("rs/target"))
        #expect(scanSummary(box, exclusions: exclusions).isEmpty)
    }

    @Test func overlappingRootsReportEachFolderOnce() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/node_modules")
        try box.link("alias", to: box.url)
        let found = finder().scan(roots: [box.url, box.path("p"), box.path("alias")])
        #expect(found.count == 1)
        #expect(found.first?.root == box.url)
    }

    @Test func commonRootsMatchExactNamesWithoutDuplicates() throws {
        let home = try Sandbox("ReclaimHome")
        defer { home.remove() }
        try home.folder("dev")
        try home.folder("Documents/GitHub")
        try home.link("Developer", to: home.path("dev"))
        try home.file("Code") // a file, not a folder
        let roots = ProjectJunkFinder.commonRoots(home: home.url).map(\.lastPathComponent)
        // "Developer" comes first in the list and is the same folder as "dev"; "Dev" doesn't match "dev" by name.
        #expect(roots == ["Developer", "GitHub"])
    }

    @Test func rebuildHintsFollowTheProjectsTools() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("pnpm/package.json"); try box.file("pnpm/pnpm-lock.yaml"); try box.folder("pnpm/node_modules")
        try box.file("yarn/package.json"); try box.file("yarn/yarn.lock"); try box.folder("yarn/.next")
        try box.file("npm/package.json"); try box.folder("npm/node_modules")
        try box.file("uv/uv.lock"); try box.file("uv/.venv/pyvenv.cfg")
        try box.file("req/requirements.txt"); try box.file("req/venv/pyvenv.cfg")
        try box.file("gw/build.gradle"); try box.file("gw/gradlew"); try box.folder("gw/build")
        let hints = Dictionary(uniqueKeysWithValues: finder().scan(roots: [box.url]).map { ($0.projectName, $0.rebuildHint) })
        #expect(hints["pnpm"] == "pnpm install")
        #expect(hints["yarn"] == "yarn build")
        #expect(hints["npm"] == "npm install")
        #expect(hints["uv"] == "uv sync")
        #expect(hints["req"] == "python3 -m venv venv && pip install -r requirements.txt")
        #expect(hints["gw"] == "./gradlew build")
    }

    @Test func streamsTheSameResults() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("a/package.json"); try box.folder("a/node_modules")
        try box.file("b/Cargo.toml"); try box.folder("b/target")
        var streamed = [URL]()
        for await junk in finder().results(in: [box.url]) { streamed.append(junk.url) }
        #expect(streamed == finder().scan(roots: [box.url]).map(\.url))
        #expect(streamed.count == 2)
    }
}

// MARK: - Activity

@Suite struct ProjectActivityTests {
    @Test func lastActiveIgnoresJunkGitAndFinderFiles() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/src"); try box.folder("p/node_modules")
        try box.file("p/.DS_Store"); try box.folder("p/.git")
        let source = daysAgo(40)
        try box.setModified("p/package.json", daysAgo(100))
        try box.setModified("p/src", source)
        try box.setModified("p/node_modules", daysAgo(1))
        try box.setModified("p/.DS_Store", daysAgo(1))
        try box.setModified("p/.git", daysAgo(1))

        let lastActive = try #require(ProjectJunkFinder.lastActive(of: box.path("p")))
        #expect(abs(lastActive.timeIntervalSince(source)) < 1)

        let junk = try #require(finder().scan(roots: [box.url]).first)
        #expect(junk.isInactive(days: 30))
        #expect(!junk.isInactive(days: 90))
    }

    @Test func gitIndexCountsAsActivity() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/Cargo.toml"); try box.folder("p/target")
        try box.file("p/.git/index"); try box.file("p/.git/HEAD")
        try box.setModified("p/Cargo.toml", daysAgo(400))
        try box.setModified("p/.git/HEAD", daysAgo(300))
        try box.setModified("p/.git/index", daysAgo(5))
        try box.setModified("p/.git", daysAgo(400))

        let junk = try #require(finder().scan(roots: [box.url]).first)
        #expect(!junk.isInactive(days: 30))
    }

    @Test func unknownActivityIsNeverInactive() {
        let kind = ProjectJunkKind.all[0]
        let unknown = ProjectJunk(url: URL(filePath: "/tmp/p/node_modules"), kind: kind, root: URL(filePath: "/tmp"), lastActive: nil)
        #expect(!unknown.isInactive(days: 0))
        let old = ProjectJunk(url: URL(filePath: "/tmp/p/node_modules"), kind: kind, root: URL(filePath: "/tmp"), lastActive: daysAgo(31))
        #expect(old.isInactive(days: 30))
        #expect(!old.isInactive(days: 90))
    }
}

// MARK: - Safety

@Suite struct ProjectJunkSafetyTests {
    private func scanned(_ box: Sandbox, _ relative: String) throws -> ProjectJunk {
        let target = box.path(relative).normalizedPath
        return try #require(finder().scan(roots: [box.url]).first { $0.url.normalizedPath == target })
    }

    @Test func acceptsWhatTheScanFound() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/node_modules")
        try box.file("v/.venv/pyvenv.cfg")
        let junk = try scanned(box, "p/node_modules")
        #expect(try ProjectJunkValidator.validate(junk, roots: [box.url], exclusions: Exclusions()).id == "node-modules")
        #expect(try ProjectJunkValidator.validate(box.path("v/.venv"), roots: [box.url], exclusions: Exclusions()).id == "python-venv")
    }

    @Test func rejectsUnknownFolderNames() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/src")
        #expect(throws: ProjectJunkError.notJunk(box.path("p/src"))) {
            try ProjectJunkValidator.validate(box.path("p/src"), roots: [box.url], exclusions: Exclusions())
        }
        #expect(throws: ProjectJunkError.self) {
            try ProjectJunkValidator.validate(box.path("p"), roots: [box.url], exclusions: Exclusions())
        }
    }

    @Test func rejectsMissingMarkers() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/node_modules")
        try box.folder("v/venv")
        let junk = try scanned(box, "p/node_modules")
        try FileManager.default.removeItem(at: box.path("p/package.json"))
        #expect(throws: ProjectJunkError.missingMarker(junk.url)) {
            try ProjectJunkValidator.validate(junk, roots: [box.url], exclusions: Exclusions())
        }
        #expect(throws: ProjectJunkError.missingMarker(box.path("v/venv"))) {
            try ProjectJunkValidator.validate(box.path("v/venv"), roots: [box.url], exclusions: Exclusions())
        }
    }

    @Test func rejectsSymbolicLinksAndFiles() throws {
        let box = try Sandbox()
        let outside = try Sandbox("ReclaimProjectsOutside")
        defer { box.remove(); outside.remove() }
        try outside.folder("real-modules")
        try box.file("p/package.json"); try box.link("p/node_modules", to: outside.path("real-modules"))
        try box.file("q/package.json"); try box.file("q/node_modules")
        #expect(throws: ProjectJunkError.symbolicLink(box.path("p/node_modules"))) {
            try ProjectJunkValidator.validate(box.path("p/node_modules"), roots: [box.url], exclusions: Exclusions())
        }
        #expect(throws: ProjectJunkError.notADirectory(box.path("q/node_modules"))) {
            try ProjectJunkValidator.validate(box.path("q/node_modules"), roots: [box.url], exclusions: Exclusions())
        }
        #expect(FileManager.default.fileExists(atPath: outside.path("real-modules").path(percentEncoded: false)))
    }

    @Test func rejectsFoldersOutsideTheRoots() throws {
        let box = try Sandbox()
        let outside = try Sandbox("ReclaimProjectsOutside")
        defer { box.remove(); outside.remove() }
        try outside.file("p/package.json"); try outside.folder("p/node_modules")
        try box.link("via-link", to: outside.path("p"))
        try box.folder("inside")

        // Simply elsewhere.
        #expect(throws: ProjectJunkError.outsideRoots(outside.path("p/node_modules"))) {
            try ProjectJunkValidator.validate(outside.path("p/node_modules"), roots: [box.url], exclusions: Exclusions())
        }
        // Inside the root as written, but a symlinked parent leads elsewhere.
        #expect(throws: ProjectJunkError.outsideRoots(box.path("via-link/node_modules"))) {
            try ProjectJunkValidator.validate(box.path("via-link/node_modules"), roots: [box.url], exclusions: Exclusions())
        }
        // `..` can't climb out either.
        let climbing = box.url.appending(path: "inside/../../\(outside.url.lastPathComponent)/p/node_modules")
        #expect(throws: ProjectJunkError.outsideRoots(climbing)) {
            try ProjectJunkValidator.validate(climbing, roots: [box.url], exclusions: Exclusions())
        }
        // A root with a similar prefix doesn't count.
        let sibling = URL(filePath: outside.url.normalizedPath + "-other")
        #expect(throws: ProjectJunkError.self) {
            try ProjectJunkValidator.validate(outside.path("p/node_modules"), roots: [sibling], exclusions: Exclusions())
        }
    }

    @Test func rejectsExcludedFolders() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/node_modules")
        var exclusions = Exclusions()
        exclusions.add(box.path("p"))
        #expect(throws: ProjectJunkError.excluded(box.path("p/node_modules"))) {
            try ProjectJunkValidator.validate(box.path("p/node_modules"), roots: [box.url], exclusions: exclusions)
        }
    }

    @Test func neverTouchesSystemLocations() {
        for path in ["/System/Library/Frameworks/node_modules", "/usr/lib/node_modules", "/Applications/node_modules"] {
            #expect(throws: ProjectJunkError.protectedLocation(URL(filePath: path))) {
                try ProjectJunkValidator.validate(URL(filePath: path), roots: [URL(filePath: "/")], exclusions: Exclusions())
            }
        }
        #expect(ProjectJunkValidator.isProtected("/System"))
        #expect(!ProjectJunkValidator.isProtected("/Systems/x"))
    }

    @Test func rejectsFoldersThatChangedSinceTheScan() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("p/package.json"); try box.folder("p/node_modules")
        let junk = try scanned(box, "p/node_modules")
        try FileManager.default.removeItem(at: junk.url)
        try box.folder("p/node_modules")
        #expect(throws: ProjectJunkError.changedSinceScan(junk.url)) {
            try ProjectJunkValidator.validate(junk, roots: [box.url], exclusions: Exclusions())
        }

        // Same name, but the project turned from Gradle into Flutter.
        try box.file("g/build.gradle"); try box.folder("g/build")
        let build = try scanned(box, "g/build")
        try FileManager.default.removeItem(at: box.path("g/build.gradle"))
        try box.file("g/pubspec.yaml")
        #expect(throws: ProjectJunkError.changedSinceScan(build.url)) {
            try ProjectJunkValidator.validate(build, roots: [box.url], exclusions: Exclusions())
        }
    }

    @Test func cleanerOnlyTrashesValidatedItems() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("a/package.json"); try box.folder("a/node_modules")
        try box.file("b/Cargo.toml"); try box.folder("b/target")
        try box.file("c/package.json"); try box.folder("c/src")
        var items = finder().scan(roots: [box.url])
        #expect(items.count == 2)
        items.append(items[0]) // duplicates are handled once
        items.append(ProjectJunk(url: box.path("c/src"), kind: ProjectJunkKind.all[0], root: box.url, lastActive: nil))
        try FileManager.default.removeItem(at: box.path("b/Cargo.toml"))

        var trashed = [URL]()
        let result = ProjectJunkCleaner(roots: [box.url], exclusions: Exclusions()).moveToTrash(items) { url, size in
            trashed.append(url)
            return TrashRecord(original: url, trashed: url, size: size)
        }
        #expect(trashed.map(\.normalizedPath) == [box.path("a/node_modules").normalizedPath])
        #expect(result.removed.count == 1)
        #expect(result.trashed.count == 1)
        #expect(result.failures.count == 2)
        #expect(result.undoTitle == "Cleaned a")
    }

    @Test func dryRunTrashesNothing() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.file("a/package.json"); try box.folder("a/node_modules")
        try box.file("b/package.json"); try box.folder("b/node_modules")
        let items = finder().scan(roots: [box.url])
        var calls = 0
        let result = ProjectJunkCleaner(roots: [box.url], exclusions: Exclusions()).moveToTrash(items, dryRun: true) { url, size in
            calls += 1
            return TrashRecord(original: url, trashed: url, size: size)
        }
        #expect(calls == 0)
        #expect(result.removed.count == 2)
        #expect(result.undoTitle == "Cleaned 2 projects")
        #expect(FileManager.default.fileExists(atPath: box.path("a/node_modules").path(percentEncoded: false)))
    }
}
