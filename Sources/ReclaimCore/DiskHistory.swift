import Foundation

// MARK: - Samples

/// One measurement of a disk's free space. In daily aggregates, `free` is the day's lowest free space
/// and `date` is the start of that day.
public struct DiskSample: Sendable, Hashable {
    public let date: Date
    public let free: Int64
    public let capacity: Int64

    public init(date: Date, free: Int64, capacity: Int64) {
        self.date = date
        self.free = free
        self.capacity = capacity
    }
}

extension DiskSample: Codable {
    // Stored as a compact `[seconds, free, capacity]` array: thousands of these end up in the file.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let seconds = try container.decode(Int64.self)
        date = Date(timeIntervalSince1970: TimeInterval(seconds))
        free = try container.decode(Int64.self)
        capacity = try container.decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(Int64(date.timeIntervalSince1970.rounded()))
        try container.encode(free)
        try container.encode(capacity)
    }
}

/// A disk's free space right now, ready to be recorded.
public struct DiskReading: Sendable, Hashable {
    /// Stable identity of the disk (see `DiskHistory.key(for:)`).
    public let key: String
    public let name: String
    public let isStartup: Bool
    public let free: Int64
    public let capacity: Int64
    /// Where the disk is mounted. Not stored; lets the app map mounted disks to their history.
    public let url: URL?

    public init(key: String, name: String, isStartup: Bool, free: Int64, capacity: Int64, url: URL? = nil) {
        self.key = key
        self.name = name
        self.isStartup = isStartup
        self.free = free
        self.capacity = capacity
        self.url = url
    }

    /// Reads the disk's identity from the file system, so call it off the main thread.
    public init(volume: VolumeInfo) {
        self.init(
            key: DiskHistory.key(for: volume), name: volume.name, isStartup: volume.isStartup,
            free: volume.availableForImportantUsage, capacity: volume.totalCapacity, url: volume.url
        )
    }
}

/// A notable jump in free space, e.g. a cleanup or a big download.
public struct DiskChange: Sendable, Hashable, Identifiable {
    public let start: Date
    public let end: Date
    /// Positive when free space grew.
    public let delta: Int64
    public let freeAfter: Int64

    public var id: Date { end }
    public var isGain: Bool { delta > 0 }

    public init(start: Date, end: Date, delta: Int64, freeAfter: Int64) {
        self.start = start
        self.end = end
        self.delta = delta
        self.freeAfter = freeAfter
    }
}

/// How free space changed between two samples.
public struct FreeSpaceChange: Sendable, Hashable {
    public let delta: Int64
    public let start: Date
    public let end: Date

    public init(delta: Int64, start: Date, end: Date) {
        self.delta = delta
        self.start = start
        self.end = end
    }

    public var days: Double { end.timeIntervalSince(start) / 86_400 }
}

// MARK: - Per-volume history

public struct VolumeHistory: Codable, Sendable, Hashable, Identifiable {
    /// Stable key, see `DiskHistory.key(for:)`.
    public let id: String
    public var name: String
    public var isStartup: Bool
    public var lastSeen: Date
    /// Raw samples (at most one per hour), oldest first, for the last `RetentionPolicy.rawDays`.
    public var hourly: [DiskSample]
    /// Older data, one sample per day holding that day's minimum, oldest first. Always older than `hourly`.
    public var daily: [DiskSample]

    public init(id: String, name: String, isStartup: Bool, lastSeen: Date, hourly: [DiskSample] = [], daily: [DiskSample] = []) {
        self.id = id
        self.name = name
        self.isStartup = isStartup
        self.lastSeen = lastSeen
        self.hourly = hourly
        self.daily = daily
    }

    public var latest: DiskSample? { hourly.last ?? daily.last }
    public var sampleCount: Int { hourly.count + daily.count }

    /// Daily aggregates followed by raw samples, oldest first.
    public var allSamples: [DiskSample] { daily + hourly }

