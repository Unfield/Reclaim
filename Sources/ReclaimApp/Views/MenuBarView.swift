import AppKit
import ReclaimCore
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel
    @AppStorage(Prefs.menuBarShowsFreeSpace) private var showsFreeSpace = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isLowOnSpace ? "exclamationmark.triangle.fill" : "internaldrive")
            if showsFreeSpace, let volume = model.volume {
                Text(ByteSize.format(volume.availableForImportantUsage))
            }
        }
    }
}

private struct MemoryRow: View {
    let stats: MemoryStats
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "memorychip", tint: stats.pressure.color, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory").fontWeight(.medium)
                    Text(stats.pressure.label)
                        .font(.caption)
                        .foregroundStyle(stats.pressure.color)
                    Spacer(minLength: 8)
                    Text("\(ByteSize.formatMemory(stats.used)) of \(ByteSize.formatMemory(stats.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(stats.pressure.color).frame(width: geometry.size.width * stats.usedFraction)
                    }
                }
                .frame(height: 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help("Show memory details")
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.volumes) { volume in
                    DiskRow(volume: volume, compact: true)
                }
                if model.isLowOnSpace {
                    Label("Your startup disk is running low on space.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if let memory = model.memory {
                    MemoryRow(stats: memory) {
                        model.selection = .memory
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                }
            }

            Divider()

            reclaimSection

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan")
                .disabled(model.isScanning || model.isCleaning)

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")

                Spacer()

                Button("Open Reclaim") {
                    openWindow(id: "main")
                    NSApp.activate()
                }

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Reclaim")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.updateVolume() }
        .task {
            while !Task.isCancelled {
                model.refreshMemoryStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var reclaimSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reclaimable").foregroundStyle(.secondary)
                Spacer()
                ActivityIndicator(isActive: model.isScanning)
                Text(model.lastScanDate == nil ? "—" : ByteSize.format(model.totalReclaimable))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            ForEach(topItems, id: \.id) { item in
                HStack(spacing: 8) {
                    Circle().fill(ChartPalette.color(for: item.id)).frame(width: 7, height: 7)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    SizeText(bytes: item.size).foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            if confirmingClean {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clean \(ByteSize.format(model.safeReclaimable)) of Safe items?")
                        .font(.callout.weight(.medium))
                    Text(model.cleanupMethod == .moveToTrash ? "Files go to the Trash. Homebrew cleanup is permanent." : "Items will be deleted permanently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { confirmingClean = false }
                            .secondaryButtonStyle()
                        Spacer()
                        Button("Clean Up") {
                            confirmingClean = false
                            Task { await model.cleanAllSafe() }
                        }
                        .primaryButtonStyle()
                    }
                }
            } else {
                Button {
                    if model.lastScanDate == nil {
                        Task { await model.refresh() }
                    } else {
                        confirmingClean = true
                    }
                } label: {
                    Text(primaryTitle).frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                .controlSize(.large)
                .disabled(model.isCleaning || model.isScanning || (model.lastScanDate != nil && model.safeReclaimable == 0))
            }

            if let report = model.lastReport, !confirmingClean {
                Label("Cleaned up \(ByteSize.format(report.total))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private var primaryTitle: String {
        if model.isCleaning { return String(localized: "Cleaning…") }
        if model.isScanning && model.lastScanDate == nil { return String(localized: "Scanning…") }
        if model.lastScanDate == nil { return String(localized: "Scan for Reclaimable Space") }
        return String(localized: "Clean Safe Items (\(ByteSize.format(model.safeReclaimable)))")
    }

    private struct TopItem {
        let id: String
        let name: String
        let size: Int64
    }

    private var topItems: [TopItem] {
        var items = model.scans.map { TopItem(id: $0.id, name: $0.category.name, size: $0.totalSize) }
        items += model.tools.compactMap { tool in
            model.toolReclaimable(tool.id).map { TopItem(id: tool.id, name: tool.name, size: $0) }
        }
        return Array(items.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(4))
    }
}
