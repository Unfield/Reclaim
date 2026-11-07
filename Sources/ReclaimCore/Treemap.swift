import CoreGraphics
import Foundation

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000), plus small helpers for presenting one.
///
/// Everything here is pure and deterministic, so the same sizes always produce the same picture.
public enum Treemap {
    /// Lays out `sizes` as rectangles filling `rect`, with areas proportional to the sizes.
    ///
    /// - Returns: One rectangle per input size, in input order. Zero, negative and non-finite sizes get `.zero`.
    ///   The result doesn't depend on input order: items are placed largest first (ties keep input order).
    public static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: sizes.count)
        let bounds = rect.standardized
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return result }

        let items = sizes.enumerated()
            .filter { $0.element > 0 && $0.element.isFinite }
            .sorted { $0.element != $1.element ? $0.element > $1.element : $0.offset < $1.offset }
        let total = items.reduce(0.0) { $0 + $1.element }
        guard total > 0, total.isFinite else { return result }

        let scale = Double(bounds.width * bounds.height) / total
        let areas = items.map { (index: $0.offset, area: $0.element * scale) }

        var remaining = bounds
        var rowStart = 0
        var rowSum = 0.0
        var position = 0
        while position < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = areas[position].area
            // Items are sorted descending, so a row's largest area is its first and its smallest the newest.
            let largest = areas[rowStart].area
            if position == rowStart
                || worstAspectRatio(sum: rowSum + candidate, largest: largest, smallest: candidate, side: side)
                <= worstAspectRatio(sum: rowSum, largest: largest, smallest: areas[position - 1].area, side: side) {
                rowSum += candidate
                position += 1
            } else {
                remaining = place(areas[rowStart..<position], sum: rowSum, in: remaining, isLast: false, into: &result)
                rowStart = position
                rowSum = 0
            }
        }
        if rowStart < areas.count {
            _ = place(areas[rowStart...], sum: rowSum, in: remaining, isLast: true, into: &result)
        }
        return result
    }

    /// The worst (largest) aspect ratio in a row of areas laid along a side of length `side`.
    static func worstAspectRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    /// Places a row along the shorter side of `rect` and returns the space left over.
    private static func place(
        _ row: ArraySlice<(index: Int, area: Double)>,
        sum: Double,
        in rect: CGRect,
        isLast: Bool,
        into result: inout [CGRect]
    ) -> CGRect {
        guard !row.isEmpty else { return rect }
        let vertical = rect.width >= rect.height // the row becomes a column on the left
        let side = vertical ? rect.height : rect.width
        let length = vertical ? rect.width : rect.height
        // The last row takes all remaining space, so rounding never leaves a sliver uncovered.
        let thickness = isLast ? length : min(length, CGFloat(sum / Double(side)))

        var offset: CGFloat = 0
        for (number, item) in row.enumerated() {
            let fraction = sum > 0 ? item.area / sum : 1 / Double(row.count)
            let extent = number == row.count - 1 ? side - offset : side * CGFloat(fraction)
            result[item.index] = vertical
                ? CGRect(x: rect.minX, y: rect.minY + offset, width: thickness, height: extent)
                : CGRect(x: rect.minX + offset, y: rect.minY, width: extent, height: thickness)
            offset += extent
        }

        return vertical
            ? CGRect(x: rect.minX + thickness, y: rect.minY, width: rect.width - thickness, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY + thickness, width: rect.width, height: rect.height - thickness)
    }

    // MARK: Grouping

    /// Splits items into those big enough for their own tile and those that should share one "Other" tile.
    ///
    /// Items below `minimumFraction` of the total (including empty ones) are grouped, but only if at least two
    /// qualify: an "Other (1 item)" tile would just hide a name for no gain.
    /// - Returns: Indices into `sizes`, each list in input order.
    public static func groupSmallItems(_ sizes: [Double], minimumFraction: Double = 0.005) -> (kept: [Int], grouped: [Int]) {
        let total = sizes.reduce(0.0) { $0 + max(0, $1.isFinite ? $1 : 0) }
        let threshold = total * minimumFraction
        var kept = [Int]()
        var grouped = [Int]()
        for (index, size) in sizes.enumerated() {
            if size.isFinite && size > 0 && size >= threshold {
                kept.append(index)
            } else {
                grouped.append(index)
            }
        }
        if grouped.count < 2 {
            return (Array(sizes.indices), [])
        }
        return (kept, grouped)
    }

    // MARK: Colors

    /// A stable index in `0..<count` for a key such as a name or file extension.
    ///
    /// Uses FNV-1a rather than `hashValue`, which is randomly seeded per launch, so colors never change between runs.
    public static func stableIndex(for key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // FNV's low bits only depend on the inputs' low bits, so mix (MurmurHash3's finalizer) before the modulo.
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return Int(hash % UInt64(count))
    }

    // MARK: Keyboard navigation

    public enum Direction: Sendable, CaseIterable {
        case left, right, up, down
    }

    /// The nearest rectangle in `direction` from `rects[index]`, for moving a selection with the arrow keys.
    /// Empty rectangles are skipped. Returns nil at the edge.
    public static func neighbor(of index: Int, toward direction: Direction, in rects: [CGRect]) -> Int? {
        guard rects.indices.contains(index) else { return nil }
        let source = rects[index]
        let tolerance: CGFloat = 0.5
        var best: (index: Int, score: CGFloat)?

        for (candidateIndex, candidate) in rects.enumerated() where candidateIndex != index && !candidate.isEmpty {
            let gap: CGFloat // distance along the direction of travel
            let offAxis: CGFloat // how far the candidate is beside the source's span
            let centerOffset: CGFloat
            switch direction {
            case .right, .left:
                gap = direction == .right ? candidate.minX - source.maxX : source.minX - candidate.maxX
                offAxis = max(0, max(candidate.minY, source.minY) - min(candidate.maxY, source.maxY))
                centerOffset = abs(candidate.midY - source.midY)
            case .down, .up:
                gap = direction == .down ? candidate.minY - source.maxY : source.minY - candidate.maxY
                offAxis = max(0, max(candidate.minX, source.minX) - min(candidate.maxX, source.maxX))
                centerOffset = abs(candidate.midX - source.midX)
            }
            guard gap >= -tolerance else { continue }
            // Strongly prefer tiles that line up with the source, then the closest, then the most centered.
            let score = max(0, gap) + offAxis * 4 + centerOffset * 0.01
            if best.map({ score < $0.score }) ?? true {
                best = (candidateIndex, score)
            }
        }
        return best?.index
    }
}
