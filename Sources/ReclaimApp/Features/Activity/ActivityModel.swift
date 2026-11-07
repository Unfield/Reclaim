import Observation
import ReclaimCore
import SwiftUI

/// State for the CPU & Energy screen, owned by `AppModel`.
@MainActor
@Observable
final class ActivityModel {
    /// Samples kept per app for the sparklines (about a minute at the refresh rate below).
    static let historyLength = 30
    static let refreshInterval: Duration = .seconds(2)

    var load: CPULoad?
    /// All groups in a stable display order (see `CPUMonitor.merge`).
    var groups: [CPUProcessGroup] = []
    var hasEnergyData = false
    var thermal: ThermalLevel = CPUMonitor.thermalLevel
    var isLowPowerMode = CPUMonitor.isLowPowerModeEnabled
    let info = CPUMonitor.info()
    /// Recent CPU % per group ID, oldest first.
    private(set) var history: [String: [Double]] = [:]

    @ObservationIgnored private var lastSnapshot: CPUSnapshot?
    @ObservationIgnored private var lastSnapshotTime: ContinuousClock.Instant?

    init() {}

    /// Measures CPU use since the previous refresh. The first call (or one after a long pause) takes a fresh
    /// one-second sample, so numbers always describe the last few seconds rather than minutes ago.
    func refresh() async {
        let isFresh = lastSnapshotTime.map { ContinuousClock.now - $0 < .seconds(10) } ?? false
        let previous = isFresh ? lastSnapshot : nil
        if previous == nil { history = [:] }

        let (snapshot, report) = await Task.detached(priority: .utility) {
            let baseline: CPUSnapshot
            if let previous {
                baseline = previous
            } else {
                baseline = CPUMonitor.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
            let current = CPUMonitor.snapshot(reusing: baseline)
            return (current, CPUMonitor.report(from: baseline, to: current))
        }.value

        lastSnapshot = snapshot
        lastSnapshotTime = .now
        load = report.load
        hasEnergyData = report.hasEnergyData
        thermal = CPUMonitor.thermalLevel
        isLowPowerMode = CPUMonitor.isLowPowerModeEnabled
        groups = CPUMonitor.merge(report.groups, keepingOrderOf: groups)
        recordHistory(report.groups)
    }

    private func recordHistory(_ fresh: [CPUProcessGroup]) {
        var updated: [String: [Double]] = [:]
        for group in fresh {
            updated[group.id] = Array((history[group.id, default: []] + [group.cpu]).suffix(Self.historyLength))
        }
        history = updated
    }
}
