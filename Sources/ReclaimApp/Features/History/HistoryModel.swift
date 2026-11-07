import Observation
import ReclaimCore
import SwiftUI

/// UserDefaults keys for scheduled cleanup and the weekly summary.
enum SchedulePrefs {
    static let frequency = "scheduleFrequency"
    static let weekday = "scheduleWeekday"
    static let minFreeGB = "scheduleMinFreeGB"
    /// When the schedule last fired (whether it cleaned or skipped).
    static let lastRun = "scheduleLastRun"
    static let lastResult = "scheduleLastResult"
    /// When the schedule was last changed. Slots before this don't count, so turning it on doesn't run it at once.
    static let anchor = "scheduleAnchor"
    static let weeklySummary = "weeklySummaryEnabled"
    static let weeklySummaryLastSent = "weeklySummaryLastSent"
    static let weeklySummaryAnchor = "weeklySummaryAnchor"
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case year = 365

    var id: Int { rawValue }
    var days: Int { rawValue }

    var title: String {
        switch self {
        case .week: String(localized: "7 Days")
        case .month: String(localized: "30 Days")
        case .year: String(localized: "1 Year")
        }
    }
}

/// State for the Disk History screen, scheduled cleanup and the weekly summary, owned by `AppModel`.
@MainActor
@Observable
final class HistoryModel {
    /// Scheduled runs and the weekly summary happen at this local hour (or later, if the Mac is asleep).
    static let slotHour = 9

    private(set) var history = DiskHistory()
    private(set) var isLoaded = false
    /// Keyed by `VolumeHistory.id`.
    private(set) var forecasts: [String: DiskForecast] = [:]
    /// History keys of the disks that are mounted right now.
    private(set) var keysByURL: [URL: String] = [:]

    // Screen state, kept here so it survives navigating away.
    var selectedVolumeKey: String?
    var range: HistoryRange = .month

    // MARK: Schedule settings

    var frequency: ScheduleFrequency {
        didSet {
            guard frequency != oldValue else { return }
            defaults.set(frequency.rawValue, forKey: SchedulePrefs.frequency)
            scheduleChanged()
        }
    }

    /// 1 = Sunday … 7 = Saturday.
    var weekday: Int {
        didSet {
            guard weekday != oldValue else { return }
            defaults.set(weekday, forKey: SchedulePrefs.weekday)
            scheduleChanged()
        }
    }

    /// Only clean when the startup disk has less than this many GB free; 0 means always.
    var minimumFreeGB: Int {
        didSet { defaults.set(minimumFreeGB, forKey: SchedulePrefs.minFreeGB) }
    }

    var weeklySummaryEnabled: Bool {
        didSet {
            guard weeklySummaryEnabled != oldValue else { return }
            defaults.set(weeklySummaryEnabled, forKey: SchedulePrefs.weeklySummary)
            if weeklySummaryEnabled {
                weeklySummaryAnchor = Date()
                defaults.set(weeklySummaryAnchor.timeIntervalSince1970, forKey: SchedulePrefs.weeklySummaryAnchor)
                Task { await Notifier.requestAuthorization() }
            }
        }
    }

    private(set) var lastRun: Date?
    private(set) var lastResult: String?
    private(set) var isRunningSchedule = false

    @ObservationIgnored private var scheduleAnchor: Date
    @ObservationIgnored private var weeklySummaryAnchor: Date
    @ObservationIgnored private var weeklySummaryLastSent: Date?

