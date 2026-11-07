import ReclaimCore
import SwiftUI

struct ICloudView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: [ICloudItem]?

    var body: some View {
        @Bindable var icloud = model.icloud
        let selected = icloud.selectedItems
        let selectedSize = selected.reduce(Int64(0)) { $0 + $1.size }

        Group {
            if icloud.availability == .unavailable {
                ContentUnavailableView {
                    Label("iCloud Drive Isn't Set Up", systemImage: "icloud.slash")
                } description: {
                    Text("Sign in to iCloud and turn on iCloud Drive in System Settings to free up space here.")
                }
            } else if icloud.scan == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for downloaded iCloud files…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if icloud.groups.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to Remove", systemImage: "checkmark.icloud")
                } description: {
                    Text("No downloaded files have gone unopened for \(icloud.days) days.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ICloudSummary(total: icloud.totalSize, downloaded: icloud.scan?.downloadedSize ?? 0)
                        ForEach(icloud.groups) { group in
                            ICloudGroupCard(group: group)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .topBar {
            HStack(spacing: 10) {
                Picker("Not opened in", selection: $icloud.days) {
                    ForEach(ICloudDrive.idleDayChoices, id: \.self) { days in
                        Text(days == 180 ? "6 months" : "\(days) days").tag(days)
                    }
                }
                .fixedSize()
                .disabled(icloud.availability == .unavailable)

                Spacer()

                Button {
                    Task { await icloud.rescan() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Rescan iCloud Drive")
                .disabled(icloud.isScanning || icloud.isEvicting)
            }
        }
        .bottomBar {
            ActivityIndicator(isActive: icloud.isScanning || icloud.isEvicting)
            Text(icloud.groups.isEmpty
                ? "Files stay in iCloud and download again when opened"
                : "\(fileCount(selected.count)) selected · \(ByteSize.format(selectedSize))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Remove Downloads…") { pendingRemoval = selected }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || icloud.isEvicting || icloud.isScanning)
        }
        .navigationTitle("iCloud Drive")
        .task { await icloud.loadIfNeeded() }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { items in
            Button("Remove Downloads") {
                Task { await icloud.removeDownloads(items, appModel: model) }
            }
        } message: { items in
            Text("This frees \(ByteSize.format(items.reduce(0) { $0 + $1.size })) on this Mac. Nothing is deleted from iCloud: the files stay in iCloud Drive and download again when you open them.")
        }
        .alert(
            resultTitle,
            isPresented: Binding(get: { icloud.lastResult != nil }, set: { if !$0 { icloud.lastResult = nil } }),
            presenting: icloud.lastResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(resultMessage(result))
        }
    }

    private var removalTitle: String {
        let count = pendingRemoval?.count ?? 0
        return count == 1 ? "Remove the download of 1 file?" : "Remove the downloads of \(fileCount(count))?"
    }

    private var resultTitle: String {
        guard let result = model.icloud.lastResult else { return "" }
        return result.count > 0 ? "Freed \(ByteSize.format(result.freed))" : "No downloads were removed"
    }

    private func resultMessage(_ result: ICloudModel.EvictionResult) -> String {
        var lines = [String]()
        if result.count > 0 {
            lines.append("Removed the downloads of \(fileCount(result.count)). They're still in iCloud Drive.")
        }
        if !result.failures.isEmpty {
            lines.append("\n\(fileCount(result.failures.count)) skipped:")
            lines += result.failures.prefix(5).map { "• \($0)" }
            if result.failures.count > 5 { lines.append("…and \(result.failures.count - 5) more") }
        }
        return lines.joined(separator: "\n")
    }
}

private func fileCount(_ count: Int) -> String {
    count == 1 ? "1 file" : "\(count) files"
}

// MARK: - Summary

private struct ICloudSummary: View {
    let total: Int64
    let downloaded: Int64

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 18) {
                IconTile(systemName: "icloud.and.arrow.down", tint: .blue, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free up space without deleting anything")
                        .font(.headline)
                    Text("These files are safely stored in iCloud but also take up space on this Mac. Removing the download keeps them in iCloud Drive, and they download again when you open them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("If Desktop & Documents sync is on, files in those folders are included too.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteSize.format(total))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(ByteSize.format(downloaded)) downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(minWidth: 140, alignment: .trailing)
            }
        }
    }
}

// MARK: - Groups

private struct ICloudGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: ICloudGroup
    /// Big folders can hold thousands of files; show the largest first and the rest on request.
    @State private var visibleCount = 50

    var body: some View {
        let icloud = model.icloud
        let isExpanded = icloud.expanded.contains(group.id)
        let selectedSize = icloud.selectedItems(in: group).reduce(Int64(0)) { $0 + $1.size }

        Card(padding: 0) {
            HStack(spacing: 10) {
                Toggle(sources: group.items.map { selection(for: $0) }, isOn: \.self) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                FileIcon(url: group.folder.url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.folder.name).fontWeight(.medium).lineLimit(1)
                    Text(fileCount(group.items.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                Text(selectedSize == group.totalSize ? "" : "\(ByteSize.format(selectedSize)) of")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                SizeText(bytes: group.totalSize)
                    .fontWeight(.medium)
                    .frame(width: 80, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { icloud.toggleExpanded(group) } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Hides the files" : "Shows the files")
            .contextMenu {
                Button("Show in Finder") { AppModel.revealInFinder(group.folder.url) }
            }

            if isExpanded {
                Divider()
                let shown = group.items.prefix(visibleCount)
                ForEach(shown) { item in
                    ICloudItemRow(item: item, isSelected: selection(for: item))
                    if item.id != shown.last?.id || group.items.count > visibleCount {
                        Divider().padding(.leading, 70)
                    }
                }
                if group.items.count > visibleCount {
                    Button("Show All \(group.items.count) Files") { visibleCount = group.items.count }
                        .buttonStyle(.link)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func selection(for item: ICloudItem) -> Binding<Bool> {
        let icloud = model.icloud
        return Binding(get: { icloud.isSelected(item) }, set: { icloud.setSelected($0, item) })
    }
}

private struct ICloudItemRow: View {
    let item: ICloudItem
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
            FileIcon(url: item.url, size: 20)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if !item.subfolderPath.isEmpty {
                    Text(item.subfolderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 12)
            Text(item.lastUsed.map { "Opened \($0.shortDate)" } ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            SizeText(bytes: item.size)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Color.clear.frame(width: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Show in Finder") { AppModel.revealInFinder(item.url) }
        }
    }
}