    /// All samples at or after `start`, oldest first.
    public func samples(since start: Date) -> [DiskSample] {
        daily.filter { $0.date >= start } + hourly.filter { $0.date >= start }
    }

    /// One sample per calendar day with that day's lowest free space, oldest first.
    public func dailyMinimums(calendar: Calendar = .current) -> [DiskSample] {
        DiskHistory.dailyMinimums(of: allSamples, calendar: calendar)
    }

    /// Change from the first sample at or after `start` to the latest one.
    public func change(since start: Date) -> FreeSpaceChange? {
        let range = samples(since: start)
        guard let first = range.first, let last = range.last, last.date > first.date else { return nil }
        return FreeSpaceChange(delta: last.free - first.free, start: first.date, end: last.date)
    }
}

// MARK: - Retention

public struct RetentionPolicy: Sendable, Hashable {
    /// At most one sample per volume per interval (aligned to the clock, e.g. once per hour).
    public var sampleInterval: TimeInterval
    /// Raw samples are kept this long, then aggregated into daily minimums.
    public var rawDays: Int
    /// Daily aggregates are kept this long.
    public var dailyDays: Int
    /// Caps the file size if many different disks are connected over time.
    public var maxVolumes: Int

    public init(sampleInterval: TimeInterval = 3_600, rawDays: Int = 30, dailyDays: Int = 730, maxVolumes: Int = 16) {
        self.sampleInterval = sampleInterval
        self.rawDays = rawDays
        self.dailyDays = dailyDays
        self.maxVolumes = maxVolumes
    }

    public static let standard = RetentionPolicy()

    var maxHourlySamples: Int { Int((Double(rawDays + 1) * 86_400 / sampleInterval).rounded(.up)) }
}

// MARK: - History

/// Free space over time for every disk Reclaim has seen. Pure value type; `DiskHistoryStore` persists it.
public struct DiskHistory: Codable, Sendable, Hashable {
    public var version: Int
    public var volumes: [VolumeHistory]

    public init(volumes: [VolumeHistory] = []) {
        version = 1
        self.volumes = volumes
    }

    public func volume(_ key: String) -> VolumeHistory? {
        volumes.first { $0.id == key }
    }

    /// The startup disk always uses the same key: its volume UUID can change when macOS is reinstalled.
    public static let startupKey = "startup"

    /// A stable identity for a disk: its volume UUID, or its name and size if it has none (e.g. network shares).
    /// Reads from the file system.
    public static func key(for volume: VolumeInfo) -> String {
        if volume.isStartup { return startupKey }
        if let uuid = try? volume.url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, !uuid.isEmpty {
            return "uuid:\(uuid)"
        }
        return "name:\(volume.name)|\(volume.totalCapacity / 1_000_000_000)"
    }

    /// Disk images and read-only disks come and go (installers) and their free space never changes.
    public static func shouldRecord(_ volume: VolumeInfo) -> Bool {
        volume.totalCapacity > 0 && !volume.isReadOnly && volume.kind != .diskImage
    }

    /// Adds a sample for each reading unless that disk already has one in the current interval.
    /// Returns whether anything changed (and so needs saving).
    @discardableResult
    public mutating func record(_ readings: [DiskReading], at now: Date, policy: RetentionPolicy = .standard, calendar: Calendar = .current) -> Bool {
        var changed = false
        for reading in readings where reading.capacity > 0 {
            let sample = DiskSample(date: now, free: max(0, reading.free), capacity: reading.capacity)
            if let index = volumes.firstIndex(where: { $0.id == reading.key }) {
                if let last = volumes[index].latest,
                   Self.slot(of: now, interval: policy.sampleInterval) <= Self.slot(of: last.date, interval: policy.sampleInterval) {
                    continue
                }
                volumes[index].hourly.append(sample)
                volumes[index].name = reading.name
                volumes[index].isStartup = reading.isStartup
                volumes[index].lastSeen = now
            } else {
                volumes.append(VolumeHistory(id: reading.key, name: reading.name, isStartup: reading.isStartup, lastSeen: now, hourly: [sample]))
            }
            changed = true
        }
        if changed { compact(now: now, policy: policy, calendar: calendar) }
        return changed
    }

