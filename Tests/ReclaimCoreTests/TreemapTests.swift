import CoreGraphics
import Foundation
import Testing
@testable import ReclaimCore

@Suite struct TreemapTests {
    private let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)

    private func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

    private func aspectRatio(_ rect: CGRect) -> Double {
        Double(max(rect.width, rect.height) / min(rect.width, rect.height))
    }

    private func expectValidLayout(_ sizes: [Double], in bounds: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        let rects = Treemap.layout(sizes, in: bounds)
        #expect(rects.count == sizes.count, sourceLocation: sourceLocation)
        let total = sizes.filter { $0 > 0 }.reduce(0, +)
        let boundsArea = area(bounds)
        let tolerance = 1e-6 * boundsArea

        for (size, rect) in zip(sizes, rects) {
            if size > 0 {
                #expect(abs(area(rect) - size / total * boundsArea) < tolerance, sourceLocation: sourceLocation)
                #expect(rect.minX >= bounds.minX - 1e-6 && rect.maxX <= bounds.maxX + 1e-6, sourceLocation: sourceLocation)
                #expect(rect.minY >= bounds.minY - 1e-6 && rect.maxY <= bounds.maxY + 1e-6, sourceLocation: sourceLocation)
            } else {
                #expect(rect == .zero, sourceLocation: sourceLocation)
            }
        }
        #expect(abs(rects.map(area).reduce(0, +) - (total > 0 ? boundsArea : 0)) < tolerance, sourceLocation: sourceLocation)

        // No two rectangles overlap (beyond floating-point noise).
        let placed = rects.filter { !$0.isEmpty }
        for i in placed.indices {
            for j in placed.indices where j > i {
                let overlap = placed[i].intersection(placed[j])
                #expect(overlap.isNull || area(overlap) < 1e-6, sourceLocation: sourceLocation)
            }
        }
    }

    @Test func classicExampleFromThePaper() {
        // The worked example from Bruls et al.: 6×4 rectangle, areas 6, 6, 4, 3, 2, 2, 1.
        let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Treemap.layout(sizes, in: CGRect(x: 0, y: 0, width: 6, height: 4))
        expectValidLayout(sizes, in: CGRect(x: 0, y: 0, width: 6, height: 4))
        // The first row is the two 6s stacked in a 3-wide column on the left.
        #expect(abs(rects[0].width - 3) < 1e-9 && abs(rects[0].height - 2) < 1e-9)
        #expect(abs(rects[1].minY - 2) < 1e-9)
        #expect(rects.map(aspectRatio).max().map { $0 < 3 } == true)
    }

    @Test func areasAreProportionalAndInsideBounds() {
        expectValidLayout([500, 300, 120, 80, 40, 30, 20, 7, 3], in: bounds)
        expectValidLayout([1, 1, 1, 1], in: bounds)
        expectValidLayout([3, 1_000_000, 42, 9_000], in: bounds)
    }

    @Test func singleItemFillsTheRect() {
        let rects = Treemap.layout([42], in: bounds)
        #expect(rects == [bounds])
    }

    @Test func zeroNegativeAndNonFiniteSizesGetZeroRects() {
        let sizes: [Double] = [0, 10, -5, 20, .nan, .infinity, 0]
        let rects = Treemap.layout(sizes, in: bounds)
        #expect(rects[0] == .zero && rects[2] == .zero && rects[4] == .zero && rects[5] == .zero && rects[6] == .zero)
        #expect(abs(area(rects[1]) + area(rects[3]) - area(bounds)) < 1e-6)
        #expect(abs(area(rects[3]) - 2 * area(rects[1])) < 1e-6)
        #expect(Treemap.layout([0, 0], in: bounds) == [.zero, .zero])
        #expect(Treemap.layout([], in: bounds).isEmpty)
        #expect(Treemap.layout([1, 2], in: .zero) == [.zero, .zero])
    }

    @Test func manyTinyItems() {
        var sizes = [Double](repeating: 1, count: 2_000)
        sizes[0] = 50_000
        expectValidLayout(sizes, in: bounds)
        expectValidLayout((1...300).map { 1 / Double($0) }, in: bounds)
    }

    @Test func aspectRatiosStayReasonable() {
        let sizes = (1...40).map { Double(41 - $0) * 10 }
        let rects = Treemap.layout(sizes, in: bounds)
        let ratios = rects.map(aspectRatio)
        // Squarified layouts keep most tiles near-square; a slice-and-dice layout would give ratios in the hundreds.
        #expect(ratios.max().map { $0 < 6 } == true)
        #expect(ratios.reduce(0, +) / Double(ratios.count) < 2.5)
    }

    @Test func layoutIsDeterministicAndOrderIndependent() {
        let sizes: [Double] = [5, 9, 1, 9, 3, 7]
        let first = Treemap.layout(sizes, in: bounds)
        #expect(Treemap.layout(sizes, in: bounds) == first)

        let reversed = Treemap.layout(sizes.reversed(), in: bounds)
        // Same sizes give the same rectangles regardless of order (only equal sizes may swap places).
        #expect(Set(reversed.map(area).map { Int($0.rounded()) }) == Set(first.map(area).map { Int($0.rounded()) }))
        #expect(reversed[0] == first[5])
        #expect(reversed[5] == first[0])
    }

    @Test func groupsSmallItems() {
        let sizes: [Double] = [1_000, 2, 500, 1, 0, 300]
        let (kept, grouped) = Treemap.groupSmallItems(sizes, minimumFraction: 0.005)
        #expect(kept == [0, 2, 5])
        #expect(grouped == [1, 3, 4])

        // A single small item keeps its own tile.
        let single = Treemap.groupSmallItems([1_000, 1, 400])
        #expect(single.kept == [0, 1, 2])
        #expect(single.grouped.isEmpty)

        #expect(Treemap.groupSmallItems([]).kept.isEmpty)
    }

    @Test func stableIndexIsDeterministic() {
        #expect(Treemap.stableIndex(for: "Documents", count: 12) == Treemap.stableIndex(for: "documents", count: 12))
        #expect((0..<12).contains(Treemap.stableIndex(for: "Library", count: 12)))
        #expect(Treemap.stableIndex(for: "anything", count: 0) == 0)
        let indices = Set(["mp4", "mov", "zip", "dmg", "pdf", "png", "app", "swift", "json", "txt"].map {
            Treemap.stableIndex(for: $0, count: 12)
        })
        #expect(indices.count > 4)

        // Similar names spread evenly over a small palette.
        var buckets = [Int](repeating: 0, count: 12)
        for number in 0..<1_200 { buckets[Treemap.stableIndex(for: "Folder \(number)", count: 12)] += 1 }
        #expect(buckets.allSatisfy { (60...140).contains($0) })
    }

    @Test func navigatesToNeighbors() {
        // ┌───┬───┐
        // │ 0 │ 1 │
        // ├───┼───┤
        // │ 2 │ 3 │
        // └───┴───┘
        let rects = [
            CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 10, width: 10, height: 10), CGRect(x: 10, y: 10, width: 10, height: 10),
        ]
        #expect(Treemap.neighbor(of: 0, toward: .right, in: rects) == 1)
        #expect(Treemap.neighbor(of: 0, toward: .down, in: rects) == 2)
        #expect(Treemap.neighbor(of: 3, toward: .left, in: rects) == 2)
        #expect(Treemap.neighbor(of: 3, toward: .up, in: rects) == 1)
        #expect(Treemap.neighbor(of: 0, toward: .left, in: rects) == nil)
        #expect(Treemap.neighbor(of: 0, toward: .up, in: rects) == nil)
        #expect(Treemap.neighbor(of: 9, toward: .up, in: rects) == nil)

        // Works on real layouts: every tile can reach some other tile.
        let layout = Treemap.layout([50, 30, 20, 10, 5, 5], in: bounds)
        for index in layout.indices {
            #expect(Treemap.Direction.allCases.contains { Treemap.neighbor(of: index, toward: $0, in: layout) != nil })
        }
    }
}
