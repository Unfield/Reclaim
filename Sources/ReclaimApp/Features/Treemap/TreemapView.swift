import ReclaimCore
import SwiftUI

/// A treemap of a folder's contents for the Space Explorer.
///
/// Entries appear as they're measured. Click selects (shared with the bottom bar's actions), double-click opens,
/// and the arrow keys move the selection between neighboring tiles.
struct TreemapView: View {
    let entries: [FolderEntry]
    @Binding var selection: FolderEntry.ID?
    /// Called when a folder should be opened (e.g. double-click).
    let onOpen: (FolderEntry) -> Void
    /// Offers "Move to Trash…" in a tile's context menu when set.
    var onTrash: ((FolderEntry) -> Void)? = nil

    @State private var hovered: TreemapTile.ID?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Gap between the treemap and the bars or window edges; tiles add 1 pt on each side for 2 pt gaps between them.
    private let margin: CGFloat = 7

    var body: some View {
        let content = TreemapContent(entries: entries)

        Group {
            if content.tiles.isEmpty || content.totalSize == 0 {
                if content.pendingCount > 0 {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Measuring \(content.pendingCount) items…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Nothing to Show",
                        systemImage: "square.dashed",
                        description: Text("The items in this folder don't take up any space.")
                    )
                }
            } else {
                treemap(content)
            }
        }
        // In a typical wide window the largest tile fills the left column, so bottom leading covers only its empty
        // corner rather than the small tiles' labels in the bottom right.
        .overlay(alignment: .bottomLeading) {
            if content.pendingCount > 0 && !content.tiles.isEmpty {
                MeasuringBadge(remaining: content.pendingCount)
                    .padding(margin + 10)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: content.pendingCount == 0)
    }

    private func treemap(_ content: TreemapContent) -> some View {
        // GeometryReader stays inside the safe area, so the top and bottom bars never cover tiles.
        GeometryReader { geometry in
            let frames = content.frames(in: CGRect(origin: .zero, size: geometry.size))
            let laidOut = zip(content.tiles, frames).filter { $0.1.width >= 2 && $0.1.height >= 2 }

            ZStack(alignment: .topLeading) {
                ForEach(laidOut, id: \.0.id) { tile, frame in
                    let inset = frame.insetBy(dx: 1, dy: 1)
                    tileView(tile, size: inset.size)
                        .frame(width: inset.width, height: inset.height)
                        .position(x: inset.midX, y: inset.midY)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // Re-layout animates when sizes arrive, but not while the window is being resized.
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: content.tiles)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
                handleKey(press.key, content: content, frames: frames)
            }
        }
        .padding(margin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap")
    }

    private func tileView(_ tile: TreemapTile, size: CGSize) -> some View {
        TreemapTileView(
            tile: tile,
            size: size,
            isSelected: tile.contains(selection),
            isHovered: hovered == tile.id
        )
        .animation(.easeOut(duration: 0.12), value: hovered == tile.id)
        .onHover { inside in
            if inside {
                hovered = tile.id
            } else if hovered == tile.id {
                hovered = nil
            }
        }
        .help(tile.tooltip)
        // Single click selects right away; the second click of a double click also opens.
        .gesture(TapGesture(count: 2).onEnded { open(tile) })
        .simultaneousGesture(TapGesture().onEnded { select(tile) })
        .contextMenu {
            if let entry = tile.entry {
                if entry.isFolder {
                    Button("Open") { onOpen(entry) }
                }
                Button("Reveal in Finder") { AppModel.revealInFinder(entry.url) }
                if let onTrash {
                    Divider()
                    Button("Move to Trash…") { onTrash(entry) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityAddTraits(tile.contains(selection) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(tile) }
        .accessibilityAction(named: tile.entry?.isFolder == true ? "Open" : "Reveal in Finder") { open(tile) }
    }

    private func select(_ tile: TreemapTile) {
        isFocused = true
        // "Other" stands for many items, and the selection can only hold one.
        selection = tile.entry?.id
    }

    private func open(_ tile: TreemapTile) {
        guard let entry = tile.entry else { return }
        selection = entry.id
        onOpen(entry)
    }

    private func handleKey(_ key: KeyEquivalent, content: TreemapContent, frames: [CGRect]) -> KeyPress.Result {
        let current = content.tiles.firstIndex { $0.entry != nil && $0.contains(selection) }

        if key == .return {
            guard let current, let entry = content.tiles[current].entry else { return .ignored }
            onOpen(entry)
            return .handled
        }

        let direction: Treemap.Direction
        switch key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }

        guard let current else {
            selection = content.tiles.first?.entry?.id
            return .handled
        }
        // Only real entries can be selected, so hide "Other" (and slivers too small to see) from navigation.
        let navigable = zip(content.tiles, frames).map { tile, frame in
            tile.entry != nil && frame.width >= 2 && frame.height >= 2 ? frame : .zero
        }
        if let next = Treemap.neighbor(of: current, toward: direction, in: navigable), let entry = content.tiles[next].entry {
            selection = entry.id
        }
        return .handled
    }
}

/// A small, opaque badge shown while some items are still being measured.
private struct MeasuringBadge: View {
    let remaining: Int

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Measuring \(remaining) more…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
