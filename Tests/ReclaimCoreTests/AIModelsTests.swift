import Foundation
import Testing
@testable import ReclaimCore

private func makeDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Resolve `/var` → `/private/var` so paths compare the same before and after files are removed.
    return url.resolvingSymlinksInPath()
}

private func write(_ url: URL, bytes: Int = 8_192) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

private func digest(_ character: Character) -> String {
    "sha256:" + String(repeating: character, count: 64)
}

private func blobName(_ character: Character) -> String {
    "sha256-" + String(repeating: character, count: 64)
}

/// A fake home folder with every supported source.
private struct FakeStores {
    let home: URL
    let locations: AIModelLocations
    let trashFolder: URL

    var ollama: URL { locations.ollama }

    init() throws {
        home = try makeDirectory("ReclaimAIModels")
        locations = AIModelLocations(home: home, environment: [:])
        trashFolder = home.appending(path: "FakeTrash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    func manifest(registry: String = "registry.ollama.ai", namespace: String = "library", model: String, tag: String, digests: [String]) throws -> URL {
        let url = ollama.appending(path: "manifests/\(registry)/\(namespace)/\(model)/\(tag)")
        let layers = digests.dropFirst().map { #"{"mediaType":"application/vnd.ollama.image.model","digest":"\#($0)","size":8192}"# }
        let json = #"{"schemaVersion":2,"config":{"digest":"\#(digests[0])","size":8192},"layers":[\#(layers.joined(separator: ","))]}"#
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return url
    }

    @discardableResult
    func blob(_ character: Character, bytes: Int = 8_192) throws -> URL {
        let url = ollama.appending(path: "blobs/\(blobName(character))")
        try write(url, bytes: bytes)
        return url
    }

    /// Two library models sharing blob "c", plus a user model.
    @discardableResult
    func makeOllama() throws -> (llama: URL, mistral: URL, user: URL) {
        try blob("a"); try blob("b", bytes: 40_960); try blob("c", bytes: 81_920); try blob("d"); try blob("e")
        let llama = try manifest(model: "llama3", tag: "8b", digests: [digest("a"), digest("b"), digest("c")])
        let mistral = try manifest(model: "mistral", tag: "latest", digests: [digest("d"), digest("c")])
        let user = try manifest(namespace: "someone", model: "tiny", tag: "q4", digests: [digest("e")])
        return (llama, mistral, user)
    }

    /// Moves items into a folder inside the fake home instead of the real Trash.
    var trash: AIModelRemover.TrashHandler {
        let folder = trashFolder
        return { url, size in
            let destination = folder.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return TrashRecord(original: url, trashed: destination, size: size)
        }
    }

    func remover(exclusions: Exclusions = Exclusions(), ollamaRemove: AIModelRemover.OllamaRemove? = nil) -> AIModelRemover {
        AIModelRemover(locations: locations, exclusions: exclusions, ollamaRemove: ollamaRemove, trash: trash)
    }

    func scan(exclusions: Exclusions = Exclusions()) -> [AIModel] {
        AIModelScanner(locations: locations, exclusions: exclusions).scan()
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

@Suite struct AIModelLocationTests {
    @Test func defaultsLiveInTheHomeFolder() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let locations = AIModelLocations(home: home, environment: [:])
        #expect(locations.ollama.normalizedPath == "/Users/me/.ollama/models")
        #expect(locations.lmStudio.map(\.normalizedPath) == ["/Users/me/.lmstudio/models", "/Users/me/.cache/lm-studio/models"])
        #expect(locations.huggingFace.normalizedPath == "/Users/me/.cache/huggingface/hub")
        #expect(locations.gpt4all.normalizedPath == "/Users/me/Library/Application Support/nomic.ai/GPT4All")
        #expect(locations.torchCheckpoints.normalizedPath == "/Users/me/.cache/torch/hub/checkpoints")
    }

    @Test func honorsEnvironmentVariables() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let custom = AIModelLocations(home: home, environment: [
            "OLLAMA_MODELS": "/Volumes/Big/ollama", "HF_HOME": "~/hf", "TORCH_HOME": "/opt/torch",
        ])
        #expect(custom.ollama.normalizedPath == "/Volumes/Big/ollama")
        #expect(custom.huggingFace.normalizedPath == "/Users/me/hf/hub")
        #expect(custom.torchCheckpoints.normalizedPath == "/opt/torch/hub/checkpoints")

        let hubCache = AIModelLocations(home: home, environment: ["HF_HUB_CACHE": "/data/hub", "HF_HOME": "/ignored"])
        #expect(hubCache.huggingFace.normalizedPath == "/data/hub")

        let xdg = AIModelLocations(home: home, environment: ["XDG_CACHE_HOME": "/cache", "OLLAMA_MODELS": "relative/path"])
        #expect(xdg.huggingFace.normalizedPath == "/cache/huggingface/hub")
        #expect(xdg.ollama.normalizedPath == "/Users/me/.ollama/models")
    }
}

@Suite struct OllamaStoreTests {
    @Test func namesFollowOllamaConventions() {
        #expect(OllamaStore.modelName(registry: "registry.ollama.ai", namespace: "library", model: "llama3", tag: "8b") == "llama3:8b")
        #expect(OllamaStore.modelName(registry: "registry.ollama.ai", namespace: "someone", model: "tiny", tag: "q4") == "someone/tiny:q4")
        #expect(OllamaStore.modelName(registry: "hf.co", namespace: "bartowski", model: "Qwen-GGUF", tag: "Q4_K_M") == "hf.co/bartowski/Qwen-GGUF:Q4_K_M")
    }

    @Test func digestsCanNeverEscapeTheBlobsFolder() {
        #expect(OllamaStore.blobFileName(forDigest: digest("a")) == blobName("a"))
        #expect(OllamaStore.blobFileName(forDigest: blobName("f")) == blobName("f"))
        #expect(OllamaStore.blobFileName(forDigest: "sha256:../../../etc/passwd") == nil)
        #expect(OllamaStore.blobFileName(forDigest: "sha256:" + String(repeating: "g", count: 64)) == nil)
        #expect(OllamaStore.blobFileName(forDigest: "md5:abc") == nil)
        #expect(OllamaStore.blobFileName(forDigest: "sha256:abc") == nil)

        let bad = Data(#"{"config":{"digest":"sha256:../x"},"layers":[]}"#.utf8)
        #expect(OllamaStore.blobNames(inManifest: bad) == nil)
        #expect(OllamaStore.blobNames(inManifest: Data("not json".utf8)) == nil)
        let good = Data(#"{"config":{"digest":"\#(digest("a"))"},"layers":[{"digest":"\#(digest("b"))"},{"digest":"\#(digest("a"))"}]}"#.utf8)
        #expect(OllamaStore.blobNames(inManifest: good) == [blobName("a"), blobName("b")])
    }

    @Test func listsModelsWithSizesAndSharedBlobs() throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let (llama, mistral, _) = try stores.makeOllama()

        let models = stores.scan().filter { $0.source == .ollama }
        #expect(models.map(\.name) == ["llama3:8b", "mistral:latest", "someone/tiny:q4"])

        let size = { (character: Character) in FileWalker.measure(stores.ollama.appending(path: "blobs/\(blobName(character))")).bytes }
        let llamaModel = try #require(models.first { $0.url.normalizedPath == llama.normalizedPath })
        #expect(llamaModel.size == size("a") + size("b") + size("c") + FileWalker.measure(llama).bytes)
        #expect(llamaModel.sharedSize == size("c"))
        #expect(llamaModel.reclaimableSize == llamaModel.size - size("c"))
        let mistralModel = try #require(models.first { $0.url.normalizedPath == mistral.normalizedPath })
        #expect(mistralModel.sharedSize == size("c"))
        #expect(models.first { $0.name == "someone/tiny:q4" }?.sharedSize == 0)

        // Shared files count once in totals.
        let all = models.reduce(Int64(0)) { $0 + $1.size }
        #expect(AIModel.diskUsage(of: models) == all - size("c"))
    }
}

@Suite struct AIModelScannerTests {
    @Test func findsLMStudioHuggingFaceGPT4AllAndTorchModels() throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let home = stores.home
        try write(home.appending(path: ".lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/model.gguf"))
        try write(home.appending(path: ".cache/lm-studio/models/TheBloke/Mistral-7B-GGUF/m.gguf"))
        try write(home.appending(path: ".lmstudio/models/.hidden/x/y.gguf"))
        try write(home.appending(path: ".cache/huggingface/hub/models--openai--whisper-large-v3/blobs/abc"), bytes: 20_000)
        try write(home.appending(path: ".cache/huggingface/hub/models--gpt2/blobs/abc"))
        try write(home.appending(path: ".cache/huggingface/hub/datasets--squad--v2/blobs/abc"))
        try write(home.appending(path: ".cache/huggingface/hub/version.txt"), bytes: 10)
        try FileManager.default.createDirectory(at: home.appending(path: ".cache/huggingface/hub/.locks"), withIntermediateDirectories: true)
        try write(home.appending(path: "Library/Application Support/nomic.ai/GPT4All/Llama-3-8B.Q4_0.gguf"))
        try write(home.appending(path: "Library/Application Support/nomic.ai/GPT4All/localdocs.db"))
        try write(home.appending(path: ".cache/torch/hub/checkpoints/resnet50.pth"))

        let models = stores.scan()
        #expect(models.map(\.source) == models.map(\.source).sorted())
        #expect(models.filter { $0.source == .lmStudio }.map(\.name).sorted() == ["TheBloke/Mistral-7B-GGUF", "lmstudio-community/Qwen3-8B-GGUF"])
        let hf = models.filter { $0.source == .huggingFace }
        #expect(hf.map(\.name) == ["openai/whisper-large-v3", "gpt2", "squad/v2"] || hf.map(\.name) == ["openai/whisper-large-v3", "squad/v2", "gpt2"])
        #expect(hf.first { $0.name == "squad/v2" }?.kind == .dataset)
        #expect(models.filter { $0.source == .gpt4all }.map(\.name) == ["Llama-3-8B.Q4_0"])
        #expect(models.filter { $0.source == .torch }.map(\.name) == ["resnet50.pth"])
        #expect(models.allSatisfy { $0.size > 0 && $0.lastUsed != nil })
    }

    @Test func doesNotListAnythingWhenNothingIsInstalled() throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        #expect(stores.scan().isEmpty)
    }

    @Test func skipsSymlinksAndExclusions() throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let elsewhere = stores.home.appending(path: "elsewhere/model")
        try write(elsewhere.appending(path: "m.gguf"))
        let publisher = stores.home.appending(path: ".lmstudio/models/pub")
        try FileManager.default.createDirectory(at: publisher, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: publisher.appending(path: "linked"), withDestinationURL: elsewhere)
        let kept = publisher.appending(path: "kept")
        try write(kept.appending(path: "m.gguf"))

        #expect(stores.scan().map(\.name) == ["pub/kept"])
        var exclusions = Exclusions()
        exclusions.add(kept)
        #expect(stores.scan(exclusions: exclusions).isEmpty)
    }

