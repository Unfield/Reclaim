import Charts
import ReclaimCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DisksSection()

                if model.inaccessibleCount > 0 {
                    FullDiskAccessBanner(count: model.inaccessibleCount)
                }

                ReclaimableSummary()

                if model.scans.isEmpty {
                    PlaceholderSection()
                } else {
                    ForEach(CategoryGroup.allCases, id: \.self) { group in
                        let scans = model.scans.filter { $0.category.group == group }
                        if !scans.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(title: group.title, trailing: ByteSize.format(scans.reduce(0) { $0 + $1.totalSize }))
                                Card(padding: 0) {
                                    ForEach(scans) { scan in
                                        CategoryRow(scan: scan)
                                        if scan.id != scans.last?.id { Divider().padding(.leading, 84) }
                                    }
                                }
                            }
                        }
                    }
                }

                if !model.visibleTools.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: String(localized: "Maintenance"))
                        Card(padding: 0) {
                            ForEach(model.visibleTools, id: \.id) { tool in
                                ToolRow(tool: tool)
                                if tool.id != model.visibleTools.last?.id { Divider().padding(.leading, 84) }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .bottomBar {
            CleanupMethodPicker(method: $model.cleanupMethod)
            Spacer()
            ActivityIndicator(isActive: model.isCleaning)
            Text("\(ByteSize.format(model.totalSelectedSize)) selected")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Clean Up…") { confirming = true }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasSelection || model.isCleaning || model.isScanning)
        }
        .navigationTitle("Overview")
        .confirmationDialog("Clean up \(ByteSize.format(model.totalSelectedSize))?", isPresented: $confirming) {
            Button(model.cleanupMethod == .moveToTrash ? "Clean Up" : "Delete", role: .destructive) {
                Task { await model.cleanSelected() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        var lines = model.scans
            .filter { !model.selectedItems(in: $0).isEmpty }
            .map { String(localized: "\($0.category.name): \(ByteSize.format(model.selectedSize(in: $0)))") }
        lines += model.tools
            .filter { model.selectedTools.contains($0.id) }
            .map { String(localized: "\($0.name): \(model.toolReclaimable($0.id).map(ByteSize.format) ?? String(localized: "all items"))") }
        if model.cleanupMethod == .moveToTrash {
            lines.append("\n" + String(localized: "Files are moved to the Trash. Tool cleanups (Homebrew, Docker, snapshots) are permanent."))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Disks

private struct DisksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: model.volumes.count > 1 ? String(localized: "Disks") : String(localized: "Disk"),
                trailing: model.volumes.count > 1
                    ? String(localized: "\(ByteSize.format(model.volumes.reduce(0) { $0 + $1.availableForImportantUsage })) free in total")
                    : nil
            )
            Card(padding: 0) {
                if model.volumes.isEmpty {
                    DiskPlaceholder().padding(16)
                }
                ForEach(model.volumes) { volume in
                    DiskRow(volume: volume).padding(16)
                    if volume.id != model.volumes.last?.id { Divider().padding(.leading, 60) }
                }
            }
        }
    }
}

private struct DiskPlaceholder: View {
    var body: some View {
        DiskRow(volume: VolumeInfo(
            url: URL(filePath: "/"), name: "Macintosh HD", totalCapacity: 500_000_000_000,
            availableCapacity: 200_000_000_000, availableForImportantUsage: 200_000_000_000, kind: .startup
        ))
        .redacted(reason: .placeholder)
    }
}

// MARK: - Summary with chart

private struct ChartSlice: Identifiable {
    let id: String
    let name: String
    let size: Int64
}

private struct ReclaimableSummary: View {
    @Environment(AppModel.self) private var model

    private var slices: [ChartSlice] {
        var all = model.scans.map { ChartSlice(id: $0.id, name: $0.category.name, size: $0.totalSize) }
        all += model.tools.compactMap { tool in
            model.toolReclaimable(tool.id).map { ChartSlice(id: tool.id, name: tool.name, size: $0) }
        }
        all = all.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard all.count > 6 else { return all }
        let other = all.dropFirst(5).reduce(Int64(0)) { $0 + $1.size }
        return Array(all.prefix(5)) + [ChartSlice(id: "other", name: String(localized: "Other"), size: other)]
    }

    private var isWorking: Bool {
        model.isScanning || model.tools.contains { model.toolState($0.id).isLoading }
    }

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reclaimable")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(ByteSize.format(model.totalReclaimable))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Label("\(ByteSize.format(model.safeReclaimable)) is safe to remove", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                        .opacity(model.safeReclaimable > 0 || model.lastScanDate != nil ? 1 : 0)
                    HStack(spacing: 6) {
                        ActivityIndicator(isActive: isWorking)
                        Text(isWorking
                            ? String(localized: "Scanning…")
                            : model.lastScanDate.map { String(localized: "Last scan \($0.formatted(date: .omitted, time: .shortened))") } ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Size", slice.size), innerRadius: .ratio(0.64), angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(ChartPalette.color(for: slice.id))
                    }
                    .chartLegend(.hidden)
                    if slices.isEmpty {
                        Circle().strokeBorder(.quaternary, lineWidth: 22)
                    }
                }
                .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(ChartPalette.color(for: slice.id)).frame(width: 8, height: 8)
                            Text(slice.name).lineLimit(1)
                            Spacer(minLength: 8)
                            SizeText(bytes: slice.size).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(width: 250, alignment: .leading)
            }
            .frame(minHeight: 150)
        }
    }
}

