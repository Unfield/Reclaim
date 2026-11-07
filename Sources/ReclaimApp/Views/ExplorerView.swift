import ReclaimCore
import SwiftUI

struct ExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: FolderEntry.ID?
    @State private var pendingTrash: FolderEntry?
    @AppStorage("explorerShowsTreemap") private var showsTreemap = false

    var body: some View {
        let entries = model.explorerEntries
        let largest = entries.compactMap(\.size).max() ?? 1
        let selected = entries.first { $0.id == selection }

        Group {
            if let error = model.explorerError {
                ContentUnavailableView("Can't Open Folder", systemImage: "lock", description: Text(error))
            } else if entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else if showsTreemap {
                TreemapView(entries: entries, selection: $selection) { entry in
                    if entry.isFolder { model.explore(entry.url) } else { AppModel.revealInFinder(entry.url) }
                }
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Name") { entry in
                        HStack(spacing: 8) {
                            FileIcon(url: entry.url)
                            Text(entry.name).lineLimit(1)
                        }
                    }
                    TableColumn("") { entry in
                        SizeBar(fraction: entry.size.map { Double($0) / Double(max(1, largest)) })
                    }
                    .width(min: 80, ideal: 160)
                    TableColumn("Size") { entry in
                        ZStack(alignment: .trailing) {
                            ActivityIndicator(isActive: entry.size == nil).controlSize(.mini)
                            if let size = entry.size { SizeText(bytes: size) }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)
                    TableColumn("") { entry in
                        if entry.isFolder {
                            Button {
                                model.explore(entry.url)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Open \(entry.name)")
                        }
                    }
                    .width(20)
                }
                .contextMenu(forSelectionType: FolderEntry.ID.self) { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        if entry.isFolder {
                            Button("Open") { model.explore(entry.url) }
                        }
                        Button("Reveal in Finder") { AppModel.revealInFinder(entry.url) }
                        Divider()
                        Button("Move to Trash…") { pendingTrash = entry }
                    }
                } primaryAction: { ids in
                    guard let entry = entries.first(where: { ids.contains($0.id) }) else { return }
                    if entry.isFolder { model.explore(entry.url) } else { AppModel.revealInFinder(entry.url) }
                }
            }
        }
        .topBar {
            HStack(spacing: 10) {
                Button {
                    model.explore(model.explorerFolder.deletingLastPathComponent())
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Enclosing folder")
                .disabled(model.explorerFolder.normalizedPath == "/")

                LocationMenu(current: model.explorerFolder) { model.explore($0) }

                Spacer()

                Picker("View", selection: $showsTreemap) {
                    Image(systemName: "list.bullet").help("List").tag(false)
                    Image(systemName: "square.grid.3x3.square").help("Treemap").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Button {
                    model.explore(model.explorerFolder, useCache: false)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Measure again")
            }
            Breadcrumbs(folder: model.explorerFolder, volumes: model.volumes) { model.explore($0) }
        }
        .bottomBar {
            ActivityIndicator(isActive: model.isExploring)
            Text("\(entries.count) items · \(ByteSize.format(model.explorerTotal))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Reveal in Finder") { selected.map { AppModel.revealInFinder($0.url) } }
                .secondaryButtonStyle()
                .disabled(selected == nil)
            Button("Move to Trash…") { pendingTrash = selected }
                .secondaryButtonStyle()
                .disabled(selected == nil)
        }
        .navigationTitle("Space Explorer")
        .task {
            if model.explorerEntries.isEmpty && model.explorerError == nil {
                model.explore(model.explorerFolder)
            }
        }
        .confirmationDialog(
            "Move \(pendingTrash?.name ?? "") to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { entry in
            Button("Move to Trash", role: .destructive) { model.trashExplorerEntry(entry) }
        } message: { entry in
            Text("\(entry.url.abbreviatedPath)\(entry.size.map { " (\(ByteSize.format($0)))" } ?? "")")
        }
    }
}

private struct SizeBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let fraction {
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(3, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 6)
    }
}

private struct Breadcrumbs: View {
    let folder: URL
    let volumes: [VolumeInfo]
    let onSelect: (URL) -> Void

    /// Path components from the disk the folder is on, down to the folder.
    private var components: [(url: URL, title: String)] {
        let volume = VolumeInfo.volume(containing: folder, in: volumes)
        let stop = volume?.url.normalizedPath ?? "/"
        var result = [(url: URL, title: String)]()
        var current = folder.standardizedFileURL
        while true {
            let isStop = current.normalizedPath == stop
            result.insert((current, isStop ? (volume?.name ?? "Disk") : current.lastPathComponent), at: 0)
            let parent = current.deletingLastPathComponent()
            if isStop || parent.normalizedPath == current.normalizedPath { break }
            current = parent
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                    let isLast = index == components.count - 1
                    Button(component.title) { onSelect(component.url) }
                        .buttonStyle(.plain)
                        .fontWeight(isLast ? .semibold : .regular)
                        .foregroundStyle(isLast ? .primary : .secondary)
                        .disabled(isLast)
                }
            }
            .font(.callout)
        }
        .defaultScrollAnchor(.trailing)
    }
}