    @ObservationIgnored private let store = DiskHistoryStore()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var recordTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let now = Date()
        func date(_ key: String) -> Date? {
            defaults.object(forKey: key) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: key))
        }

        frequency = ScheduleFrequency(rawValue: defaults.string(forKey: SchedulePrefs.frequency) ?? "") ?? .off
        let storedWeekday = defaults.integer(forKey: SchedulePrefs.weekday)
        weekday = (1...7).contains(storedWeekday) ? storedWeekday : 2
        minimumFreeGB = max(0, defaults.integer(forKey: SchedulePrefs.minFreeGB))
        weeklySummaryEnabled = defaults.bool(forKey: SchedulePrefs.weeklySummary)
        lastRun = date(SchedulePrefs.lastRun)
        lastResult = defaults.string(forKey: SchedulePrefs.lastResult)
        scheduleAnchor = date(SchedulePrefs.anchor) ?? now
        weeklySummaryAnchor = date(SchedulePrefs.weeklySummaryAnchor) ?? now
        weeklySummaryLastSent = date(SchedulePrefs.weeklySummaryLastSent)

        loadTask = Task { [store] in
            let loaded = await store.history()
            apply(loaded)
            isLoaded = true
        }
    }

    // MARK: - Recording

    /// Called whenever disk usage is refreshed (at launch, every 5 minutes, after cleanups). Cheap: the store
    /// writes at most one sample per disk per hour, and the disk lookups and file I/O happen off the main actor.
    func record(_ volumes: [VolumeInfo]) {
        let candidates = volumes.filter(DiskHistory.shouldRecord)
        let previous = recordTask
        recordTask = Task { [store, loadTask] in
            // One at a time, so results are applied in order.
            await previous?.value
            await loadTask?.value
            let readings = await Self.readings(for: candidates)
            var keys = [URL: String]()
            for reading in readings {
                if let url = reading.url { keys[url] = reading.key }
            }
            if keys != keysByURL { keysByURL = keys }
            if let updated = await store.record(readings) { apply(updated) }
        }
    }

    /// `nonisolated async` so the volume UUID lookups run off the main actor.
    nonisolated private static func readings(for volumes: [VolumeInfo]) async -> [DiskReading] {
        volumes.map(DiskReading.init(volume:))
    }

    private func apply(_ updated: DiskHistory) {
        let now = Date()
        history = updated
        var forecasts = [String: DiskForecast]()
        for volume in updated.volumes {
            forecasts[volume.id] = DiskForecaster.forecast(for: volume, now: now)
        }
        self.forecasts = forecasts
        if selectedVolumeKey.map({ key in !chartableVolumes.contains { $0.id == key } }) ?? true {
            selectedVolumeKey = chartableVolumes.first?.id
        }
    }

    // MARK: - Queries

    func key(for volume: VolumeInfo) -> String? {
        volume.isStartup ? DiskHistory.startupKey : keysByURL[volume.url]
    }

    func forecast(for volume: VolumeInfo) -> DiskForecast? {
        key(for: volume).flatMap { forecasts[$0] }
    }

    func isMounted(_ key: String) -> Bool {
        key == DiskHistory.startupKey || keysByURL.values.contains(key)
    }

    /// Disks with enough data to draw: the startup disk first, then connected disks, then by name.
    var chartableVolumes: [VolumeHistory] {
        history.volumes
            .filter { $0.sampleCount >= 2 }
            .sorted { lhs, rhs in
                if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
                let lhsMounted = isMounted(lhs.id), rhsMounted = isMounted(rhs.id)
                if lhsMounted != rhsMounted { return lhsMounted }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Schedule

    var schedule: CleanupSchedule {
        CleanupSchedule(
            frequency: frequency, weekday: weekday, hour: Self.slotHour,
            minimumFree: minimumFreeGB > 0 ? Int64(minimumFreeGB) * 1_000_000_000 : nil
        )
    }

    /// May be in the past while a run is overdue (it then runs within a few minutes).
    var nextRun: Date? {
        schedule.nextRun(lastRun: lastRun, anchor: scheduleAnchor)
    }

    private func scheduleChanged() {
        scheduleAnchor = Date()
        defaults.set(scheduleAnchor.timeIntervalSince1970, forKey: SchedulePrefs.anchor)
        if frequency != .off { Task { await Notifier.requestAuthorization() } }
    }

    /// Called every 5 minutes by `AppModel`'s monitor loop. Runs scheduled cleanups and posts the weekly summary when due.
    func tick(appModel: AppModel) async {
        await loadTask?.value
        await runScheduledCleanupIfDue(appModel)
        await postWeeklySummaryIfDue(appModel)
    }

    private func runScheduledCleanupIfDue(_ appModel: AppModel) async {
        let now = Date()
        let schedule = schedule
        guard !isRunningSchedule, !appModel.isScanning, !appModel.isCleaning,
              schedule.isDue(lastRun: lastRun, anchor: scheduleAnchor, now: now) else { return }

        // Recorded up front so a failure or crash can't make it run over and over.
        setLastRun(now)
        let free = appModel.volume?.availableForImportantUsage
        guard schedule.allowsCleanup(free: free) else {
            setLastResult(String(localized: "Skipped, \(ByteSize.format(free ?? 0)) was free"))
            return
        }

        isRunningSchedule = true
        defer { isRunningSchedule = false }
        await appModel.refresh()
        // `refresh()` returns early if another scan (e.g. the one at launch) is already running; wait for it so
        // the cleanup works from complete results.
        let deadline = Date().addingTimeInterval(600)
        while appModel.isScanning, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        guard !appModel.isCleaning, !appModel.isScanning, appModel.lastScanDate != nil else {
            setLastResult(String(localized: "Skipped, Reclaim was busy"))
            return
        }
        // Unattended runs never empty the Trash (that's permanent) and don't pop up the result alert.
        let report = await appModel.cleanAllSafe(includingTrash: false, showReport: false)

        guard let report, report.total > 0 || !report.failures.isEmpty else {
            setLastResult(String(localized: "Nothing needed cleaning"))
            return
        }
        setLastResult(report.total > 0 ? String(localized: "Cleaned up \(ByteSize.format(report.total))") : String(localized: "Nothing could be removed"))

        var body = report.total > 0
            ? String(localized: "Reclaim cleaned up \(ByteSize.format(report.total)).")
            : String(localized: "Reclaim couldn't remove anything.")
        if report.trashed > 0 {
            body += " " + String(localized: "\(ByteSize.format(report.trashed)) of it is in the Trash.")
        }
        if !report.failures.isEmpty {
            body += " " + (report.failures.count == 1
                ? String(localized: "1 item couldn't be removed.")
                : String(localized: "\(report.failures.count) items couldn't be removed."))
        }
        await Notifier.post(title: String(localized: "Scheduled cleanup"), body: body, identifier: "scheduled-cleanup")
    }

    private func postWeeklySummaryIfDue(_ appModel: AppModel) async {
        let now = Date()
        let summarySchedule = CleanupSchedule(frequency: .weekly, weekday: 2, hour: Self.slotHour)
        guard weeklySummaryEnabled, Notifier.isSupported, !isRunningSchedule, !appModel.isScanning, !appModel.isCleaning,
              summarySchedule.isDue(lastRun: weeklySummaryLastSent, anchor: weeklySummaryAnchor, now: now) else { return }

        weeklySummaryLastSent = now
        defaults.set(now.timeIntervalSince1970, forKey: SchedulePrefs.weeklySummaryLastSent)

        // The safe total needs a reasonably fresh scan.
        if appModel.lastScanDate.map({ now.timeIntervalSince($0) > 6 * 3_600 }) ?? true {
            await appModel.refresh()
        }
        guard let volume = appModel.volume else { return }

        var body = String(localized: "\(ByteSize.format(volume.availableForImportantUsage)) free")
        let weekAgo = now.addingTimeInterval(-7 * 86_400)

        if let first = history.volume(DiskHistory.startupKey)?.samples(since: weekAgo).first,
           now.timeIntervalSince(first.date) >= 3 * 86_400 {
            let delta = volume.availableForImportantUsage - first.free
            if abs(delta) >= 1_000_000 { body += " (\(DiskHistoryFormat.signedSize(delta)))" }
        }
        body += "."
        let safe = appModel.safeReclaimable
        body += " " + (safe > 0
            ? String(localized: "\(ByteSize.format(safe)) can be cleaned safely.")
            : String(localized: "Nothing needs cleaning right now."))
        await Notifier.post(title: String(localized: "Your Mac this week"), body: body, identifier: "weekly-summary")
    }

    private func setLastRun(_ date: Date) {
        lastRun = date
        defaults.set(date.timeIntervalSince1970, forKey: SchedulePrefs.lastRun)
    }

    private func setLastResult(_ text: String) {
        lastResult = text
        defaults.set(text, forKey: SchedulePrefs.lastResult)
    }
}

/// A short forecast shown under a disk's usage bar on the Overview (e.g. "Full in ~6 weeks"). Empty if unknown.
struct DiskForecastLabel: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo

    /// Further out than this isn't worth a line on the Overview.
    private static let maximumDays: Double = 365

    var body: some View {
        if let forecast = model.history.forecast(for: volume), let days = forecast.daysUntilFull, days <= Self.maximumDays {
            Text(days < 1 ? "Full within a day" : "Full in \(DiskHistoryFormat.approximateDuration(days: days))")
                .foregroundStyle(days < 7 ? AnyShapeStyle(.red) : days < 30 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .help("At the rate free space has been shrinking over the last \(DiskForecaster.windowDays) days. See Disk History for details.")
        }
    }
}