// MARK: - Rows

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let scan: CategoryScan

    var body: some View {
        let selectedCount = model.selectedItems(in: scan).count
        let allSelected = !scan.items.isEmpty && selectedCount == scan.items.count
        let partiallySelected = selectedCount > 0 && !allSelected

        OverviewRow(
            isOn: Binding(get: { allSelected }, set: { model.selectAll($0, in: scan) }),
            isMixed: partiallySelected,
            isEnabled: !scan.items.isEmpty,
            symbol: scan.category.symbolName,
            tint: ChartPalette.color(for: scan.id),
            title: scan.category.name,
            safety: scan.category.safety,
            subtitle: scan.category.summary,
            subtitleIsWarning: false,
            isBusy: false,
            value: scan.items.isEmpty ? OverviewRow.empty : ByteSize.format(scan.totalSize),
            secondaryValue: partiallySelected ? String(localized: "\(ByteSize.format(model.selectedSize(in: scan))) selected") : nil
        ) {
            model.selection = .category(scan.id)
        }
    }
}

private struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: any MaintenanceTool

    var body: some View {
        let state = model.toolState(tool.id)
        let isReady = state.status?.isReady == true
        var subtitle = tool.summary
        var warning = false
        if case .unavailable(let reason) = state.status?.availability {
            subtitle = reason
            warning = true
        }

        let value: String
        if let size = model.toolReclaimable(tool.id) {
            value = size > 0 ? ByteSize.format(size) : OverviewRow.empty
        } else if let status = state.status, status.isReady {
            value = status.entries.isEmpty ? OverviewRow.empty : String(localized: "\(status.entries.count) items")
        } else {
            value = "—"
        }

        return OverviewRow(
            isOn: Binding(get: { model.selectedTools.contains(tool.id) }, set: { model.setToolSelected($0, toolID: tool.id) }),
            isMixed: false,
            isEnabled: isReady && state.status?.entries.isEmpty == false,
            symbol: ToolSymbols.name(for: tool.id),
            tint: ChartPalette.color(for: tool.id),
            title: tool.name,
            safety: tool.safety,
            subtitle: subtitle,
            subtitleIsWarning: warning,
            isBusy: state.isLoading || state.isCleaning,
            value: value,
            secondaryValue: nil
        ) {
            model.selection = .tool(tool.id)
        }
    }
}

/// Shared layout for category and tool rows, with fixed column widths so values don't jump.
private struct OverviewRow: View {
    static let empty = String(localized: "Empty")

    @Binding var isOn: Bool
    let isMixed: Bool
    let isEnabled: Bool
    let symbol: String
    let tint: Color
    let title: String
    let safety: SafetyLevel
    let subtitle: String
    let subtitleIsWarning: Bool
    let isBusy: Bool
    let value: String
    let secondaryValue: String?
    let showDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!isEnabled)
                .frame(width: 20)
                .help(isMixed ? "Some items selected" : "")

            IconTile(systemName: symbol, tint: tint, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    SafetyBadge(level: safety)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            ZStack(alignment: .trailing) {
                ActivityIndicator(isActive: isBusy)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .monospacedDigit()
                        .foregroundStyle(value == Self.empty || value == "—" ? .secondary : .primary)
                    if let secondaryValue {
                        Text(secondaryValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(isBusy ? 0 : 1)
            }
            .frame(width: 110, alignment: .trailing)

            Button(action: showDetails) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show details")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: showDetails)
    }
}

private struct PlaceholderSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: CategoryGroup.system.title)
            Card(padding: 0) {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 16, height: 16)
                        RoundedRectangle(cornerRadius: 9).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Category name")
                            Text("A description of what is stored here").font(.caption)
                        }
                        Spacer()
                        Text("00.0 GB")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if index < 3 { Divider().padding(.leading, 84) }
                }
            }
            .redacted(reason: .placeholder)
        }
    }
}
