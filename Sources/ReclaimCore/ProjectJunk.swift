import Foundation

// MARK: - Kinds

/// The language or tool a rebuildable project folder belongs to.
public enum ProjectEcosystem: String, Sendable, CaseIterable, Hashable {
    case javaScript, rust, python, swift, gradle, cocoaPods, dart, zig, elixir, terraform

    public var name: String {
        switch self {
        case .javaScript: "JavaScript"
        case .rust: "Rust"
        case .python: "Python"
        case .swift: "Swift"
        case .gradle: "Gradle"
        case .cocoaPods: "CocoaPods"
        case .dart: "Dart"
        case .zig: "Zig"
        case .elixir: "Elixir"
        case .terraform: "Terraform"
        }
    }
}

/// A kind of dependency or build folder that a project's own tooling can regenerate.
///
/// A folder only counts if its marker is present (e.g. `node_modules` needs a `package.json`
/// next to it), so a folder that merely happens to be called `build` or `env` is never offered.
public struct ProjectJunkKind: Sendable, Hashable, Identifiable {
    public enum Marker: Sendable, Hashable {
        /// One of these files sits in the same directory as the folder.
        case sibling([String])
        /// A file with this extension sits in the same directory as the folder.
        case siblingExtension(String)
        /// The folder itself contains this file.
        case contains(String)
    }

    public let id: String
    public let folderNames: [String]
    public let name: String
    public let ecosystem: ProjectEcosystem
    public let safety: SafetyLevel
    /// The usual command that brings the folder back.
    public let rebuildHint: String
    public let marker: Marker

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private static let packageJSON = Marker.sibling(["package.json"])
    private static let gradleFiles = Marker.sibling(["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"])

    /// Every known kind. Order matters where folder names are shared (`build`): the first match wins.
    public static let all: [ProjectJunkKind] = [
        .init(id: "node-modules", folderNames: ["node_modules"], name: "Node packages", ecosystem: .javaScript,
              safety: .review, rebuildHint: "npm install", marker: packageJSON),
        .init(id: "next", folderNames: [".next"], name: "Next.js build", ecosystem: .javaScript,
              safety: .safe, rebuildHint: "npm run build", marker: packageJSON),
        .init(id: "nuxt", folderNames: [".nuxt"], name: "Nuxt build", ecosystem: .javaScript,
              safety: .safe, rebuildHint: "npm run build", marker: packageJSON),
        .init(id: "svelte-kit", folderNames: [".svelte-kit"], name: "SvelteKit build", ecosystem: .javaScript,
              safety: .safe, rebuildHint: "npm run build", marker: packageJSON),
        .init(id: "turbo", folderNames: [".turbo"], name: "Turborepo cache", ecosystem: .javaScript,
              safety: .safe, rebuildHint: "npm run build", marker: packageJSON),
        .init(id: "parcel-cache", folderNames: [".parcel-cache"], name: "Parcel cache", ecosystem: .javaScript,
              safety: .safe, rebuildHint: "npm run build", marker: packageJSON),
        .init(id: "angular", folderNames: [".angular"], name: "Angular cache", ecosystem: .javaScript,
              safety: .safe, rebuildHint: "npm run build", marker: packageJSON),
        .init(id: "cargo-target", folderNames: ["target"], name: "Cargo build", ecosystem: .rust,
              safety: .safe, rebuildHint: "cargo build", marker: .sibling(["Cargo.toml"])),
        .init(id: "python-venv", folderNames: [".venv", "venv", "env"], name: "Python environment", ecosystem: .python,
              safety: .review, rebuildHint: "python3 -m venv .venv", marker: .contains("pyvenv.cfg")),
        .init(id: "swift-build", folderNames: [".build"], name: "Swift build", ecosystem: .swift,
              safety: .safe, rebuildHint: "swift build", marker: .sibling(["Package.swift"])),
        .init(id: "gradle-build", folderNames: ["build"], name: "Gradle build", ecosystem: .gradle,
              safety: .safe, rebuildHint: "gradle build", marker: gradleFiles),
        .init(id: "gradle-cache", folderNames: [".gradle"], name: "Gradle cache", ecosystem: .gradle,
              safety: .safe, rebuildHint: "gradle build", marker: gradleFiles),
        .init(id: "cocoapods", folderNames: ["Pods"], name: "CocoaPods", ecosystem: .cocoaPods,
              safety: .review, rebuildHint: "pod install", marker: .sibling(["Podfile"])),
        .init(id: "dart-tool", folderNames: [".dart_tool"], name: "Dart tool cache", ecosystem: .dart,
              safety: .safe, rebuildHint: "dart pub get", marker: .sibling(["pubspec.yaml"])),
        .init(id: "flutter-build", folderNames: ["build"], name: "Flutter build", ecosystem: .dart,
              safety: .safe, rebuildHint: "flutter build", marker: .sibling(["pubspec.yaml"])),
        .init(id: "zig-cache", folderNames: [".zig-cache", "zig-cache"], name: "Zig cache", ecosystem: .zig,
              safety: .safe, rebuildHint: "zig build", marker: .sibling(["build.zig"])),
        .init(id: "mix-build", folderNames: ["_build"], name: "Mix build", ecosystem: .elixir,
              safety: .safe, rebuildHint: "mix compile", marker: .sibling(["mix.exs"])),
        .init(id: "mix-deps", folderNames: ["deps"], name: "Mix dependencies", ecosystem: .elixir,
              safety: .review, rebuildHint: "mix deps.get", marker: .sibling(["mix.exs"])),
        .init(id: "terraform", folderNames: [".terraform"], name: "Terraform providers", ecosystem: .terraform,
              safety: .review, rebuildHint: "terraform init", marker: .siblingExtension("tf")),
    ]

