import ReclaimCore
import SwiftUI

extension AIModelSource {
    var symbolName: String {
        switch self {
        case .ollama: "cube"
        case .lmStudio: "cpu"
        case .huggingFace: "face.smiling"
        case .gpt4all: "bubble.left.and.text.bubble.right"
        case .torch: "flame"
        }
    }

    var tint: Color {
        switch self {
        case .ollama: .gray
        case .lmStudio: .indigo
        case .huggingFace: .yellow
        case .gpt4all: .green
        case .torch: .orange
        }
    }
}

extension AIModel {
    var sortDate: Date { lastUsed ?? .distantPast }
    var sourceName: String { source.name }
}

/// The source's app icon if it's installed, otherwise a symbol.
private struct SourceIcon: View {
    @Environment(AppModel.self) private var model
    let source: AIModelSource
    var size: CGFloat = 18

    var body: some View {
        if let url = model.aiModels.appURL(for: source) {
            FileIcon(url: url, size: size)
        } else {
            IconTile(systemName: source.symbolName, tint: source.tint, size: size)
        }
    }
}

struct AIModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var sourceFilter: AIModelSource?
    @State private var selection: AIModel.ID?
    @State private var sortOrder = [KeyPathComparator(\AIModel.size, order: .reverse)]
    @State private var pendingRemoval: [AIModel]?

    private var visibleModels: [AIModel] {
        let models = model.aiModels.models
        let filtered = sourceFilter.map { source in models.filter { $0.source == source } } ?? models
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        let aiModels = model.aiModels
        let models = visibleModels
        let checked = aiModels.checkedModels
        let highlighted = models.first { $0.id == selection }

        Group {
            if !aiModels.loaded {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for AI models…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if models.isEmpty {
                ContentUnavailableView {
                    Label("No AI Models Found", systemImage: "brain")
                } description: {
                    Text("Reclaim looks for models from Ollama, LM Studio, Hugging Face, GPT4All and PyTorch Hub.")
                }
            } else {
                Table(models, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("") { item in
                        Toggle("", isOn: Binding(
                            get: { aiModels.isChecked(item) },
                            set: { aiModels.setChecked($0, item) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    .width(20)
                    TableColumn("Model", value: \.name) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if let detail = detail(for: item) {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .help(item.url.abbreviatedPath)
                    }
                    TableColumn("Source", value: \.sourceName) { item in
                        HStack(spacing: 6) {
                            SourceIcon(source: item.source)
                            Text(item.source.name).lineLimit(1)
                        }
                    }
                    .width(min: 120, ideal: 140, max: 180)
                    TableColumn("Last Used", value: \.sortDate) { item in
                        Text(item.lastUsed?.shortDate ?? String(localized: "Unknown"))
                            .foregroundStyle(.secondary)
                    }
                    .width(110)
                    TableColumn("Size", value: \.size) { item in
                        SizeText(bytes: item.size).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)
                }
                .contextMenu(forSelectionType: AIModel.ID.self) { ids in
                    if let item = models.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") { AppModel.revealInFinder(item.url) }
                        Divider()
                        Button("Remove \(item.name)…") { pendingRemoval = [item] }
                    }
                } primaryAction: { ids in
                    models.filter { ids.contains($0.id) }.forEach { AppModel.revealInFinder($0.url) }
                }
            }
        }
        .topBar {
            HStack(spacing: 10) {
                Picker("Source", selection: $sourceFilter) {
                    Text("All Sources").tag(AIModelSource?.none)
                    Divider()
                    ForEach(aiModels.presentSources, id: \.self) { source in
                        Text(source.name).tag(AIModelSource?.some(source))
                    }
                }
                .fixedSize()
                .disabled(aiModels.presentSources.isEmpty)

                Spacer()

                Button {
                    Task { await aiModels.rescan() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Rescan AI models")
                .disabled(aiModels.isScanning || aiModels.isRemoving)
            }
        }
        .bottomBar {
            ActivityIndicator(isActive: aiModels.isScanning || aiModels.isRemoving)
            Text(checked.isEmpty
                ? "\(models.count) models · \(ByteSize.format(AIModel.diskUsage(of: models)))"
                : "\(checked.count) selected · \(ByteSize.format(checked.reduce(0) { $0 + $1.reclaimableSize }))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Reveal in Finder") { highlighted.map { AppModel.revealInFinder($0.url) } }
                .secondaryButtonStyle()
                .disabled(highlighted == nil)
            Button("Remove…") { pendingRemoval = checked }
                .primaryButtonStyle()
                .disabled(checked.isEmpty || aiModels.isRemoving)
        }
        .navigationTitle("AI Models")
        .task { await aiModels.loadIfNeeded() }
        .onChange(of: aiModels.presentSources) { _, sources in
            if let filter = sourceFilter, !sources.contains(filter) { sourceFilter = nil }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { chosen in
            Button("Remove", role: .destructive) {
                Task { await aiModels.remove(chosen, appModel: model) }
            }
        } message: { chosen in
            Text(removalMessage(chosen))
        }
    }

    private func detail(for item: AIModel) -> String? {
        var parts = [String]()
        if item.kind == .dataset { parts.append(String(localized: "Dataset")) }
        if item.sharedSize > 0 { parts.append(String(localized: "\(ByteSize.format(item.sharedSize)) shared with other models")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var removalTitle: String {
        guard let chosen = pendingRemoval else { return "" }
        return chosen.count == 1 ? String(localized: "Remove \(chosen[0].name)?") : String(localized: "Remove \(chosen.count) models?")
    }

    private func removalMessage(_ chosen: [AIModel]) -> String {
        let usesCLI = model.aiModels.usesOllamaCLI
        let permanent = chosen.filter { usesCLI && $0.source == .ollama }
        let trashed = chosen.filter { !(usesCLI && $0.source == .ollama) }
        var lines = [String]()
        if !trashed.isEmpty {
            let size = ByteSize.format(trashed.reduce(0) { $0 + $1.reclaimableSize })
            lines.append(String(localized: "\(size) will be moved to the Trash. You can put it back from Recently Removed."))
        }
        if !permanent.isEmpty {
            let size = ByteSize.format(permanent.reduce(0) { $0 + $1.reclaimableSize })
            let names = permanent.count == 1 ? permanent[0].name : String(localized: "\(permanent.count) Ollama models")
            lines.append(String(localized: "\(names) (\(size)) will be removed with Ollama's own `ollama rm` command. This can't be undone."))
        }
        if chosen.contains(where: { $0.sharedSize > 0 }) {
            lines.append(String(localized: "Files shared with other Ollama models are kept."))
        }
        lines.append(String(localized: "You'll need to download a model again to use it."))
        return lines.joined(separator: "\n\n")
    }
}