    /// Aggregates old raw samples into daily minimums and drops what's past retention.
    public mutating func compact(now: Date, policy: RetentionPolicy = .standard, calendar: Calendar = .current) {
        let rawCutoff = now.addingTimeInterval(-Double(policy.rawDays) * 86_400)
        let dailyCutoff = now.addingTimeInterval(-Double(policy.dailyDays) * 86_400)

        for index in volumes.indices {
            var volume = volumes[index]
            let oldCount = volume.hourly.prefix { $0.date < rawCutoff }.count
            if oldCount > 0 {
                for day in Self.dailyMinimums(of: Array(volume.hourly.prefix(oldCount)), calendar: calendar) {
                    if let last = volume.daily.last, calendar.isDate(last.date, inSameDayAs: day.date) {
                        volume.daily[volume.daily.count - 1] = last.free <= day.free ? last : day
                    } else {
                        volume.daily.append(day)
                    }
                }
                volume.hourly.removeFirst(oldCount)
            }
            volume.daily.removeAll { $0.date < dailyCutoff }
            if volume.hourly.count > policy.maxHourlySamples {
                volume.hourly.removeFirst(volume.hourly.count - policy.maxHourlySamples)
            }
            if volume.daily.count > policy.dailyDays + 1 {
                volume.daily.removeFirst(volume.daily.count - policy.dailyDays - 1)
            }
            volumes[index] = volume
        }

        volumes.removeAll { $0.sampleCount == 0 || $0.lastSeen < dailyCutoff }
        if volumes.count > policy.maxVolumes {
            // Keep the startup disk and the disks seen most recently.
            let kept = volumes
                .sorted { ($0.isStartup ? 1 : 0, $0.lastSeen) > ($1.isStartup ? 1 : 0, $1.lastSeen) }
                .prefix(policy.maxVolumes)
            let keys = Set(kept.map(\.id))
            volumes.removeAll { !keys.contains($0.id) }
        }
    }

    static func slot(of date: Date, interval: TimeInterval) -> Int64 {
        Int64((date.timeIntervalSince1970 / interval).rounded(.down))
    }

    /// One sample per calendar day (dated at the start of the day) with that day's lowest free space.
    public static func dailyMinimums(of samples: [DiskSample], calendar: Calendar = .current) -> [DiskSample] {
        var result = [DiskSample]()
        for sample in samples {
            let day = calendar.startOfDay(for: sample.date)
            if let last = result.last, last.date == day {
                result[result.count - 1] = DiskSample(date: day, free: min(last.free, sample.free), capacity: sample.capacity)
            } else {
                result.append(DiskSample(date: day, free: sample.free, capacity: sample.capacity))
            }
        }
        return result
    }

    /// Big jumps in free space, newest first. Consecutive steps in the same direction (e.g. a download spread
    /// over two samples) are combined.
    public static func notableChanges(in samples: [DiskSample], threshold: Int64) -> [DiskChange] {
        guard threshold > 0 else { return [] }
        var changes = [DiskChange]()
        var run: (start: Date, end: Date, delta: Int64, freeAfter: Int64)?

        func finish() {
            if let current = run, abs(current.delta) >= threshold {
                changes.append(DiskChange(start: current.start, end: current.end, delta: current.delta, freeAfter: current.freeAfter))
            }
            run = nil
        }

        for (previous, sample) in zip(samples, samples.dropFirst()) {
            let delta = sample.free - previous.free
            guard abs(delta) >= threshold / 2 else {
                finish()
                continue
            }
            if let current = run, (current.delta > 0) == (delta > 0) {
                run = (current.start, sample.date, current.delta + delta, sample.free)
            } else {
                finish()
                run = (previous.date, sample.date, delta, sample.free)
            }
        }
        finish()
        return changes.reversed()
    }

