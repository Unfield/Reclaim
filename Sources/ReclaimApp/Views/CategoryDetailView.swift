import ReclaimCore
import SwiftUI

struct CategoryDetailView: View {
    @Environment(AppModel.self) private var model
    let scan: CategoryScan
    @State private var confirming = false
    @State private var tableSelection = Set<URL>()

    var body: some View {
        @Bindable var model = model
        let selectedSize = model.selectedSize(in: scan)

        Group {
            if scan.items.isEmpty {
                ContentUnavailableView("Nothing to Clean", systemImage: "checkmark.circle", description: Text("This category is empty."))
            } else {
                Table(scan.items, selection: $tableSelection) {
                    TableColumn("") { item in
                        Toggle("", isOn: Binding(
                            get: { model.isSelected(item, in: scan) },
                            set: { model.setSelected($0, item: item, in: scan) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    }
                    .width(22)
                    TableColumn("Name") { item in
                        HStack(spacing: 8) {
                            FileIcon(url: item.url)
                            Text(item.name).lineLimit(1)
                        }
                        .help(item.url.abbreviatedPath)
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
                .contextMenu(forSelectionType: URL.self) { urls in
                    Button("Reveal in Finder") { urls.forEach(AppModel.revealInFinder) }
                    Divider()
                    Button("Check Selected") { setChecked(true, urls) }
                    Button("Uncheck Selected") { setChecked(false, urls) }
                    Divider()
                    Button("Never Clean This") {
                        var exclusions = Exclusions.load()
                        urls.forEach { exclusions.add($0) }
                        try? exclusions.save()
                        Task { await model.scanCategories() }
                    }
                } primaryAction: { urls in
                    urls.forEach(AppModel.revealInFinder)
                }
            }
        }
        .topBar {
            DetailHeader(
                title: scan.category.name,
                symbol: scan.category.symbolName,
                tint: ChartPalette.color(for: scan.id),
                safety: scan.category.safety,
                summary: scan.category.summary,
                size: scan.totalSize
            )
            if scan.category.deletesPermanently {
                Label("Items here are deleted permanently.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if scan.inaccessibleCount > 0 {
                FullDiskAccessBanner(count: scan.inaccessibleCount)
            }
        }
        .bottomBar {
            Menu("Select") {
                Button("Select All") { model.selectAll(true, in: scan) }
                Button("Select None") { model.selectAll(false, in: scan) }
            }
            .fixedSize()
            if !scan.category.deletesPermanently {
                CleanupMethodPicker(method: $model.cleanupMethod)
            }
            Spacer()
            ActivityIndicator(isActive: model.isCleaning)
            Text("\(ByteSize.format(selectedSize)) selected")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Clean Selected…") { confirming = true }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSize == 0 || model.isCleaning || model.isScanning)
        }
        .navigationTitle(scan.category.name)
        .confirmationDialog(
            "Clean \(ByteSize.format(selectedSize)) from \(scan.category.name)?",
            isPresented: $confirming
        ) {
            let permanent = scan.category.deletesPermanently || model.cleanupMethod == .deletePermanently
            Button(permanent ? "Delete" : "Move to Trash", role: .destructive) {
                Task { await model.cleanCategory(scan.id) }
            }
        } message: {
            Text("\(model.selectedItems(in: scan).count) items will be removed.")
        }
    }

    private func setChecked(_ checked: Bool, _ urls: Set<URL>) {
        for item in scan.items where urls.contains(item.url) {
            model.setSelected(checked, item: item, in: scan)
        }
    }
}

/// Shared header for detail screens.
struct DetailHeader: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    let safety: SafetyLevel
    let summary: String
    let size: Int64?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemName: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.title2.weight(.semibold))
                    SafetyBadge(level: safety)
                }
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(safety.explanation)
                    .font(.caption)
                    .foregroundStyle(safety.color)
            }
            Spacer(minLength: 16)
            Text(size.map(ByteSize.format) ?? "")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }
}
