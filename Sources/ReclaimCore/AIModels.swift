import Foundation

// MARK: - Sources and locations

/// Apps and libraries that keep local AI models.
public enum AIModelSource: String, Sendable, CaseIterable, Comparable, Codable {
    case ollama
    case lmStudio
    case huggingFace
    case gpt4all
    case torch

    public var name: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .huggingFace: "Hugging Face"
        case .gpt4all: "GPT4All"
        case .torch: "PyTorch Hub"
        }
    }

    public static func < (lhs: AIModelSource, rhs: AIModelSource) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// Where each source keeps its models. Honors the same environment variables the tools do.
public struct AIModelLocations: Sendable, Equatable {
    /// Ollama's models folder (contains `manifests` and `blobs`).
    public var ollama: URL
    /// LM Studio's models folders: current first, then the legacy one.
    public var lmStudio: [URL]
    /// The Hugging Face hub cache (contains `models--org--name` folders).
    public var huggingFace: URL
    public var gpt4all: URL
    public var torchCheckpoints: URL

    public init(ollama: URL, lmStudio: [URL], huggingFace: URL, gpt4all: URL, torchCheckpoints: URL) {
        self.ollama = ollama
        self.lmStudio = lmStudio
        self.huggingFace = huggingFace
        self.gpt4all = gpt4all
        self.torchCheckpoints = torchCheckpoints
    }

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        func path(_ key: String) -> URL? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            let expanded = value == "~" ? home.path(percentEncoded: false)
                : value.hasPrefix("~/") ? home.appending(path: String(value.dropFirst(2))).path(percentEncoded: false)
                : value
            guard expanded.hasPrefix("/") else { return nil }
            return URL(filePath: expanded, directoryHint: .isDirectory)
        }
        let cache = path("XDG_CACHE_HOME") ?? home.appending(path: ".cache", directoryHint: .isDirectory)

        ollama = path("OLLAMA_MODELS") ?? home.appending(path: ".ollama/models", directoryHint: .isDirectory)
        lmStudio = [
            home.appending(path: ".lmstudio/models", directoryHint: .isDirectory),
            home.appending(path: ".cache/lm-studio/models", directoryHint: .isDirectory),
        ]
        huggingFace = path("HF_HUB_CACHE") ?? path("HUGGINGFACE_HUB_CACHE")
            ?? path("HF_HOME")?.appending(path: "hub", directoryHint: .isDirectory)
            ?? cache.appending(path: "huggingface/hub", directoryHint: .isDirectory)
        gpt4all = home.appending(path: "Library/Application Support/nomic.ai/GPT4All", directoryHint: .isDirectory)
        torchCheckpoints = (path("TORCH_HOME") ?? cache.appending(path: "torch", directoryHint: .isDirectory))
            .appending(path: "hub/checkpoints", directoryHint: .isDirectory)
    }
}

// MARK: - Model

public struct AIModel: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case model
        case dataset
    }

    public let source: AIModelSource
    /// e.g. `llama3:8b`, `lmstudio-community/Qwen3-8B-GGUF`, `openai/whisper-large-v3`.
    public let name: String
    public let kind: Kind
    /// The folder or file holding the model. For Ollama, its manifest.
    public let url: URL
    /// Total size, including files shared with other models.
    public let size: Int64
    /// Files shared with other models (Ollama layers) and their sizes. Removing this model alone doesn't free them.
    public let sharedFiles: [String: Int64]
    public let lastUsed: Date?

    public init(source: AIModelSource, name: String, kind: Kind = .model, url: URL, size: Int64, sharedFiles: [String: Int64] = [:], lastUsed: Date?) {
        self.source = source
        self.name = name
        self.kind = kind
        self.url = url
        self.size = size
        self.sharedFiles = sharedFiles
        self.lastUsed = lastUsed
    }

    /// Bytes shared with other models.
    public var sharedSize: Int64 { sharedFiles.values.reduce(0, +) }

    /// Disk space used by a set of models, counting shared files once.
    public static func diskUsage(of models: [AIModel]) -> Int64 {
        var shared = [String: Int64]()
        for model in models { shared.merge(model.sharedFiles) { first, _ in first } }
        return models.reduce(0) { $0 + $1.reclaimableSize } + shared.values.reduce(0, +)
    }

    public var id: String { "\(source.rawValue):\(url.normalizedPath)" }
    /// What removing this model frees.
    public var reclaimableSize: Int64 { max(0, size - sharedSize) }
}