    /// Splits `start...end` into `count` equal buckets holding the lowest free space seen in each (nil if no data).
    public static func buckets(_ samples: [DiskSample], from start: Date, to end: Date, count: Int) -> [Int64?] {
        guard count > 0, end > start else { return [] }
        var result = [Int64?](repeating: nil, count: count)
        let width = end.timeIntervalSince(start) / Double(count)
        for sample in samples where sample.date >= start && sample.date <= end {
            let index = min(count - 1, Int(sample.date.timeIntervalSince(start) / width))
            result[index] = min(result[index] ?? .max, sample.free)
        }
        return result
    }

    /// A text sparkline (▁▂▃▄▅▆▇█); a space where there's no data. `minimumSpan` keeps tiny wiggles from
    /// looking dramatic.
    public static func sparkline(_ values: [Int64?], minimumSpan: Int64 = 0) -> String {
        let bars = Array("▁▂▃▄▅▆▇█")
        let known = values.compactMap { $0 }
        guard let low = known.min(), let high = known.max() else { return String(repeating: " ", count: values.count) }
        var lower = Double(low)
        var span = Double(high - low)
        if span < Double(minimumSpan) {
            lower -= (Double(minimumSpan) - span) / 2
            span = Double(minimumSpan)
        }
        return String(values.map { value -> Character in
            guard let value else { return " " }
            guard span > 0 else { return bars[bars.count / 2 - 1] }
            let level = Int(((Double(value) - lower) / span * Double(bars.count - 1)).rounded())
            return bars[min(bars.count - 1, max(0, level))]
        })
    }
}

// MARK: - Forecast

public struct DiskForecast: Sendable, Hashable {
    /// Trend in free space, in bytes per day. Negative means the disk is filling up.
    public let bytesPerDay: Double
    /// Days from `asOf` until free space reaches zero; nil if it's steady, growing, or years away.
    public let daysUntilFull: Double?
    /// Free space the forecast starts from.
    public let current: Int64
    public let asOf: Date
    /// Number of days with data the trend is based on.
    public let daysOfData: Int

    public init(bytesPerDay: Double, daysUntilFull: Double?, current: Int64, asOf: Date, daysOfData: Int) {
        self.bytesPerDay = bytesPerDay
        self.daysUntilFull = daysUntilFull
        self.current = current
        self.asOf = asOf
        self.daysOfData = daysOfData
    }

    public var isFillingUp: Bool { daysUntilFull != nil }
    public var fullDate: Date? { daysUntilFull.map { asOf.addingTimeInterval($0 * 86_400) } }

    /// Projected free space at `date` (never below zero).
    public func projectedFree(at date: Date) -> Int64 {
        let days = date.timeIntervalSince(asOf) / 86_400
        return max(0, Int64(Double(current) + bytesPerDay * days))
    }
}

public enum DiskForecaster {
    /// Fewer days than this and there's no forecast.
    public static let minimumDays = 3
    /// The trend is based on this many recent days.
    public static let windowDays = 30
    /// Further away than this counts as "not filling up".
    public static let horizonDays: Double = 3 * 365

    /// Forecasts when a disk fills up from its history: a Theil–Sen (median of pairwise slopes) trend over the
    /// daily minimum free space of the last `windowDays`. One or two one-off jumps up (cleanups) are taken out
    /// first so they don't hide an underlying decline; regular cleanups (three or more) are part of the pattern.
    public static func forecast(for volume: VolumeHistory, now: Date, calendar: Calendar = .current) -> DiskForecast? {
        forecast(daily: volume.dailyMinimums(calendar: calendar), current: volume.latest, now: now, calendar: calendar)
    }