    /// Every folder name that may be junk. The finder never descends into folders with these names.
    public static let folderNameSet: Set<String> = Set(all.flatMap(\.folderNames))

    /// The kind of `folder`, if its name is known and its marker is present.
    /// - Parameter siblingFiles: names of the non-directory entries next to `folder`.
    public static func kind(of folder: URL, siblingFiles: Set<String>) -> ProjectJunkKind? {
        let name = folder.lastPathComponent
        guard folderNameSet.contains(name) else { return nil }
        return all.first { $0.folderNames.contains(name) && $0.isMarkerPresent(for: folder, siblingFiles: siblingFiles) }
    }

    func isMarkerPresent(for folder: URL, siblingFiles: Set<String>) -> Bool {
        switch marker {
        case .sibling(let names):
            return names.contains(where: siblingFiles.contains)
        case .siblingExtension(let ext):
            return siblingFiles.contains { ($0 as NSString).pathExtension == ext && !$0.hasPrefix(".") }
        case .contains(let name):
            return FileProbe.isRegularFile(folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// The rebuild command, adjusted for the project's package manager where that's knowable from its files.
    func rebuildHint(folderName: String, siblingFiles: Set<String>) -> String {
        switch ecosystem {
        case .javaScript:
            let runner: String
            if siblingFiles.contains("pnpm-lock.yaml") {
                runner = "pnpm"
            } else if siblingFiles.contains("yarn.lock") {
                runner = "yarn"
            } else if siblingFiles.contains("bun.lockb") || siblingFiles.contains("bun.lock") {
                runner = "bun"
            } else {
                runner = "npm"
            }
            if id == "node-modules" { return "\(runner) install" }
            return runner == "npm" || runner == "bun" ? "\(runner) run build" : "\(runner) build"
        case .python:
            if siblingFiles.contains("uv.lock") { return "uv sync" }
            if siblingFiles.contains("poetry.lock") { return "poetry install" }
            if siblingFiles.contains("Pipfile") { return "pipenv install" }
            let create = "python3 -m venv \(folderName)"
            return siblingFiles.contains("requirements.txt") ? "\(create) && pip install -r requirements.txt" : create
        case .gradle:
            return siblingFiles.contains("gradlew") ? "./gradlew build" : rebuildHint
        default:
            return rebuildHint
        }
    }
}

// MARK: - Found items

/// Identifies a file-system object independent of its path (device + inode).
public struct FileIdentity: Sendable, Hashable {
    public let device: Int32
    public let inode: UInt64

    /// The identity of the item itself (symbolic links are not followed unless asked).
    public static func of(_ url: URL, followingSymlinks: Bool = false) -> FileIdentity? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return followingSymlinks ? stat(path, &info) : lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}

/// A rebuildable folder inside a code project.
public struct ProjectJunk: Identifiable, Sendable, Hashable {
    /// The junk folder itself, e.g. `~/Dev/site/node_modules`.
    public let url: URL
    public let kind: ProjectJunkKind
    /// The search folder this was found in.
    public let root: URL
    /// Newest change to the project's own files (see `ProjectJunkFinder.lastActive(of:)`).
    public let lastActive: Date?
    public let rebuildHint: String
    /// What the folder was when it was found, so a later swap is noticed before removal.
    public let identity: FileIdentity?
    /// Filled in once measured.
    public var size: Int64?

    public init(url: URL, kind: ProjectJunkKind, root: URL, lastActive: Date?, rebuildHint: String? = nil, identity: FileIdentity? = nil, size: Int64? = nil) {
        self.url = url
        self.kind = kind
        self.root = root
        self.lastActive = lastActive
        self.rebuildHint = rebuildHint ?? kind.rebuildHint
        self.identity = identity
        self.size = size
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    /// The directory containing the marker file.
    public var project: URL { url.deletingLastPathComponent() }
    public var projectName: String { project.lastPathComponent }

    /// True if the project hasn't changed for at least `days` days. Unknown activity counts as active.
    public func isInactive(days: Int, now: Date = Date()) -> Bool {
        guard let lastActive else { return false }
        return lastActive <= now.addingTimeInterval(-Double(max(0, days)) * 86_400)
    }

    // Sort keys for tables.
    public var sortSize: Int64 { size ?? -1 }
    public var sortLastActive: Date { lastActive ?? .distantPast }
}

// MARK: - Finder

/// Walks code folders looking for rebuildable dependency and build folders.
///
/// Never follows symbolic links, never descends into junk folders, `.git`, other hidden folders
/// or packages (bundles), and stops at `maxDepth` levels below each root.
public struct ProjectJunkFinder: Sendable {
    public var maxDepth: Int
    public var exclusions: Exclusions

    public init(maxDepth: Int = 6, exclusions: Exclusions = .load()) {
        self.maxDepth = maxDepth
        self.exclusions = exclusions
    }

    /// Folders developers commonly keep code in, relative to the home folder.
    public static let commonFolders = [
        "Developer", "Dev", "dev", "Projects", "projects", "Code", "code", "src", "repos",
        "GitHub", "Documents/GitHub", "Sites", "workspace",
    ]

    /// The common code folders that exist, matched with exact case and without duplicates
    /// (on a case-insensitive disk `~/Dev` and `~/dev` are the same folder).
    public static func commonRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var listings: [String: Set<String>] = [:]
        func names(in directory: URL) -> Set<String> {
            let key = directory.normalizedPath
            if let cached = listings[key] { return cached }
            let found = Set((try? FileManager.default.contentsOfDirectory(atPath: key)) ?? [])
            listings[key] = found
            return found
        }

        let candidates = commonFolders.compactMap { relative -> URL? in
            var current = home
            for component in relative.split(separator: "/").map(String.init) {
                guard names(in: current).contains(component) else { return nil }
                current = current.appending(path: component, directoryHint: .isDirectory)
            }
            return current
        }
        return uniqueRoots(candidates)
    }

    /// Existing folders only, without duplicates (same folder reached by different paths).
    public static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<FileIdentity>()
        var seenPaths = Set<String>()
        return roots.filter { root in
            guard FileProbe.isDirectory(root, followingSymlinks: true) else { return false }
            if let identity = FileIdentity.of(root, followingSymlinks: true) {
                return seen.insert(identity).inserted
            }
            return seenPaths.insert(root.normalizedPath).inserted
        }
    }

    /// Scans synchronously, reporting each folder as soon as it's found. Stops early if the task is cancelled.
    public func scan(roots: [URL], found: (ProjectJunk) -> Void) {
        var seen = Set<String>()
        var seenIdentities = Set<FileIdentity>()
        for root in Self.uniqueRoots(roots) where !exclusions.excludes(root) {
            walk(root, depth: 0, root: root) { junk in
                guard seen.insert(junk.url.normalizedPath).inserted else { return }
                if let identity = junk.identity, !seenIdentities.insert(identity).inserted { return }
                found(junk)
            }
        }
    }

    /// Everything found, in discovery order.
    public func scan(roots: [URL]) -> [ProjectJunk] {
        var results = [ProjectJunk]()
        scan(roots: roots) { results.append($0) }
        return results
    }

    /// Streams results from a background task. Cancelling the consumer stops the scan.
    public func results(in roots: [URL]) -> AsyncStream<ProjectJunk> {
        let finder = self
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                finder.scan(roots: roots) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Walking

    struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let isPackage: Bool
        let modified: Date?
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey,
    ]

    static func list(_ directory: URL) -> [Entry]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        else { return nil }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                isPackage: values.isPackage == true,
                modified: values.contentModificationDate
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func siblingFiles(in entries: [Entry]) -> Set<String> {
        Set(entries.filter { !$0.isDirectory }.map(\.name))
    }

    private func walk(_ directory: URL, depth: Int, root: URL, found: (ProjectJunk) -> Void) {
        guard !Task.isCancelled, let entries = Self.list(directory) else { return }
        let siblings = Self.siblingFiles(in: entries)
        var lastActive: Date??
        var subdirectories = [URL]()

        for entry in entries where entry.isDirectory && !entry.isSymbolicLink {
            if ProjectJunkKind.folderNameSet.contains(entry.name) {
                // Junk-named folders are never descended into, whether or not they match.
                guard let kind = ProjectJunkKind.kind(of: entry.url, siblingFiles: siblings),
                      !exclusions.excludes(entry.url)
                else { continue }
                if lastActive == nil { lastActive = .some(Self.lastActive(of: directory, entries: entries)) }
                found(ProjectJunk(
                    url: entry.url,
                    kind: kind,
                    root: root,
                    lastActive: lastActive ?? nil,
                    rebuildHint: kind.rebuildHint(folderName: entry.name, siblingFiles: siblings),
                    identity: FileIdentity.of(entry.url)
                ))
                continue
            }
            guard depth < maxDepth, !entry.name.hasPrefix("."), !entry.isPackage, !exclusions.excludes(entry.url) else { continue }
            subdirectories.append(entry.url)
        }

        for subdirectory in subdirectories {
            walk(subdirectory, depth: depth + 1, root: root, found: found)
        }
    }

    // MARK: Activity

    /// When the project was last worked on: the newest modification among its top-level entries
    /// (ignoring junk folders, `.git` and `.DS_Store`) and `.git/index` / `.git/HEAD`.
    public static func lastActive(of project: URL) -> Date? {
        guard let entries = list(project) else { return nil }
        return lastActive(of: project, entries: entries)
    }

    static func lastActive(of project: URL, entries: [Entry]) -> Date? {
        var newest: Date?
        func consider(_ date: Date?) {
            guard let date else { return }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }

        var hasGitDirectory = false
        for entry in entries {
            if entry.name == ".DS_Store" { continue }
            if entry.isDirectory && !entry.isSymbolicLink {
                if entry.name == ".git" {
                    hasGitDirectory = true
                    continue
                }
                if ProjectJunkKind.folderNameSet.contains(entry.name) { continue }
            }
            consider(entry.modified)
        }
        if hasGitDirectory {
            for name in ["index", "HEAD"] {
                let url = project.appending(path: ".git/\(name)", directoryHint: .notDirectory)
                consider(try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }
        }
        return newest
    }
}

// MARK: - Validation

public enum ProjectJunkError: Error, LocalizedError, Sendable, Equatable {
    case notJunk(URL)
    case missing(URL)
    case notADirectory(URL)
    case symbolicLink(URL)
    case missingMarker(URL)
    case outsideRoots(URL)
    case protectedLocation(URL)
    case excluded(URL)
    case changedSinceScan(URL)

    public var errorDescription: String? {
        switch self {
        case .notJunk(let url): "Refusing to remove \(url.abbreviatedPath): it isn't a known build or dependency folder."
        case .missing(let url): "\(url.abbreviatedPath) no longer exists."
        case .notADirectory(let url): "Refusing to remove \(url.abbreviatedPath): it isn't a folder."
        case .symbolicLink(let url): "Refusing to remove \(url.abbreviatedPath): it's a symbolic link."
        case .missingMarker(let url): "Refusing to remove \(url.abbreviatedPath): its project file is missing."
        case .outsideRoots(let url): "Refusing to remove \(url.abbreviatedPath): it isn't inside a searched folder."
        case .protectedLocation(let url): "Refusing to remove \(url.abbreviatedPath): it's part of macOS."
        case .excluded(let url): "Skipped \(url.abbreviatedPath): it's on your exclusion list."
        case .changedSinceScan(let url): "Skipped \(url.abbreviatedPath): it changed since the scan. Scan again."
        }
    }
}

/// The last line of defense before a project folder is removed.
public enum ProjectJunkValidator {
    static let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/Library/Apple", "/Applications"]

    /// Checks a scan result again right before removal, including that it's still the same folder.
    @discardableResult
    public static func validate(_ junk: ProjectJunk, roots: [URL], exclusions: Exclusions) throws -> ProjectJunkKind {
        let kind = try validate(junk.url, roots: roots, exclusions: exclusions)
        guard kind == junk.kind else { throw ProjectJunkError.changedSinceScan(junk.url) }
        if let identity = junk.identity, FileIdentity.of(junk.url) != identity {
            throw ProjectJunkError.changedSinceScan(junk.url)
        }
        return kind
    }

    /// Throws unless `url` is a real (non-symlink) folder with a known junk name, its marker is present,
    /// it lies inside one of `roots` (also after resolving symlinks), isn't excluded and isn't part of macOS.
    @discardableResult
    public static func validate(_ url: URL, roots: [URL], exclusions: Exclusions) throws -> ProjectJunkKind {
        let standardized = url.standardizedFileURL
        let path = standardized.normalizedPath
        let name = standardized.lastPathComponent
        guard url.isFileURL, path.hasPrefix("/"), path != "/", ProjectJunkKind.folderNameSet.contains(name) else {
            throw ProjectJunkError.notJunk(url)
        }
        if isProtected(path) { throw ProjectJunkError.protectedLocation(url) }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path) // Doesn't follow a final symlink.
        } catch {
            throw ProjectJunkError.missing(url)
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw ProjectJunkError.symbolicLink(url) }
        guard type == .typeDirectory else { throw ProjectJunkError.notADirectory(url) }

        // Inside a root both as written and after resolving symlinks, so a linked folder can't lead elsewhere.
        let parent = standardized.deletingLastPathComponent()
        let resolvedParent = parent.resolvingSymlinksInPath().normalizedPath
        let resolvedPath = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
        let insideRoot = roots.contains { root in
            isInside(parent.normalizedPath, root.standardizedFileURL.normalizedPath)
                && isInside(resolvedParent, root.resolvingSymlinksInPath().normalizedPath)
        }
        guard insideRoot else { throw ProjectJunkError.outsideRoots(url) }
        if isProtected(resolvedPath) { throw ProjectJunkError.protectedLocation(url) }

        if exclusions.excludes(standardized) || exclusions.excludes(URL(filePath: resolvedPath)) {
            throw ProjectJunkError.excluded(url)
        }

        guard let entries = ProjectJunkFinder.list(parent),
              let kind = ProjectJunkKind.kind(of: standardized, siblingFiles: ProjectJunkFinder.siblingFiles(in: entries))
        else { throw ProjectJunkError.missingMarker(url) }
        return kind
    }

    static func isProtected(_ path: String) -> Bool {
        protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// True if `path` is `base` or inside it.
    static func isInside(_ path: String, _ base: String) -> Bool {
        path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }
}

// MARK: - Cleaning

/// Moves validated project folders to the Trash.
public struct ProjectJunkCleaner: Sendable {
    public struct Failure: Sendable {
        public let junk: ProjectJunk
        public let message: String
    }

    public struct Result: Sendable {
        public var removed: [ProjectJunk] = []
        public var trashed: [TrashRecord] = []
        public var failures: [Failure] = []

        public var bytesFreed: Int64 { removed.reduce(0) { $0 + ($1.size ?? 0) } }
        /// Distinct projects that had something removed.
        public var projectCount: Int { Set(removed.map(\.project.normalizedPath)).count }

        /// A title for the undo history, e.g. "Cleaned 12 projects".
        public var undoTitle: String {
            let projects = Set(removed.map(\.project.normalizedPath))
            if projects.count == 1, let project = removed.first?.projectName { return "Cleaned \(project)" }
            return "Cleaned \(projects.count) projects"
        }
    }

    public let roots: [URL]
    public let exclusions: Exclusions

    /// - Parameter roots: the folders that were scanned; nothing outside them is ever removed.
    public init(roots: [URL], exclusions: Exclusions = .load()) {
        self.roots = roots
        self.exclusions = exclusions
    }

    /// Validates each item right before moving it. `trash` is replaceable for tests.
    public func moveToTrash(
        _ items: [ProjectJunk],
        dryRun: Bool = false,
        trash: (URL, Int64) throws -> TrashRecord = { try Trash.move($0, size: $1) }
    ) -> Result {
        var result = Result()
        var handled = Set<String>()
        for junk in items where handled.insert(junk.url.normalizedPath).inserted {
            do {
                try ProjectJunkValidator.validate(junk, roots: roots, exclusions: exclusions)
                if !dryRun {
                    result.trashed.append(try trash(junk.url, junk.size ?? 0))
                }
                result.removed.append(junk)
            } catch {
                result.failures.append(Failure(junk: junk, message: error.localizedDescription))
            }
        }
        return result
    }
}

// MARK: - Helpers

enum FileProbe {
    static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    static func isDirectory(_ url: URL, followingSymlinks: Bool) -> Bool {
        if followingSymlinks {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeDirectory
    }
}
