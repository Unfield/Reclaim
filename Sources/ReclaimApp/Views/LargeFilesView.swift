import ReclaimCore
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingTrash: CleanupItem?
    @State private var selection: CleanupItem.ID?

    private let sizeOptions: [Int64] = [100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 5_000_000_000]

    var body: some View {
        @Bindable var model = model
        let selected = model.largeFiles.first { $0.id == selection }

        Group {
            if model.largeFiles.isEmpty {
                if model.isSearchingLargeFiles {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Searching \(model.largeFilesRoot.abbreviatedPath)…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Find Large Files", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Search a folder or disk for big files you might not need anymore.")
                    } actions: {
                        Button("Search \(model.largeFilesRoot.abbreviatedPath)") { Task { await model.findLargeFiles() } }
                            .primaryButtonStyle()
                    }
                }
            } else {
                Table(model.largeFiles, selection: $selection) {
                    TableColumn("Name") { item in
                        HStack(spacing: 8) {
                            FileIcon(url: item.url, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.url.deletingLastPathComponent().abbreviatedPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    TableColumn("Modified") { item in
                        Text(item.modified?.shortDate ?? "—").foregroundStyle(.secondary)
                    }
                    .width(110)
                    TableColumn("Size") { item in
                        SizeText(bytes: item.size).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)
                }
                .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
                    if let item = model.largeFiles.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") { AppModel.revealInFinder(item.url) }
                        Divider()
                        Button("Move to Trash…") { pendingTrash = item }
                    }
                } primaryAction: { ids in
                    ids.forEach(AppModel.revealInFinder)
                }
            }
        }
        .topBar {
            HStack(spacing: 10) {
                LocationMenu(current: model.largeFilesRoot) {
                    model.largeFilesRoot = $0
                    model.largeFiles = []
                }
                Picker("Larger than", selection: $model.largeFilesMinimum) {
                    ForEach(sizeOptions, id: \.self) { Text(ByteSize.format($0)).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Search") { Task { await model.findLargeFiles() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSearchingLargeFiles)
            }
        }
        .bottomBar {
            ActivityIndicator(isActive: model.isSearchingLargeFiles)
            Text(model.largeFiles.isEmpty
                ? "Skips hidden files, app bundles, node_modules and .git"
                : "\(model.largeFiles.count) files · \(ByteSize.format(model.largeFiles.reduce(0) { $0 + $1.size }))")
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
        .navigationTitle("Large Files")
        .confirmationDialog(
            "Move \(pendingTrash?.name ?? "") to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { item in
            Button("Move to Trash", role: .destructive) { model.trashLargeFile(item) }
        } message: { item in
            Text("\(item.url.abbreviatedPath) (\(ByteSize.format(item.size)))")
        }
    }
}
