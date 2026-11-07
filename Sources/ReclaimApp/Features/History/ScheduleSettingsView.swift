import ReclaimCore
import SwiftUI

/// The "Schedule" tab in Settings.
struct ScheduleSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var history = model.history
        let isOff = history.frequency == .off

        Form {
            Section {
                Picker("Clean up automatically", selection: $history.frequency) {
                    Text("Never").tag(ScheduleFrequency.off)
                    Text("Every day").tag(ScheduleFrequency.daily)
                    Text("Every week").tag(ScheduleFrequency.weekly)
                    Text("Every month").tag(ScheduleFrequency.monthly)
                }
                if history.frequency == .weekly {
                    Picker("On", selection: $history.weekday) {
                        ForEach(Self.weekdays, id: \.number) { day in
                            Text(day.name).tag(day.number)
                        }
                    }
                } else {
                    LabeledContent("On") {
                        Text(history.frequency == .monthly ? "The 1st of each month" : history.frequency == .daily ? "Every day" : "—")
                    }
                    .foregroundStyle(isOff ? .secondary : .primary)
                }
                Picker("Only when", selection: $history.minimumFreeGB) {
                    Text("Always").tag(0)
                    ForEach([10, 20, 50, 100], id: \.self) { gb in
                        Text("Less than \(gb) GB is free").tag(gb)
                    }
                }
                .disabled(isOff)
                LabeledContent("Last run", value: lastRunText)
                LabeledContent("Next run", value: nextRunText)
            } header: {
                Text("Scheduled Cleanup")
            } footer: {
                Text("Cleans everything marked Safe, like “Clean Safe Items” in the menu bar: app caches, logs and the Trash. Runs around \(Self.slotTime), or as soon as possible after that if your Mac was asleep. Reclaim needs to be open, in the menu bar is enough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Send a weekly summary", isOn: $history.weeklySummaryEnabled)
                    .disabled(!Notifier.isSupported)
            } header: {
                Text("Weekly Summary")
            } footer: {
                Text(Notifier.isSupported
                    ? "Every Monday morning: how much space is free, how that changed during the week, and how much can be cleaned up safely."
                    : "Notifications need the bundled app (scripts/build-app.sh).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lastRunText: String {
        let history = model.history
        guard let lastRun = history.lastRun else { return "Never" }
        let date = lastRun.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return history.lastResult.map { "\(date) · \($0)" } ?? date
    }

    private var nextRunText: String {
        let history = model.history
        if history.isRunningSchedule { return "Running now…" }
        guard let next = history.nextRun else { return "—" }
        if next <= Date() { return "In a few minutes" }
        return next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    private static var slotTime: String {
        let date = Calendar.current.date(bySettingHour: HistoryModel.slotHour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Weekday names in the user's order (e.g. starting on Monday), numbered like `Calendar` (1 = Sunday).
    private static var weekdays: [(number: Int, name: String)] {
        let calendar = Calendar.current
        let symbols = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let number = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (number, symbols[number - 1])
        }
    }
}