    @Test func parsesHuggingFaceFolderNames() {
        #expect(AIModelScanner.huggingFaceRepo(folderName: "models--meta-llama--Llama-3.1-8B")?.name == "meta-llama/Llama-3.1-8B")
        #expect(AIModelScanner.huggingFaceRepo(folderName: "datasets--squad--v2")?.kind == .dataset)
        #expect(AIModelScanner.huggingFaceRepo(folderName: "spaces--a--b") == nil)
        #expect(AIModelScanner.huggingFaceRepo(folderName: "models--") == nil)
    }
}

@Suite struct AIModelRemovalTests {
    @Test func ollamaWithoutCLIKeepsBlobsOtherModelsStillUse() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let (llama, mistral, _) = try stores.makeOllama()
        let blobs = stores.ollama.appending(path: "blobs")
        let model = try #require(stores.scan().first { $0.url.normalizedPath == llama.normalizedPath })

        let report = await stores.remover().remove([model])
        #expect(report.failures.isEmpty)
        #expect(report.removed.map(\.name) == ["llama3:8b"])
        #expect(report.deletedBytes == 0)
        #expect(report.trashed.count == 3) // manifest + blobs a and b
        #expect(!exists(llama))
        #expect(!exists(blobs.appending(path: blobName("a"))))
        #expect(!exists(blobs.appending(path: blobName("b"))))
        #expect(exists(blobs.appending(path: blobName("c")))) // still used by mistral
        #expect(exists(mistral))

