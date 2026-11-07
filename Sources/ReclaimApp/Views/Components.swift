import AppKit
import ReclaimCore
import SwiftUI

// MARK: - Model presentation helpers

extension SafetyLevel {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        }
    }
}

extension CleanupCategory {
    var symbolName: String {
        if group == .otherDisks { return "trash" }
        switch id {
        case "user-caches": return "archivebox"
        case "user-logs": return "doc.plaintext"
        case "trash": return "trash"
        case "mail-downloads": return "envelope"
        case "ios-backups": return "iphone"
        case "xcode-derived-data": return "hammer"
        case "xcode-device-support": return "cable.connector"
        case "xcode-archives": return "tray.full"
        case "simulator-caches": return "ipad.and.iphone"
        case "package-caches": return "cube.box"
        case "old-downloads": return "arrow.down.circle"
        default: return "folder"
        }
    }
}

enum ToolSymbols {
    static func name(for id: String) -> String {
        switch id {
        case "homebrew": "mug"
        case "docker": "shippingbox"
        case "time-machine": "clock.arrow.circlepath"
        default: "wrench.and.screwdriver"
        }
    }
}

extension VolumeInfo {
    var symbolName: String {
        switch kind {
        case .startup, .internalDisk: "internaldrive"
        case .external: "externaldrive"
        case .network: "server.rack"
        case .diskImage: "opticaldiscdrive"
        }
    }

    var kindDescription: String {
        switch kind {
        case .startup: "Startup Disk"
        case .internalDisk: "Internal"
        case .external: "External"
        case .network: "Network"
        case .diskImage: "Disk Image"
        }
    }

    var usageTint: Color {
        usedFraction > 0.9 ? .red : usedFraction > 0.75 ? .orange : .accentColor
    }
}

extension InstalledApp {
    var sortDate: Date { lastActivity ?? .distantPast }
}

/// Fixed colors per chart slice, so colors don't shuffle as scan results arrive.
enum ChartPalette {
    /// Hand-picked so the items most likely to appear together never share a hue.
    private static let colors: [String: Color] = [
        "user-caches": .blue,
        "package-caches": .orange,
        "docker": .cyan,
        "homebrew": .green,
        "xcode-derived-data": .indigo,
        "xcode-device-support": .purple,
        "xcode-archives": .brown,
        "simulator-caches": .mint,
        "user-logs": .teal,
        "mail-downloads": .yellow,
        "ios-backups": .pink,
        "old-downloads": .red,
        "time-machine": .purple,
        "trash": .gray,
    ]

    static func color(for id: String) -> Color {
        colors[id] ?? .gray
    }
}

// MARK: - Layout primitives

/// The standard content container. Content stays opaque; glass is reserved for bars and controls.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A spinner that always occupies its space, so showing it never shifts the layout.
struct ActivityIndicator: View {
    let isActive: Bool

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isActive ? 1 : 0)
            .accessibilityHidden(!isActive)
    }
}

extension View {
    /// A bottom bar that uses the system's Liquid Glass bar treatment on macOS 26+.
    @ViewBuilder
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = HStack(spacing: 10) { bar() }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .controlSize(.large)
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom) { content }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    content.background(.bar)
                }
            }
        }
    }

    /// A header bar pinned above scrolling content (tables, lists). Content scrolls under it with the system edge effect.
    @ViewBuilder
    func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = VStack(alignment: .leading, spacing: 12) { bar() }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top) { content }
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    content.background(.bar)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    func primaryButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - Small components

struct SafetyBadge: View {
    let level: SafetyLevel

    var body: some View {
        Text(level.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(level.color)
            .background(level.color.opacity(0.14), in: Capsule())
            .help(level.explanation)
    }
}

struct SizeText: View {
    let bytes: Int64?
    var placeholder = "—"

    var body: some View {
        Text(bytes.map(ByteSize.format) ?? placeholder)
            .monospacedDigit()
    }
}

/// A file or app icon from the Finder.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct IconTile: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct DiskUsageBar: View {
    let volume: VolumeInfo
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let used = width * volume.usedFraction
            let purgeable = width * Double(volume.purgeableCapacity) / Double(max(1, volume.totalCapacity))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    Rectangle().fill(volume.usageTint).frame(width: max(0, used))
                    Rectangle().fill(volume.usageTint.opacity(0.35)).frame(width: max(0, min(purgeable, width - used)))
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .help("\(ByteSize.format(volume.usedCapacity)) used, \(ByteSize.format(volume.purgeableCapacity)) purgeable")
    }
}

/// One disk with its usage. Used on the overview and in the menu bar.
struct DiskRow: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: volume.symbolName, tint: volume.usageTint, size: compact ? 24 : 32)
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name).fontWeight(.medium).lineLimit(1)
                    if !compact {
                        Text([volume.kindDescription, volume.format].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("\(ByteSize.format(volume.availableForImportantUsage)) free")
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                DiskUsageBar(volume: volume, height: compact ? 5 : 8)
                if !compact {
                    Text("\(ByteSize.format(volume.usedCapacity)) of \(ByteSize.format(volume.totalCapacity)) used" + (volume.purgeableCapacity > 0 ? " · \(ByteSize.format(volume.purgeableCapacity)) purgeable" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if volume.isEjectable {
                Button {
                    model.eject(volume)
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .help("Eject \(volume.name)")
            }
        }
        .contextMenu {
            Button("Explore \(volume.name)") {
                model.explore(volume.url)
                model.selection = .explorer
            }
            Button("Show in Finder") { NSWorkspace.shared.open(volume.url) }
            if volume.isEjectable {
                Divider()
                Button("Eject") { model.eject(volume) }
            }
        }
    }
}

struct CleanupMethodPicker: View {
    @Binding var method: CleanupMethod

    var body: some View {
        Picker("Method", selection: $method) {
            Label("Move to Trash", systemImage: "trash").tag(CleanupMethod.moveToTrash)
            Label("Delete Immediately", systemImage: "xmark.bin").tag(CleanupMethod.deletePermanently)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// Lets the user jump to a disk, the home folder, or any folder.
struct LocationMenu: View {
    @Environment(AppModel.self) private var model
    let current: URL
    let onSelect: (URL) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect(FileManager.default.homeDirectoryForCurrentUser)
            } label: {
                Label("Home Folder", systemImage: "house")
            }
            Section("Disks") {
                ForEach(model.volumes) { volume in
                    Button {
                        onSelect(volume.url)
                    } label: {
                        Label(volume.name, systemImage: volume.symbolName)
                    }
                }
            }
            Divider()
            Button("Choose Folder…") {
                if let url = AppModel.chooseFolder(startingAt: current) { onSelect(url) }
            }
        } label: {
            Label(current.abbreviatedPath, systemImage: VolumeInfo.volume(containing: current, in: model.volumes)?.symbolName ?? "folder")
                .lineLimit(1)
                .truncationMode(.head)
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

struct FullDiskAccessBanner: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            Text("\(count) items couldn't be read. Grant Full Disk Access for complete results.")
                .font(.callout)
            Spacer()
            Button("Open Settings") { AppModel.openFullDiskAccessSettings() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Date {
    var shortDate: String { formatted(date: .abbreviated, time: .omitted) }
}