    /// `daily` holds one minimum per day (see `DiskHistory.dailyMinimums`); `current` is the latest raw sample.
    public static func forecast(
        daily: [DiskSample], current: DiskSample? = nil, now: Date, windowDays: Int = windowDays, calendar: Calendar = .current
    ) -> DiskForecast? {
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(-Double(windowDays) * 86_400)
        let points = daily.filter { $0.date >= windowStart && $0.date <= now }
        guard points.count >= minimumDays, let first = points.first, let last = points.last else { return nil }

        let xs = points.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let capacity = last.capacity
        let ys = removingOneOffJumps(xs: xs, ys: points.map { Double($0.free) }, minimumJump: max(2e9, Double(capacity) / 100))
        guard let slope = theilSenSlope(xs: xs, ys: ys) else { return nil }

        let start = current.flatMap { $0.date >= last.date ? $0 : nil } ?? last
        var days: Double?
        if slope < 0 {
            let remaining = Double(start.free) / -slope
            if remaining <= horizonDays { days = max(0, remaining) }
        }
        return DiskForecast(bytesPerDay: slope, daysUntilFull: days, current: start.free, asOf: start.date, daysOfData: points.count)
    }

    /// Median of the slopes between every pair of points. Robust to outliers (up to ~29% of points).
    public static func theilSenSlope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count else { return nil }
        var slopes = [Double]()
        slopes.reserveCapacity(xs.count * (xs.count - 1) / 2)
        for i in xs.indices {
            for j in xs.indices where j > i {
                let dx = xs[j] - xs[i]
                if abs(dx) > 1e-9 { slopes.append((ys[j] - ys[i]) / dx) }
            }
        }
        return median(slopes)
    }

    /// Removes sudden increases that stand out from the day-to-day pattern by shifting everything after them
    /// down, as if the cleanup hadn't happened. Left alone if there are three or more (recurring cleanups).
    static func removingOneOffJumps(xs: [Double], ys: [Double], minimumJump: Double) -> [Double] {
        guard ys.count >= 3 else { return ys }
        let steps = ys.indices.dropFirst().map { (index: $0, dx: max(xs[$0] - xs[$0 - 1], 1e-9), dy: ys[$0] - ys[$0 - 1]) }
        guard let typicalRate = median(steps.map { $0.dy / $0.dx }) else { return ys }
        let excess = steps.map { $0.dy - typicalRate * $0.dx }
        let spread = median(excess.map(abs)) ?? 0
        let threshold = max(minimumJump, 5 * 1.4826 * spread)
        let jumps = zip(steps, excess).filter { $1 > threshold }
        guard !jumps.isEmpty, jumps.count <= 2 else { return ys }

        var adjusted = ys
        for (step, amount) in jumps {
            for index in step.index..<adjusted.count { adjusted[index] -= amount }
        }
        return adjusted
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: - Schedule

public enum ScheduleFrequency: String, CaseIterable, Sendable, Codable {
    case off, daily, weekly, monthly
}

/// When scheduled cleanups (or the weekly summary) run. Slots are at a fixed local time; a missed slot
/// (Mac asleep, Reclaim not running) runs once, the next time Reclaim checks.
public struct CleanupSchedule: Sendable, Hashable {
    public var frequency: ScheduleFrequency
    /// For weekly schedules: 1 = Sunday … 7 = Saturday (Gregorian `Calendar` numbering).
    public var weekday: Int
    /// Local hour of the slot.
    public var hour: Int
    /// Only clean when the startup disk has less than this free (nil: always).
    public var minimumFree: Int64?

    public init(frequency: ScheduleFrequency, weekday: Int = 2, hour: Int = 9, minimumFree: Int64? = nil) {
        self.frequency = frequency
        self.weekday = min(7, max(1, weekday))
        self.hour = min(23, max(0, hour))
        self.minimumFree = minimumFree
    }

    /// The first slot strictly after `date`, or nil if the schedule is off.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents(hour: hour, minute: 0, second: 0)
        switch frequency {
        case .off: return nil
        case .daily: break
        case .weekly: components.weekday = weekday
        case .monthly: components.day = 1
        }
        // `.nextTime` keeps a slot that falls into a DST gap on the same day instead of skipping it.
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime, direction: .forward)
    }

    /// When the schedule runs next: the first slot after the last run, or after `anchor` (when it was set up)
    /// so turning it on doesn't trigger a run straight away. May be in the past if a run is overdue.
    public func nextRun(lastRun: Date?, anchor: Date, calendar: Calendar = .current) -> Date? {
        nextRun(after: max(lastRun ?? anchor, anchor), calendar: calendar)
    }

    public func isDue(lastRun: Date?, anchor: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextRun(lastRun: lastRun, anchor: anchor, calendar: calendar) else { return false }
        return next <= now
    }

    /// Whether a due run should actually clean, given the startup disk's free space.
    public func allowsCleanup(free: Int64?) -> Bool {
        guard let minimumFree, let free else { return true }
        return free < minimumFree
    }
}

