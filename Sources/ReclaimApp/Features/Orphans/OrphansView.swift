import AppKit
import ReclaimCore
import SwiftUI

struct OrphansView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var highlighted: LeftoverRow.ID?
    @State private var confirmingRemoval = false

    private var orphans: OrphansModel { model.orphans }

    private var visibleGroups: [LeftoverGroup] {
        guard !search.isEmpty else { return orphans.groups }
        return orphans.groups.filter { group in
            group.name.localizedCaseInsensitiveContains(search)
                || group.locations.contains { $0.bundleID.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        let groups = visibleGroups

        Group {
            if !orphans.hasScanned {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for leftovers…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if orphans.groups.isEmpty {
                ContentUnavailableView(
                    "No Leftovers",
                    systemImage: "checkmark.circle",
                    description: Text("Apps you removed didn't leave any data behind.")
                )
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                table(groups)
            }
        }
        .topBar { topBar }
        .bottomBar { bottomBar }
        .navigationTitle("App Leftovers")
        .task {
            if !orphans.hasScanned { await orphans.scan() }
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirmingRemoval) {
            Button("Move to Trash", role: .destructive) {
                Task { await orphans.removeSelected(using: model) }
            }
        } message: {
            Text(confirmationMessage)
        }
        .alert(
            "Some items couldn't be removed",
            isPresented: Binding(get: { !orphans.removalFailures.isEmpty }, set: { if !$0 { orphans.removalFailures = [] } })
        ) {
            Button("OK") { orphans.removalFailures = [] }
        } message: {
            Text(orphans.removalFailures.prefix(5).joined(separator: "\n"))
        }
    }

    // MARK: Bars

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 10) {
            SafetyBadge(level: .review)
            Text("Data from apps that are no longer installed. It can include settings, so check before removing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            SearchField(text: $search, prompt: "Search leftovers")
                .frame(width: 200)

            Button {
                Task { await orphans.scan() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Rescan")
            .disabled(orphans.isScanning || orphans.isRemoving)
        }
        if !orphans.unreadableFolders.isEmpty {
            UnreadableFoldersBanner(folders: orphans.unreadableFolders)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        let selected = orphans.selectedLocations
        let isBusy = orphans.isScanning || orphans.isRemoving || !orphans.measuring.isEmpty

        ActivityIndicator(isActive: isBusy)
        Group {
            if selected.isEmpty {
                let total = orphans.groups.reduce(Int64(0)) { $0 + $1.size }
                Text("\(orphans.groups.count) apps · \(ByteSize.format(total))")
            } else {
                Text("\(selected.count) selected · \(ByteSize.format(orphans.selectedSize))")
            }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Spacer()
        Button("Reveal in Finder") { reveal(highlighted) }
            .secondaryButtonStyle()
            .disabled(highlighted == nil)
        Button("Move to Trash…") { confirmingRemoval = true }
            .primaryButtonStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty || orphans.isRemoving)
    }

    // MARK: Table

    private func table(_ groups: [LeftoverGroup]) -> some View {
        Table(of: LeftoverRow.self, selection: $highlighted) {
            TableColumn("") { row in
                checkbox(for: row)
            }
            .width(22)

            TableColumn("App") { row in
                switch row {
                case .group(let group):
                    HStack(spacing: 8) {
                        IconTile(systemName: "app.dashed", tint: .secondary, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).lineLimit(1)
                            Text(group.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                case .location(let location):
                    HStack(spacing: 8) {
                        Image(systemName: location.kind.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.kind.title).lineLimit(1)
                            Text(location.url.abbreviatedPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .help(location.url.abbreviatedPath)
                }
            }

            TableColumn("Modified") { row in
                let date = switch row {
                case .group(let group): group.lastModified
                case .location(let location): location.modified
                }
                Text(date?.shortDate ?? "—").foregroundStyle(.secondary)
            }
            .width(110)

            TableColumn("Size") { row in
                sizeCell(for: row).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        } rows: {
            ForEach(groups) { group in
                DisclosureTableRow(LeftoverRow.group(group), isExpanded: expansion(of: group)) {
                    ForEach(group.locations) { location in
                        TableRow(LeftoverRow.location(location))
                    }
                }
            }
        }
        .contextMenu(forSelectionType: LeftoverRow.ID.self) { ids in
            if let id = ids.first, let row = row(for: id) {
                Button("Reveal in Finder") { reveal(id) }
                if case .group(let group) = row, group.hasUnmeasuredLocations {
                    Button("Measure Containers") { orphans.measureAll(in: group) }
                } else if case .location(let location) = row, location.size == nil {
                    Button("Measure") { orphans.measure(location) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { reveal(id) }
        }
    }

    @ViewBuilder
    private func checkbox(for row: LeftoverRow) -> some View {
        switch row {
        case .group(let group):
            let sources = group.locations.map { location in
                Binding(get: { orphans.isSelected(location) }, set: { orphans.setSelected(location, $0) })
            }
            Toggle(sources: sources, isOn: \.self) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Select all of \(group.name)'s leftovers")
        case .location(let location):
            Toggle("", isOn: Binding(get: { orphans.isSelected(location) }, set: { orphans.setSelected(location, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func sizeCell(for row: LeftoverRow) -> some View {
        switch row {
        case .group(let group):
            if group.hasUnmeasuredLocations && group.locations.allSatisfy({ $0.size == nil }) {
                SizeText(bytes: nil, placeholder: "Unknown")
                    .foregroundStyle(.secondary)
                    .help("App containers aren't measured until you select them or choose Measure.")
            } else if group.hasUnmeasuredLocations {
                SizeText(bytes: group.size)
                    .help("Doesn't include app containers until you select them or choose Measure.")
            } else {
                SizeText(bytes: group.size)
            }
        case .location(let location):
            if let size = location.size {
                SizeText(bytes: size).foregroundStyle(.secondary)
            } else if orphans.measuring.contains(location.url) {
                ProgressView().controlSize(.small)
            } else {
                Button("Measure") { orphans.measure(location) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Measuring another app's container may make macOS ask for permission.")
            }
        }
    }

    // MARK: Helpers

    private func expansion(of group: LeftoverGroup) -> Binding<Bool> {
        Binding(
            get: { orphans.expandedGroups.contains(group.id) },
            set: { if $0 { orphans.expandedGroups.insert(group.id) } else { orphans.expandedGroups.remove(group.id) } }
        )
    }

    private func row(for id: LeftoverRow.ID) -> LeftoverRow? {
        for group in orphans.groups {
            if LeftoverRow.group(group).id == id { return .group(group) }
            if let location = group.locations.first(where: { LeftoverRow.location($0).id == id }) { return .location(location) }
        }
        return nil
    }

    private func reveal(_ id: LeftoverRow.ID?) {
        guard let id, let row = row(for: id) else { return }
        switch row {
        case .group(let group):
            NSWorkspace.shared.activateFileViewerSelecting(group.locations.map(\.url))
        case .location(let location):
            AppModel.revealInFinder(location.url)
        }
    }

    private var confirmationTitle: String {
        let groups = orphans.selectedGroups
        return groups.count == 1
            ? "Move leftovers of \(groups[0].name) to the Trash?"
            : "Move leftovers of \(groups.count) apps to the Trash?"
    }

    private var confirmationMessage: String {
        let count = orphans.selectedLocations.count
        let items = count == 1 ? "1 item" : "\(count) items"
        return "\(items), \(ByteSize.format(orphans.selectedSize)). Settings and data in them will be gone if you reinstall the app. You can put them back from Recently Removed."
    }
}

/// Like `FullDiskAccessBanner`, but names the Library folders that couldn't be listed.
private struct UnreadableFoldersBanner: View {
    let folders: [URL]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Couldn't read \(folders.map(\.lastPathComponent).formatted(.list(type: .and))). Grant Full Disk Access for complete results.")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button("Open Settings") { AppModel.openFullDiskAccessSettings() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A table row: an app's group of leftovers, or one location inside it.
private enum LeftoverRow: Identifiable, Hashable {
    case group(LeftoverGroup)
    case location(LeftoverLocation)

    var id: String {
        switch self {
        case .group(let group): "app:" + group.bundleID
        case .location(let location): location.url.path(percentEncoded: false)
        }
    }
}

private extension LeftoverKind {
    var symbolName: String {
        switch self {
        case .applicationSupport: "folder"
        case .caches: "archivebox"
        case .containers: "shippingbox"
        case .preferences: "gearshape"
        case .savedState: "macwindow"
        case .httpStorages: "network"
        case .webKit: "safari"
        case .logs: "doc.plaintext"
        case .applicationScripts: "applescript"
        case .cookies: "globe"
        }
    }
}