// MARK: - Ollama store

/// Reads Ollama's on-disk store: `manifests/<registry>/<namespace>/<model>/<tag>` (JSON) and `blobs/sha256-<hex>`.
public enum OllamaStore {
    public static let defaultRegistry = "registry.ollama.ai"

    public struct Manifest: Sendable, Equatable {
        public let url: URL
        public let name: String
        /// Blob file names (`sha256-<hex>`), without duplicates.
        public let blobNames: [String]
    }

    public struct Contents: Sendable {
        public var manifests: [Manifest] = []
        /// Manifests that couldn't be parsed. Their blobs are unknown, so no blob may be removed while any exist.
        public var unreadable: [URL] = []
        public var allReadable: Bool { unreadable.isEmpty }
    }

    private struct Layer: Decodable {
        let digest: String
    }

    private struct ManifestFile: Decodable {
        let config: Layer?
        let layers: [Layer]?
    }

    /// The blob file names a manifest refers to, or nil if it isn't a valid manifest.
    public static func blobNames(inManifest data: Data) -> [String]? {
        guard let manifest = try? JSONDecoder().decode(ManifestFile.self, from: data) else { return nil }
        let digests = [manifest.config].compactMap { $0 } + (manifest.layers ?? [])
        var names = [String]()
        for layer in digests {
            // A malformed digest could point anywhere, so the whole manifest is treated as unreadable.
            guard let name = blobFileName(forDigest: layer.digest) else { return nil }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// `sha256:<64 hex>` → `sha256-<64 hex>`. Nil for anything else, so a digest can never escape the blobs folder.
    public static func blobFileName(forDigest digest: String) -> String? {
        let parts = digest.split(separator: ":", omittingEmptySubsequences: false)
        let hex = parts.count == 2 && parts[0] == "sha256" ? parts[1]
            : digest.hasPrefix("sha256-") ? digest.dropFirst("sha256-".count) : nil
        guard let hex, isSHA256Hex(hex) else { return nil }
        return "sha256-\(hex)"
    }

    static func isBlobFileName(_ name: String) -> Bool {
        name.hasPrefix("sha256-") && isSHA256Hex(name.dropFirst("sha256-".count))
    }

    private static func isSHA256Hex(_ text: Substring) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// The name Ollama shows and accepts: `model:tag` for the official library, `namespace/model:tag`
    /// for other users, and `registry/namespace/model:tag` for other registries (e.g. `hf.co/...`).
    public static func modelName(registry: String, namespace: String, model: String, tag: String) -> String {
        if registry == defaultRegistry {
            return namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
        }
        return "\(registry)/\(namespace)/\(model):\(tag)"
    }

    public static func read(_ root: URL) -> Contents {
        var contents = Contents()
        let manifests = root.appending(path: "manifests", directoryHint: .isDirectory)
        for registry in FileWalker.subfolders(of: manifests) {
            for namespace in FileWalker.subfolders(of: registry) {
                for model in FileWalker.subfolders(of: namespace) {
                    for tag in FileWalker.children(of: model) where FileWalker.isRegularFile(tag) {
                        guard let data = try? Data(contentsOf: tag), let blobs = blobNames(inManifest: data) else {
                            contents.unreadable.append(tag)
                            continue
                        }
                        let name = modelName(
                            registry: registry.lastPathComponent, namespace: namespace.lastPathComponent,
                            model: model.lastPathComponent, tag: tag.lastPathComponent
                        )
                        contents.manifests.append(Manifest(url: tag, name: name, blobNames: blobs))
                    }
                }
            }
        }
        return contents
    }
}

// MARK: - Scanner

/// Finds local AI models from Ollama, LM Studio, Hugging Face, GPT4All and PyTorch Hub.
public struct AIModelScanner: Sendable {
    public let locations: AIModelLocations
    private let exclusions: Exclusions

    public init(locations: AIModelLocations = AIModelLocations(), exclusions: Exclusions = .load()) {
        self.locations = locations
        self.exclusions = exclusions
    }

    /// All models, grouped by source, largest first.
    public func scan() -> [AIModel] {
        let models = ollamaModels() + lmStudioModels() + huggingFaceModels() + gpt4allModels() + torchModels()
        return models.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func ollamaModels() -> [AIModel] {
        let root = locations.ollama
        let store = OllamaStore.read(root)
        let blobsFolder = root.appending(path: "blobs", directoryHint: .isDirectory)

        var references = [String: Int]()
        for manifest in store.manifests {
            for blob in manifest.blobNames { references[blob, default: 0] += 1 }
        }
        var measured = [String: FileWalker.Measurement]()
        func measure(_ blob: String) -> FileWalker.Measurement {
            if let cached = measured[blob] { return cached }
            let url = blobsFolder.appending(path: blob)
            let result = FileWalker.isRegularFile(url) ? FileWalker.measure(url) : FileWalker.Measurement()
            measured[blob] = result
            return result
        }

        return store.manifests.compactMap { manifest -> AIModel? in
            guard !exclusions.excludes(manifest.url) else { return nil }
            // Ollama reads every manifest for `ollama list`, so only blob access says when a model was used.
            var total = FileWalker.measure(manifest.url, includeAccessDates: false)
            var shared = [String: Int64]()
            for blob in manifest.blobNames {
                let blobSize = measure(blob)
                total.add(blobSize)
                if references[blob, default: 0] > 1 { shared[blob] = blobSize.bytes }
            }
            return AIModel(source: .ollama, name: manifest.name, url: manifest.url, size: total.bytes, sharedFiles: shared, lastUsed: total.lastUsed)
        }
    }

    func lmStudioModels() -> [AIModel] {
        var seenRoots = Set<String>()
        var models = [AIModel]()
        for root in locations.lmStudio {
            // The legacy folder may be a link to the current one; don't list the same models twice.
            guard seenRoots.insert(root.resolvingSymlinksInPath().normalizedPath).inserted else { continue }
            for publisher in FileWalker.subfolders(of: root) {
                for folder in FileWalker.subfolders(of: publisher) {
                    if let found = model(.lmStudio, name: "\(publisher.lastPathComponent)/\(folder.lastPathComponent)", at: folder) {
                        models.append(found)
                    }
                }
            }
        }
        return models
    }

    func huggingFaceModels() -> [AIModel] {
        FileWalker.subfolders(of: locations.huggingFace).compactMap { folder in
            guard let (name, kind) = Self.huggingFaceRepo(folderName: folder.lastPathComponent) else { return nil }
            return model(.huggingFace, name: name, kind: kind, at: folder)
        }
    }

    func gpt4allModels() -> [AIModel] {
        FileWalker.children(of: locations.gpt4all).compactMap { file in
            guard file.pathExtension.lowercased() == "gguf", FileWalker.isRegularFile(file) else { return nil }
            return model(.gpt4all, name: file.deletingPathExtension().lastPathComponent, at: file)
        }
    }

    func torchModels() -> [AIModel] {
        FileWalker.children(of: locations.torchCheckpoints).compactMap { file in
            guard FileWalker.isRegularFile(file) else { return nil }
            return model(.torch, name: file.lastPathComponent, at: file)
        }
    }

    private func model(_ source: AIModelSource, name: String, kind: AIModel.Kind = .model, at url: URL) -> AIModel? {
        guard !exclusions.excludes(url) else { return nil }
        let measurement = FileWalker.measure(url)
        return AIModel(source: source, name: name, kind: kind, url: url, size: measurement.bytes, lastUsed: measurement.lastUsed)
    }

    /// `models--org--name` → ("org/name", .model); `datasets--org--name` → ("org/name", .dataset).
    public static func huggingFaceRepo(folderName: String) -> (name: String, kind: AIModel.Kind)? {
        let kinds: [(prefix: String, kind: AIModel.Kind)] = [("models--", .model), ("datasets--", .dataset)]
        guard let match = kinds.first(where: { folderName.hasPrefix($0.prefix) }) else { return nil }
        let repo = folderName.dropFirst(match.prefix.count).components(separatedBy: "--").filter { !$0.isEmpty }
        guard !repo.isEmpty else { return nil }
        return (repo.joined(separator: "/"), match.kind)
    }
}

// MARK: - Removal

public enum AIModelRemovalError: Error, LocalizedError, Sendable {
    case outsideModelFolder(URL)
    case excluded(URL)
    case symbolicLink(URL)
    case missing(URL)
    case unreadableOllamaManifests(Int)

    public var errorDescription: String? {
        switch self {
        case .outsideModelFolder(let url): "Refusing to remove \(url.abbreviatedPath): it isn't in a known model folder."
        case .excluded(let url): "Skipped \(url.abbreviatedPath): it's on your exclusion list."
        case .symbolicLink(let url): "Skipped \(url.abbreviatedPath): it's a symbolic link."
        case .missing(let url): "\(url.abbreviatedPath) no longer exists."
        case .unreadableOllamaManifests(let count):
            "\(count) Ollama models couldn't be read, so Reclaim can't tell which files are shared. Remove it with `ollama rm` instead."
        }
    }
}

public struct AIModelRemovalReport: Sendable {
    public var removed: [AIModel] = []
    public var failures: [(model: AIModel, message: String)] = []
    /// Everything moved to the Trash (record these for undo).
    public var trashed: [TrashRecord] = []
    /// Bytes removed permanently by `ollama rm`.
    public var deletedBytes: Int64 = 0
    /// Problems that didn't stop a model from being removed.
    public var warnings: [String] = []

    public init() {}

    public var trashedBytes: Int64 { trashed.reduce(0) { $0 + $1.size } }
}

public struct AIModelRemover: Sendable {
    public typealias TrashHandler = @Sendable (URL, Int64) throws -> TrashRecord
    public typealias OllamaRemove = @Sendable (String) async throws -> ShellResult

    public let locations: AIModelLocations
    private let exclusions: Exclusions
    private let ollamaRemove: OllamaRemove?
    private let trash: TrashHandler

    /// `ollama rm` if the CLI is installed.
    public static var ollamaCLI: OllamaRemove? {
        guard Shell.find("ollama") != nil else { return nil }
        return { name in try await Shell.run("ollama", ["rm", name], timeout: 120) }
    }

    public init(
        locations: AIModelLocations = AIModelLocations(),
        exclusions: Exclusions = .load(),
        ollamaRemove: OllamaRemove? = AIModelRemover.ollamaCLI,
        trash: @escaping TrashHandler = { try Trash.move($0, size: $1) }
    ) {
        self.locations = locations
        self.exclusions = exclusions
        self.ollamaRemove = ollamaRemove
        self.trash = trash
    }

    /// Ollama models are removed permanently with `ollama rm` (otherwise they go to the Trash).
    public var usesOllamaCLI: Bool { ollamaRemove != nil }

    public func remove(_ models: [AIModel], dryRun: Bool = false) async -> AIModelRemovalReport {
        var report = AIModelRemovalReport()
        var ollamaFallback = [AIModel]()

        for model in models {
            do {
                try validate(model)
            } catch {
                report.failures.append((model, error.localizedDescription))
                continue
            }
            if dryRun {
                report.removed.append(model)
                continue
            }
            switch model.source {
            case .ollama:
                if let ollamaRemove, await removeWithOllama(model, ollamaRemove) {
                    report.removed.append(model)
                    report.deletedBytes += model.reclaimableSize
                } else {
                    // Without the CLI (or if it fails, e.g. because Ollama isn't running), the files go to the Trash.
                    ollamaFallback.append(model)
                }
            default:
                do {
                    report.trashed.append(try trash(model.url, model.size))
                    report.removed.append(model)
                } catch {
                    report.failures.append((model, error.localizedDescription))
                }
            }
        }
        if !ollamaFallback.isEmpty { trashOllamaModels(ollamaFallback, into: &report) }
        return report
    }

    private func removeWithOllama(_ model: AIModel, _ run: OllamaRemove) async -> Bool {
        guard let result = try? await run(model.name), result.succeeded else { return false }
        // Make sure it was removed from *this* store (Ollama may be using a different models folder).
        return !FileWalker.exists(model.url)
    }

    /// Moves manifests to the Trash, then every blob no remaining manifest uses.
    private func trashOllamaModels(_ models: [AIModel], into report: inout AIModelRemovalReport) {
        let store = OllamaStore.read(locations.ollama)
        guard store.allReadable else {
            for model in models {
                report.failures.append((model, AIModelRemovalError.unreadableOllamaManifests(store.unreadable.count).localizedDescription))
            }
            return
        }
        // Paths are normalized up front: once a file is gone, its normalized path can change (e.g. `/private/var` vs `/var`).
        let keyed = store.manifests.map { (key: $0.url.normalizedPath, manifest: $0) }
        let manifests = Dictionary(keyed.map { ($0.key, $0.manifest) }, uniquingKeysWith: { first, _ in first })

        var removedManifests = Set<String>()
        var candidateBlobs = [String]()
        for model in models {
            let key = model.url.normalizedPath
            guard let manifest = manifests[key] else {
                report.failures.append((model, AIModelRemovalError.missing(model.url).localizedDescription))
                continue
            }
            do {
                report.trashed.append(try trash(model.url, FileWalker.measure(model.url).bytes))
                report.removed.append(model)
                removedManifests.insert(key)
                candidateBlobs += manifest.blobNames
            } catch {
                report.failures.append((model, error.localizedDescription))
            }
        }

        let stillUsed = Set(keyed.filter { !removedManifests.contains($0.key) }.flatMap(\.manifest.blobNames))
        var handled = Set<String>()
        let blobs = locations.ollama.appending(path: "blobs", directoryHint: .isDirectory)
        for name in candidateBlobs where !stillUsed.contains(name) && handled.insert(name).inserted {
            let url = blobs.appending(path: name)
            guard FileWalker.exists(url) else { continue }
            do {
                try validateOllamaBlob(url)
                report.trashed.append(try trash(url, FileWalker.measure(url).bytes))
            } catch {
                report.warnings.append("Couldn't remove Ollama file \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Safety checks

    /// Checks, right before removal, that a model is exactly where its source keeps models.
    func validate(_ model: AIModel) throws {
        let url = model.url
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        guard !name.isEmpty, !name.hasPrefix("."), name != ".." else { throw AIModelRemovalError.outsideModelFolder(url) }

        let root: URL?
        switch model.source {
        case .ollama:
            // manifests/<registry>/<namespace>/<model>/<tag>
            let manifests = locations.ollama.appending(path: "manifests", directoryHint: .isDirectory)
            root = Self.depth(of: url, below: manifests) == 4 ? manifests : nil
        case .lmStudio:
            root = locations.lmStudio.first { Self.depth(of: url, below: $0) == 2 }
        case .huggingFace:
            root = parent.normalizedPath == locations.huggingFace.normalizedPath
                && AIModelScanner.huggingFaceRepo(folderName: name) != nil ? locations.huggingFace : nil
        case .gpt4all:
            root = parent.normalizedPath == locations.gpt4all.normalizedPath && url.pathExtension.lowercased() == "gguf"
                ? locations.gpt4all : nil
        case .torch:
            root = parent.normalizedPath == locations.torchCheckpoints.normalizedPath ? locations.torchCheckpoints : nil
        }
        guard let root else { throw AIModelRemovalError.outsideModelFolder(url) }
        try validateItem(url, below: root)
        if model.source == .ollama, !FileWalker.isRegularFile(url) { throw AIModelRemovalError.outsideModelFolder(url) }
    }

    func validateOllamaBlob(_ url: URL) throws {
        let blobs = locations.ollama.appending(path: "blobs", directoryHint: .isDirectory)
        guard url.deletingLastPathComponent().normalizedPath == blobs.normalizedPath,
              OllamaStore.isBlobFileName(url.lastPathComponent)
        else { throw AIModelRemovalError.outsideModelFolder(url) }
        try validateItem(url, below: blobs)
    }

    /// The item exists, isn't excluded, and neither it nor any folder between it and `root` is a symbolic link.
    private func validateItem(_ url: URL, below root: URL) throws {
        guard FileWalker.exists(url) else { throw AIModelRemovalError.missing(url) }
        if exclusions.excludes(url) { throw AIModelRemovalError.excluded(url) }
        var current = url
        while current.normalizedPath != root.normalizedPath, current.normalizedPath.count > root.normalizedPath.count {
            if FileWalker.isSymbolicLink(current) { throw AIModelRemovalError.symbolicLink(current) }
            current = current.deletingLastPathComponent()
        }
    }

    /// How many path components `url` is below `root`, or nil if it isn't inside it.
    static func depth(of url: URL, below root: URL) -> Int? {
        let base = root.normalizedPath
        let path = url.normalizedPath
        guard path.hasPrefix(base + "/") else { return nil }
        let components = path.dropFirst(base.count + 1).split(separator: "/")
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return components.count
    }
}

// MARK: - File helpers

/// Small file-system helpers that never follow symbolic links.
enum FileWalker {
    struct Measurement: Sendable {
        var bytes: Int64 = 0
        var lastUsed: Date?

        mutating func add(_ other: Measurement) {
            bytes += other.bytes
            if let date = other.lastUsed, date > (lastUsed ?? .distantPast) { lastUsed = date }
        }
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentAccessDateKey, .contentModificationDateKey,
    ]

    private static func values(_ url: URL) -> URLResourceValues? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try? fresh.resourceValues(forKeys: keys)
    }

    /// True even for broken symbolic links.
    static func exists(_ url: URL) -> Bool {
        values(url) != nil
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        values(url)?.isSymbolicLink == true
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard let values = values(url) else { return false }
        return values.isSymbolicLink != true && values.isRegularFile == true
    }

    /// Non-hidden direct children.
    static func children(of folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Non-hidden direct child folders that aren't symbolic links.
    static func subfolders(of folder: URL) -> [URL] {
        children(of: folder).filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    /// Allocated size and most recent file access/modification of a file or folder (links count as themselves).
    /// Folder dates are ignored: merely listing a folder (as this scan does) updates its access date.
    static func measure(_ url: URL, includeAccessDates: Bool = true) -> Measurement {
        guard let rootValues = try? url.resourceValues(forKeys: keys) else { return Measurement() }
        var result = Measurement()
        func include(_ values: URLResourceValues) {
            guard values.isDirectory != true || values.isSymbolicLink == true else { return }
            result.bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let dates = [includeAccessDates ? values.contentAccessDate : nil, values.contentModificationDate]
            for date in dates.compactMap({ $0 }) where date > (result.lastUsed ?? .distantPast) {
                result.lastUsed = date
            }
        }
        include(rootValues)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return result }

        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }
            if let values = try? child.resourceValues(forKeys: keys) { include(values) }
        }
        return result
    }
}