// MARK: - Formatting

public enum DiskHistoryFormat {
    /// "+3.2 GB", "−12.4 GB" (with a real minus sign) or "No change".
    public static func signedSize(_ bytes: Int64) -> String {
        guard abs(bytes) >= 1_000_000 else { return String(localized: "No change") }
        return (bytes < 0 ? "−" : "+") + ByteSize.format(abs(bytes))
    }

    /// "less than a day", "~5 days", "~6 weeks", "~4 months", "~2 years".
    public static func approximateDuration(days: Double) -> String {
        // Shown after "in" ("Full in ~6 weeks"), which matters for languages that inflect the unit.
        switch days {
        case ..<1:
            return String(localized: "less than a day")
        case ..<14:
            let count = Int(days.rounded())
            return count == 1 ? String(localized: "~1 day") : String(localized: "~\(count) days")
        case ..<60:
            let count = Int((days / 7).rounded())
            return count == 1 ? String(localized: "~1 week") : String(localized: "~\(count) weeks")
        case ..<730:
            let count = Int((days / 30.44).rounded())
            return count == 1 ? String(localized: "~1 month") : String(localized: "~\(count) months")
        default:
            let count = Int((days / 365.25).rounded())
            return count == 1 ? String(localized: "~1 year") : String(localized: "~\(count) years")
        }
    }
}

// MARK: - Store

/// Persists `DiskHistory` as JSON (shared by the app, which records, and the CLI, which reads).
/// An actor so file I/O stays off the main thread and writes are serialized.
public actor DiskHistoryStore {
    public static var defaultFile: URL { ReclaimPaths.supportDirectory.appending(path: "disk-history.json") }

    private let file: URL
    private let policy: RetentionPolicy
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var cached: DiskHistory?

    public init(
        file: URL = DiskHistoryStore.defaultFile, policy: RetentionPolicy = .standard, calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.file = file
        self.policy = policy
        self.calendar = calendar
        self.now = now
    }

    /// Reads a history file; empty if it's missing or unreadable.
    public static func load(from file: URL) -> DiskHistory {
        guard let data = try? Data(contentsOf: file) else { return DiskHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(DiskHistory.self, from: data)) ?? DiskHistory()
    }

    public func history() -> DiskHistory {
        if let cached { return cached }
        let loaded = Self.load(from: file)
        cached = loaded
        return loaded
    }

    /// Records the readings (throttled per `RetentionPolicy.sampleInterval`). Returns the updated history if
    /// anything was written, nil if every disk already had a sample this interval.
    @discardableResult
    public func record(_ readings: [DiskReading]) -> DiskHistory? {
        var updated = history()
        guard updated.record(readings, at: now(), policy: policy, calendar: calendar) else { return nil }
        cached = updated
        save(updated)
        return updated
    }

    private func save(_ history: DiskHistory) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
