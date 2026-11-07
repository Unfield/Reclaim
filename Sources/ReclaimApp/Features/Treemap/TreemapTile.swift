import ReclaimCore
import SwiftUI

/// One rectangle in the treemap: a folder entry, or the "Other" tile that collects tiny items.
struct TreemapTile: Identifiable, Equatable {
    enum ID: Hashable {
        case entry(URL)
        case other
    }

    enum Kind: Equatable {
        case entry(FolderEntry)
        case other(ids: Set<URL>)
    }

    let kind: Kind
    let size: Int64

    var id: ID {
        switch kind {
        case .entry(let entry): .entry(entry.url)
        case .other: .other
        }
    }

    var entry: FolderEntry? {
        if case .entry(let entry) = kind { return entry }
        return nil
    }

    var title: String {
        switch kind {
        case .entry(let entry): entry.name
        case .other(let ids): String(localized: "Other (\(ids.count) items)")
        }
    }

    /// For narrow tiles, where "Other (123 items)" would be truncated into something unreadable.
    var compactTitle: String {
        switch kind {
        case .entry(let entry): entry.name
        case .other: String(localized: "Other")
        }
    }

    func contains(_ id: URL?) -> Bool {
        guard let id else { return false }
        switch kind {
        case .entry(let entry): return entry.url == id
        case .other(let ids): return ids.contains(id)
        }
    }

    var tooltip: String {
        switch kind {
        case .entry(let entry): "\(entry.url.abbreviatedPath)\n\(ByteSize.format(size))"
        case .other(let ids): String(localized: "\(ids.count) smaller items") + "\n" + ByteSize.format(size)
        }
    }

    var accessibilityLabel: String {
        switch kind {
        case .entry(let entry): "\(entry.name), \(entry.isFolder ? String(localized: "folder") : String(localized: "file")), \(ByteSize.format(size))"
        case .other(let ids): String(localized: "\(ids.count) smaller items") + ", " + ByteSize.format(size)
        }
    }

    /// Stable per name (folders) or per file extension (files), so colors never shift between refreshes and
    /// files of one kind share a color.
    var tint: Color {
        guard let entry else { return .gray }
        let ext = entry.url.pathExtension
        let key = entry.isFolder || ext.isEmpty ? entry.name : "." + ext
        return Self.palette[Treemap.stableIndex(for: key, count: Self.palette.count)]
    }

    /// Hues picked to look evenly spaced (a plain color wheel is mostly green, and the system colors cluster
    /// around blue). Tiles draw them translucently over an opaque base, which adapts them to light and dark mode.
    private static let palette: [Color] = [0.0, 0.07, 0.13, 0.22, 0.34, 0.46, 0.53, 0.6, 0.67, 0.76, 0.85, 0.93].map {
        Color(hue: $0, saturation: 0.7, brightness: 0.92)
    }
}

/// The tiles for a list of entries: measured entries largest first, tiny ones grouped into "Other".
struct TreemapContent {
    /// Items under this share of the total share one "Other" tile.
    static let otherThreshold = 0.005

    let tiles: [TreemapTile]
    /// Entries still being measured (not shown yet).
    let pendingCount: Int
    let totalCount: Int

    init(entries: [FolderEntry]) {
        // Sorting here (with the name as a tie-breaker) makes the picture independent of the order sizes arrive in.
        let measured = entries
            .filter { $0.size != nil }
            .sorted { ($0.size ?? 0, $1.name) > ($1.size ?? 0, $0.name) }
        let (kept, grouped) = Treemap.groupSmallItems(measured.map { Double($0.size ?? 0) }, minimumFraction: Self.otherThreshold)

        var tiles = kept.map { TreemapTile(kind: .entry(measured[$0]), size: measured[$0].size ?? 0) }
        if !grouped.isEmpty {
            tiles.append(TreemapTile(
                kind: .other(ids: Set(grouped.map { measured[$0].url })),
                size: grouped.reduce(0) { $0 + (measured[$1].size ?? 0) }
            ))
        }
        self.tiles = tiles
        pendingCount = entries.count - measured.count
        totalCount = entries.count
    }

    var totalSize: Int64 { tiles.reduce(0) { $0 + $1.size } }

    func frames(in rect: CGRect) -> [CGRect] {
        Treemap.layout(tiles.map { Double($0.size) }, in: rect)
    }
}

struct TreemapTileView: View {
    let tile: TreemapTile
    let size: CGSize
    let isSelected: Bool
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var isFolder: Bool { tile.entry?.isFolder ?? false }

    private var cornerRadius: CGFloat { min(6, min(size.width, size.height) / 4) }

    /// Folders get a stronger tint than files, so they stand out as the things you can drill into.
    private var fillOpacity: Double {
        let dark = colorScheme == .dark
        let base: Double = switch tile.kind {
        case .other: dark ? 0.3 : 0.18
        case .entry: isFolder ? (dark ? 0.6 : 0.42) : (dark ? 0.38 : 0.26)
        }
        return isHovered ? base + 0.14 : base
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            // An opaque base keeps tiles solid under Liquid Glass bars and in both appearances.
            shape.fill(Color(nsColor: .controlBackgroundColor))
            shape.fill(tile.tint.opacity(fillOpacity))
            shape.fill(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.06 : 0.18), .clear], startPoint: .top, endPoint: .bottom))
            label
        }
        .overlay {
            shape.strokeBorder(tile.tint.opacity(isHovered ? 0.85 : 0.4), lineWidth: isHovered ? 1.5 : 0.5)
        }
        .overlay {
            if isSelected {
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
                if min(size.width, size.height) > 12 {
                    shape.inset(by: 3).strokeBorder(Color(nsColor: .controlBackgroundColor).opacity(0.85), lineWidth: 1)
                }
            }
        }
        .contentShape(shape)
    }

    @ViewBuilder
    private var label: some View {
        let showsText = size.width >= 36 && size.height >= 20
        if showsText {
            let isLarge = size.width >= 220 && size.height >= 110
            let showsSize = size.height >= (isLarge ? 54 : 36) && size.width >= 48
            let showsIcon = size.width >= 64
            VStack(alignment: .leading, spacing: isLarge ? 3 : 1) {
                HStack(spacing: 5) {
                    if showsIcon { icon(size: isLarge ? 18 : 14) }
                    // One line, truncated in the middle so file extensions stay visible.
                    Text(size.width >= 130 ? tile.title : tile.compactTitle)
                        .font(isLarge ? .title3.weight(.semibold) : .callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if showsSize {
                    SizeText(bytes: tile.size)
                        .font(isLarge ? .callout : .caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, isLarge ? 10 : 6)
            .padding(.vertical, isLarge ? 8 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        switch tile.kind {
        case .other:
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
        case .entry(let entry):
            if entry.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(tile.tint)
            } else {
                FileIcon(url: entry.url, size: size)
            }
        }
    }
}
