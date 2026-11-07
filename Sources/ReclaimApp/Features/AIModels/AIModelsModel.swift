import AppKit
import Observation
import ReclaimCore
import SwiftUI

/// State for the AI Models screen, owned by `AppModel`.
@MainActor
@Observable
final class AIModelsModel {
    private(set) var models: [AIModel] = []
    private(set) var loaded = false
    private(set) var isScanning = false
    private(set) var isRemoving = false
    /// Whether Ollama models are removed with `ollama rm` (permanent) rather than moved to the Trash.
    private(set) var usesOllamaCLI = false
    /// Models checked for removal. Models may hold work you can't easily get back, so nothing starts checked.
    var checked: Set<AIModel.ID> = []

    @ObservationIgnored private var appURLs: [AIModelSource: URL] = [:]

    init() {}

    var presentSources: [AIModelSource] {
        AIModelSource.allCases.filter { source in models.contains { $0.source == source } }
    }

    var checkedModels: [AIModel] { models.filter { checked.contains($0.id) } }

    func isChecked(_ model: AIModel) -> Bool { checked.contains(model.id) }

    func setChecked(_ isChecked: Bool, _ model: AIModel) {
        if isChecked { checked.insert(model.id) } else { checked.remove(model.id) }
    }

    /// The source's app, if it's installed (for its icon).
    func appURL(for source: AIModelSource) -> URL? { appURLs[source] }

    // MARK: Scanning

    func loadIfNeeded() async {
        if !loaded { await rescan() }
    }

    func rescan() async {
        guard !isScanning, !isRemoving else { return }
        isScanning = true
        defer { isScanning = false }

        let (models, usesCLI) = await Task.detached(priority: .userInitiated) {
            (AIModelScanner().scan(), AIModelRemover.ollamaCLI != nil)
        }.value
        appURLs = Dictionary(uniqueKeysWithValues: AIModelSource.allCases.compactMap { source in
            Self.findApp(for: source).map { (source, $0) }
        })
        self.models = models
        usesOllamaCLI = usesCLI
        checked.formIntersection(models.map(\.id))
        loaded = true
    }

    private static func findApp(for source: AIModelSource) -> URL? {
        let bundleIDs: [String]
        let paths: [String]
        switch source {
        case .ollama:
            bundleIDs = ["com.electron.ollama"]
            paths = ["Ollama.app"]
        case .lmStudio:
            bundleIDs = ["ai.elementlabs.lmstudio"]
            paths = ["LM Studio.app"]
        case .gpt4all:
            bundleIDs = []
            paths = ["GPT4All.app", "gpt4all/bin/gpt4all.app"]
        case .huggingFace, .torch:
            return nil
        }
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let folders = [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
        for folder in folders {
            for path in paths {
                let url = folder.appending(path: path)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
            }
        }
        return nil
    }

    // MARK: Removing

    func remove(_ chosen: [AIModel], appModel: AppModel) async {
        guard !chosen.isEmpty, !isRemoving else { return }
        isRemoving = true

        let report = await Task.detached(priority: .userInitiated) {
            await AIModelRemover().remove(chosen)
        }.value

        var summary = CleanupSummary()
        summary.freed = report.deletedBytes
        summary.trashed = report.trashedBytes
        summary.failures = report.failures.map { String(localized: "\($0.model.name): \($0.message)") } + report.warnings
        let title = report.removed.count == 1
            ? String(localized: "Removed \(report.removed[0].name)")
            : String(localized: "Removed \(report.removed.count) AI models")
        summary.undoBatchID = appModel.recordTrash(title: title, records: report.trashed)
        appModel.lastReport = summary
        appModel.didRemoveFiles()

        checked.subtract(report.removed.map(\.id))
        isRemoving = false
        await rescan()
    }
}