        // Now the shared blob is only used by mistral, so removing it frees it too.
        let mistralModel = try #require(stores.scan().first { $0.url.normalizedPath == mistral.normalizedPath })
        #expect(mistralModel.sharedSize == 0)
        let second = await stores.remover().remove([mistralModel])
        #expect(second.trashed.count == 3)
        #expect(!exists(blobs.appending(path: blobName("c"))))
        #expect(exists(blobs.appending(path: blobName("e"))))
    }

    @Test func removingAllModelsSharingABlobInOneBatchFreesIt() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let (llama, mistral, _) = try stores.makeOllama()
        let models = stores.scan().filter { $0.url.normalizedPath == llama.normalizedPath || $0.url.normalizedPath == mistral.normalizedPath }

        let report = await stores.remover().remove(models)
        #expect(report.removed.count == 2)
        #expect(report.trashed.count == 6) // 2 manifests + a, b, c, d
        #expect(!exists(stores.ollama.appending(path: "blobs/\(blobName("c"))")))
    }

    @Test func refusesToRemoveBlobsWhenAManifestCannotBeRead() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let (llama, _, _) = try stores.makeOllama()
        let model = try #require(stores.scan().first { $0.url.normalizedPath == llama.normalizedPath })
        let broken = stores.ollama.appending(path: "manifests/registry.ollama.ai/library/broken/latest")
        try Data("{ not json".utf8).write(to: broken.creatingParent())

        let report = await stores.remover().remove([model])
        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(exists(llama))
    }

    @Test func prefersTheOllamaCLI() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let (llama, _, _) = try stores.makeOllama()
        let model = try #require(stores.scan().first { $0.url.normalizedPath == llama.normalizedPath })

        final class Calls: @unchecked Sendable { var names: [String] = [] }
        let calls = Calls()
        let fakeCLI: AIModelRemover.OllamaRemove = { name in
            calls.names.append(name)
            try FileManager.default.removeItem(at: llama)
            return ShellResult(status: 0, output: "deleted '\(name)'", errorOutput: "")
        }
        let report = await stores.remover(ollamaRemove: fakeCLI).remove([model])
        #expect(calls.names == ["llama3:8b"])
        #expect(report.removed.count == 1)
        #expect(report.trashed.isEmpty)
        #expect(report.deletedBytes == model.reclaimableSize)
    }

    @Test func fallsBackToTheTrashWhenTheCLIFails() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let (llama, _, _) = try stores.makeOllama()
        let model = try #require(stores.scan().first { $0.url.normalizedPath == llama.normalizedPath })
        let failingCLI: AIModelRemover.OllamaRemove = { _ in
            ShellResult(status: 1, output: "", errorOutput: "Error: could not connect to ollama app, is it running?")
        }
        let report = await stores.remover(ollamaRemove: failingCLI).remove([model])
        #expect(report.removed.count == 1)
        #expect(report.trashed.count == 3)
        #expect(!exists(llama))
    }

    @Test func movesFolderModelsToTheTrashWithRecords() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let folder = stores.home.appending(path: ".cache/huggingface/hub/models--openai--whisper")
        try write(folder.appending(path: "blobs/x"))
        let model = try #require(stores.scan().first)

        let report = await stores.remover().remove([model])
        #expect(report.removed.count == 1)
        #expect(report.trashed.map(\.original) == [model.url])
        #expect(model.url.lastPathComponent == folder.lastPathComponent)
        #expect(report.trashedBytes == model.size)
        #expect(!exists(folder))
        #expect(exists(stores.home.appending(path: ".cache/huggingface/hub")))
    }

    @Test func dryRunRemovesNothing() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        try stores.makeOllama()
        let models = stores.scan()
        let report = await stores.remover().remove(models, dryRun: true)
        #expect(report.removed.count == models.count)
        #expect(report.trashed.isEmpty)
        #expect(models.allSatisfy { exists($0.url) })
    }

    @Test func safetyChecksRefuseAnythingOutsideModelFolders() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let precious = stores.home.appending(path: "Documents/thesis")
        try write(precious.appending(path: "chapter1.docx"))
        let lmRoot = stores.locations.lmStudio[0]

        // A publisher folder that links elsewhere.
        try FileManager.default.createDirectory(at: lmRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lmRoot.appending(path: "linked"), withDestinationURL: stores.home.appending(path: "Documents"))
        let throughLink = AIModel(source: .lmStudio, name: "linked/thesis", url: lmRoot.appending(path: "linked/thesis"), size: 1, lastUsed: nil)

        let fakes = [
            AIModel(source: .lmStudio, name: "x", url: precious, size: 1, lastUsed: nil),
            AIModel(source: .lmStudio, name: "x", url: lmRoot.appending(path: "pub"), size: 1, lastUsed: nil), // wrong depth
            AIModel(source: .huggingFace, name: "x", url: stores.locations.huggingFace.appending(path: "../../Documents/thesis"), size: 1, lastUsed: nil),
            AIModel(source: .huggingFace, name: "x", url: stores.locations.huggingFace.appending(path: "version.txt"), size: 1, lastUsed: nil),
            AIModel(source: .gpt4all, name: "x", url: stores.locations.gpt4all.appending(path: "localdocs.db"), size: 1, lastUsed: nil),
            AIModel(source: .ollama, name: "x", url: stores.ollama.appending(path: "blobs/\(blobName("a"))"), size: 1, lastUsed: nil),
            throughLink,
        ]
        let report = await stores.remover().remove(fakes)
        #expect(report.removed.isEmpty)
        #expect(report.failures.count == fakes.count)
        #expect(exists(precious.appending(path: "chapter1.docx")))

        let remover = stores.remover()
        #expect(throws: AIModelRemovalError.self) { try remover.validateOllamaBlob(stores.ollama.appending(path: "blobs/../manifests")) }
        #expect(throws: AIModelRemovalError.self) { try remover.validateOllamaBlob(stores.ollama.appending(path: "blobs/notablob")) }
    }

    @Test func removalHonorsExclusions() async throws {
        let stores = try FakeStores()
        defer { stores.cleanUp() }
        let folder = stores.locations.lmStudio[0].appending(path: "pub/model")
        try write(folder.appending(path: "m.gguf"))
        let model = try #require(stores.scan().first)

        var exclusions = Exclusions()
        exclusions.add(folder)
        let report = await stores.remover(exclusions: exclusions).remove([model])
        #expect(report.removed.isEmpty)
        #expect(exists(folder))
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
