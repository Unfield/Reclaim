import Observation
import ReclaimCore
import SwiftUI

/// State for the Disk History screen, scheduled cleanup and the weekly summary, owned by `AppModel`.
/// (Placeholder: replace with the real implementation.)
@MainActor
@Observable
final class HistoryModel {
    init() {}

    /// Called whenever disk usage is refreshed (at launch, every 5 minutes, after cleanups). Should be cheap
    /// and throttle its own writes.
    func record(_ volumes: [VolumeInfo]) {}

    /// Called every 5 minutes by `AppModel`'s monitor loop. Runs scheduled cleanups and posts the weekly summary when due.
    func tick(appModel: AppModel) async {}
}

/// A short forecast shown under a disk's usage bar on the Overview (e.g. "Full in about 6 weeks"). Empty if unknown.
struct DiskForecastLabel: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo

    var body: some View {
        EmptyView()
    }
}

/// The "Schedule" tab in Settings.
struct ScheduleSettingsView: View {
    var body: some View {
        Form {
            Text("Coming soon.").foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
