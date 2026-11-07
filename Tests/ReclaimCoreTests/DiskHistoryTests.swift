import Foundation
import Testing
@testable import ReclaimCore

private let gb: Int64 = 1_000_000_000
private let capacity: Int64 = 500 * gb
private let day: TimeInterval = 86_400

private func calendar(_ timeZone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar = calendar()) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
}

private func reading(_ free: Int64, key: String = "disk", capacity: Int64 = capacity) -> DiskReading {
    DiskReading(key: key, name: "Disk \(key)", isStartup: key == DiskHistory.startupKey, free: free, capacity: capacity)
}

/// A settable clock for the store.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// Daily samples at midnight UTC, `values` in GB.
private func dailySeries(_ values: [Double], start: Date = date(2026, 1, 1)) -> [DiskSample] {
    values.enumerated().map { index, value in
        DiskSample(date: start.addingTimeInterval(Double(index) * day), free: Int64(value * Double(gb)), capacity: capacity)
    }
}

// MARK: - Recording

@Suite struct DiskHistoryRecordingTests {
    @Test func throttlesToOneSamplePerHour() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "disk-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = TestClock(date(2026, 3, 1, 10, 0))
        let store = DiskHistoryStore(file: file, calendar: calendar(), now: { clock.now })

        #expect(await store.record([reading(100 * gb)]) != nil)
        clock.advance(5 * 60)
        #expect(await store.record([reading(99 * gb)]) == nil)
        clock.advance(50 * 60) // 10:55, same hour
        #expect(await store.record([reading(98 * gb)]) == nil)
        clock.advance(10 * 60) // 11:05
        #expect(await store.record([reading(97 * gb)]) != nil)
        // A newly connected disk is recorded right away.
        #expect(await store.record([reading(97 * gb), reading(10 * gb, key: "external")]) != nil)

        let reloaded = DiskHistoryStore.load(from: file)
        #expect(reloaded.volume("disk")?.hourly.map(\.free) == [100 * gb, 97 * gb])
        #expect(reloaded.volume("external")?.hourly.count == 1)
    }

    @Test func ignoresBrokenFilesAndEmptyDisks() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "disk-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        #expect(DiskHistoryStore.load(from: file).volumes.isEmpty)

        let store = DiskHistoryStore(file: file, now: { date(2026, 3, 1) })
        #expect(await store.record([reading(0, capacity: 0)]) == nil)
        #expect(await store.record([reading(5 * gb)])?.volumes.count == 1)
    }

    @Test func samplesRoundTripCompactly() throws {
        let sample = DiskSample(date: date(2026, 3, 1, 12), free: 123 * gb, capacity: capacity)
        let data = try JSONEncoder().encode(sample)
        #expect(String(decoding: data, as: UTF8.self) == "[\(Int(sample.date.timeIntervalSince1970)),\(123 * gb),\(capacity)]")
        #expect(try JSONDecoder().decode(DiskSample.self, from: data) == sample)
    }

    @Test func aggregatesOldSamplesIntoDailyMinimums() throws {
        let utc = calendar()
        let start = date(2026, 1, 1)
        var history = DiskHistory()
        // 40 days of hourly samples; free space dips to 50 GB at 3:00 every day.
        for hour in 0..<(40 * 24) {
            let now = start.addingTimeInterval(Double(hour) * 3_600)
            let free = hour % 24 == 3 ? 50 * gb : 100 * gb
            history.record([reading(free)], at: now, calendar: utc)
        }
        let volume = try #require(history.volume("disk"))
        let end = start.addingTimeInterval(Double(40 * 24 - 1) * 3_600)

        #expect(volume.hourly.allSatisfy { $0.date >= end.addingTimeInterval(-30 * day) })
        #expect(volume.hourly.count <= 30 * 24 + 1)
        #expect(volume.daily.count == 10)
        #expect(volume.daily.allSatisfy { $0.free == 50 * gb })
        #expect(volume.daily.map(\.date) == (0..<10).map { start.addingTimeInterval(Double($0) * day) })
        #expect(volume.daily.last.map { $0.date < volume.hourly[0].date } == true)

        // Every day still has one daily minimum, whether raw or aggregated.
        let minimums = volume.dailyMinimums(calendar: utc)
        #expect(minimums.count == 40)
        #expect(minimums.allSatisfy { $0.free == 50 * gb })
    }

    @Test func dropsDataPastRetentionAndCapsVolumes() {
        let now = date(2026, 6, 1)
        let policy = RetentionPolicy(maxVolumes: 3)
        var history = DiskHistory(volumes: [
            VolumeHistory(id: "old", name: "Old", isStartup: false, lastSeen: now.addingTimeInterval(-800 * day),
                          daily: [DiskSample(date: now.addingTimeInterval(-800 * day), free: gb, capacity: capacity)]),
            VolumeHistory(id: "long", name: "Long", isStartup: false, lastSeen: now.addingTimeInterval(-day), daily: [
                DiskSample(date: now.addingTimeInterval(-740 * day), free: gb, capacity: capacity),
                DiskSample(date: now.addingTimeInterval(-700 * day), free: gb, capacity: capacity),
            ]),
            VolumeHistory(id: DiskHistory.startupKey, name: "HD", isStartup: true, lastSeen: now.addingTimeInterval(-90 * day),
                          daily: [DiskSample(date: now.addingTimeInterval(-90 * day), free: gb, capacity: capacity)]),
            VolumeHistory(id: "a", name: "A", isStartup: false, lastSeen: now.addingTimeInterval(-2 * day),
                          hourly: [DiskSample(date: now.addingTimeInterval(-2 * day), free: gb, capacity: capacity)]),
            VolumeHistory(id: "b", name: "B", isStartup: false, lastSeen: now.addingTimeInterval(-3 * day),
                          hourly: [DiskSample(date: now.addingTimeInterval(-3 * day), free: gb, capacity: capacity)]),
        ])
        history.compact(now: now, policy: policy, calendar: calendar())

        #expect(Set(history.volumes.map(\.id)) == [DiskHistory.startupKey, "long", "a"])
        #expect(history.volume("long")?.daily.count == 1)
    }

    @Test func skipsDiskImagesAndReadOnlyDisks() {
        func volume(_ kind: VolumeInfo.Kind, readOnly: Bool = false) -> VolumeInfo {
            VolumeInfo(url: URL(filePath: "/Volumes/X"), name: "X", totalCapacity: capacity, availableCapacity: gb,
                       availableForImportantUsage: gb, kind: kind, isReadOnly: readOnly)
        }
        #expect(DiskHistory.shouldRecord(volume(.external)))
        #expect(DiskHistory.shouldRecord(volume(.startup)))
        #expect(!DiskHistory.shouldRecord(volume(.diskImage)))
        #expect(!DiskHistory.shouldRecord(volume(.external, readOnly: true)))
        #expect(DiskHistory.key(for: volume(.startup)) == DiskHistory.startupKey)
    }
}

// MARK: - Analysis

@Suite struct DiskHistoryAnalysisTests {
    @Test func changeSinceUsesFirstSampleInRange() {
        let start = date(2026, 1, 1)
        let volume = VolumeHistory(id: "d", name: "D", isStartup: false, lastSeen: start, hourly: dailySeries([100, 90, 80, 85], start: start))
        let change = volume.change(since: start.addingTimeInterval(day))
        #expect(change?.delta == -5 * gb)
        #expect(change?.days == 2)
        #expect(volume.change(since: start.addingTimeInterval(10 * day)) == nil)
    }

    @Test func findsNotableChangesNewestFirst() {
        // Steady small use, a cleanup (+30) and a download split over two samples (−6, −6).
        let samples = dailySeries([100, 99, 98, 128, 127, 121, 115, 114])
        let changes = DiskHistory.notableChanges(in: samples, threshold: 10 * gb)
        #expect(changes.map(\.delta) == [-12 * gb, 30 * gb])
        #expect(changes.first?.freeAfter == 115 * gb)
        #expect(changes.last?.isGain == true)
    }

    @Test func sparklineScalesAndShowsGaps() {
        #expect(DiskHistory.sparkline([0, 7, nil, 3]) == "▁█ ▄")
        #expect(DiskHistory.sparkline([5, 5, 5]) == "▄▄▄")
        #expect(DiskHistory.sparkline([nil, nil]) == "  ")
        // A small wiggle stays small when a minimum span is given.
        #expect(DiskHistory.sparkline([100, 101], minimumSpan: 14) == "▄▅")

        let start = date(2026, 1, 1)
        let buckets = DiskHistory.buckets(dailySeries([10, 9, 8, 7], start: start), from: start, to: start.addingTimeInterval(4 * day), count: 2)
        #expect(buckets == [9 * gb, 7 * gb])
    }

    @Test func formatsSignedSizesAndDurations() {
        #expect(DiskHistoryFormat.signedSize(-12_400_000_000) == "−" + ByteSize.format(12_400_000_000))
        #expect(DiskHistoryFormat.signedSize(3_200_000_000) == "+" + ByteSize.format(3_200_000_000))
        #expect(DiskHistoryFormat.signedSize(10) == "No change")
        #expect(DiskHistoryFormat.approximateDuration(days: 0.5) == "less than a day")
        #expect(DiskHistoryFormat.approximateDuration(days: 1) == "~1 day")
        #expect(DiskHistoryFormat.approximateDuration(days: 42) == "~6 weeks")
        #expect(DiskHistoryFormat.approximateDuration(days: 120) == "~4 months")
        #expect(DiskHistoryFormat.approximateDuration(days: 800) == "~2 years")
    }
}

// MARK: - Forecast

@Suite struct DiskForecastTests {
    private let start = date(2026, 1, 1)
    private var now: Date { start.addingTimeInterval(29.5 * day) }

    private func forecast(_ values: [Double]) -> DiskForecast? {
        DiskForecaster.forecast(daily: dailySeries(values, start: start), now: now, calendar: calendar())
    }

    @Test func steadyDecline() throws {
        let result = try #require(forecast((0..<30).map { 100 - Double($0) }))
        #expect(abs(result.bytesPerDay + Double(gb)) < 1e6)
        // 71 GB left at 1 GB a day.
        #expect(abs((result.daysUntilFull ?? 0) - 71) < 0.01)
        #expect(result.fullDate == result.asOf.addingTimeInterval(71 * day))
        #expect(result.daysOfData == 30)
        #expect(result.projectedFree(at: result.asOf.addingTimeInterval(10 * day)) == 61 * gb)
    }

    @Test func flatIsNotFillingUp() throws {
        let result = try #require(forecast(Array(repeating: 80, count: 30)))
        #expect(result.bytesPerDay == 0)
        #expect(result.daysUntilFull == nil)
        #expect(!result.isFillingUp)
    }

    @Test func increasingIsNotFillingUp() throws {
        let result = try #require(forecast((0..<20).map { 50 + Double($0) * 0.5 }))
        #expect(result.bytesPerDay > 0)
        #expect(result.daysUntilFull == nil)
    }

    @Test func noisyDeclineFindsTheTrend() throws {
        // −1 GB a day with ±3 GB of deterministic noise.
        var seed: UInt64 = 42
        let values = (0..<30).map { index -> Double in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(seed >> 33) / Double(1 << 31) * 6 - 3
            return 200 - Double(index) + noise
        }
        let result = try #require(forecast(values))
        #expect(abs(result.bytesPerDay / Double(gb) + 1) < 0.2)
        #expect(result.isFillingUp)
    }

    @Test func oneOffCleanupDoesNotHideTheDecline() throws {
        // −1 GB a day, with a 40 GB cleanup halfway through.
        let values = (0..<30).map { index in 100 - Double(index) + (index >= 15 ? 40 : 0) }
        let result = try #require(forecast(values))
        #expect(abs(result.bytesPerDay / Double(gb) + 1) < 0.05)
        // Counts down from what's actually free now (111 GB).
        #expect(abs((result.daysUntilFull ?? 0) - 111) < 1)
    }

    @Test func recurringCleanupsKeepADiskStable() throws {
        // Fills up 2 GB a day, cleaned back up every week: no long-term decline.
        let values = (0..<30).map { index in 100 - Double(index % 7) * 2 }
        let result = try #require(forecast(values))
        #expect(result.bytesPerDay > -0.5 * Double(gb))
    }

    @Test func needsThreeDaysOfRecentData() {
        #expect(forecast([100, 99]) == nil)
        #expect(forecast([100, 99, 98]) != nil)
        // Data older than the window doesn't count.
        let old = dailySeries([100, 99, 98, 97], start: start.addingTimeInterval(-60 * day))
        #expect(DiskForecaster.forecast(daily: old, now: now, calendar: calendar()) == nil)
    }

    @Test func distantFullDateCountsAsNotFillingUp() throws {
        // 10 MB a day off 400 GB is over 100 years away.
        let result = try #require(forecast((0..<30).map { 400 - Double($0) * 0.01 }))
        #expect(result.bytesPerDay < 0)
        #expect(result.daysUntilFull == nil)
    }

    @Test func startsFromTheLatestSample() throws {
        let daily = dailySeries((0..<10).map { 100 - Double($0) * 2 }, start: start)
        let latest = DiskSample(date: start.addingTimeInterval(9.5 * day), free: 90 * gb, capacity: capacity)
        let result = try #require(DiskForecaster.forecast(daily: daily, current: latest, now: now, calendar: calendar()))
        #expect(result.current == 90 * gb)
        #expect(result.asOf == latest.date)
        #expect(abs((result.daysUntilFull ?? 0) - 45) < 0.01)
    }

    @Test func forecastFromVolumeUsesDailyMinimums() throws {
        let utc = calendar()
        var history = DiskHistory()
        // Four days; each day dips 5 GB below its usual level, which drops 1 GB a day.
        for hour in 0..<(4 * 24) {
            let base = 100 - Double(hour / 24)
            let free = Int64((hour % 24 == 12 ? base - 5 : base) * Double(gb))
            history.record([reading(free)], at: start.addingTimeInterval(Double(hour) * 3_600), calendar: utc)
        }
        let volume = try #require(history.volume("disk"))
        let result = try #require(DiskForecaster.forecast(for: volume, now: start.addingTimeInterval(4 * day), calendar: utc))
        #expect(abs(result.bytesPerDay / Double(gb) + 1) < 0.01)
        #expect(result.daysOfData == 4)
    }
}

// MARK: - Schedule

@Suite struct CleanupScheduleTests {
    @Test func dailyRunsAtTheNextSlot() {
        let utc = calendar()
        let schedule = CleanupSchedule(frequency: .daily, hour: 9)
        #expect(schedule.nextRun(after: date(2026, 11, 3, 10), calendar: utc) == date(2026, 11, 4, 9))
        #expect(schedule.nextRun(after: date(2026, 11, 3, 8), calendar: utc) == date(2026, 11, 3, 9))
        #expect(schedule.nextRun(after: date(2026, 11, 3, 9), calendar: utc) == date(2026, 11, 4, 9))
    }

    @Test func weeklyRunsOnTheChosenDay() {
        let utc = calendar()
        // Nov 4, 2026 is a Wednesday; weekday 2 is Monday.
        let schedule = CleanupSchedule(frequency: .weekly, weekday: 2)
        #expect(schedule.nextRun(after: date(2026, 11, 4, 12), calendar: utc) == date(2026, 11, 9, 9))
        #expect(schedule.nextRun(after: date(2026, 11, 9, 9), calendar: utc) == date(2026, 11, 16, 9))
    }

    @Test func monthlyRunsOnTheFirst() {
        let utc = calendar()
        let schedule = CleanupSchedule(frequency: .monthly)
        #expect(schedule.nextRun(after: date(2026, 1, 15), calendar: utc) == date(2026, 2, 1, 9))
        #expect(schedule.nextRun(after: date(2026, 12, 1, 9, 30), calendar: utc) == date(2027, 1, 1, 9))
    }

    @Test func offNeverRuns() {
        let schedule = CleanupSchedule(frequency: .off)
        #expect(schedule.nextRun(after: date(2026, 1, 1)) == nil)
        #expect(!schedule.isDue(lastRun: nil, anchor: .distantPast, now: .distantFuture))
    }

    @Test func isDueAfterTheAnchorAndLastRun() {
        let utc = calendar()
        let schedule = CleanupSchedule(frequency: .daily)
        let anchor = date(2026, 11, 3, 15) // turned on in the afternoon: first run tomorrow
        #expect(!schedule.isDue(lastRun: nil, anchor: anchor, now: date(2026, 11, 4, 8), calendar: utc))
        #expect(schedule.isDue(lastRun: nil, anchor: anchor, now: date(2026, 11, 4, 9), calendar: utc))
        // A run at 9:05 isn't due again until tomorrow.
        #expect(!schedule.isDue(lastRun: date(2026, 11, 4, 9, 5), anchor: anchor, now: date(2026, 11, 4, 23), calendar: utc))
        // Missed a week (Mac was off): due once, now.
        #expect(schedule.isDue(lastRun: date(2026, 11, 4, 9, 5), anchor: anchor, now: date(2026, 11, 12, 14), calendar: utc))
        #expect(schedule.nextRun(lastRun: date(2026, 11, 4, 9, 5), anchor: anchor, calendar: utc) == date(2026, 11, 5, 9))
    }

    @Test func survivesDaylightSavingChanges() throws {
        let berlin = calendar("Europe/Berlin")
        let daily = CleanupSchedule(frequency: .daily, hour: 9)

        // Spring forward (Mar 29, 2026): the next 9:00 is only 23 hours later.
        let spring = try #require(daily.nextRun(after: date(2026, 3, 28, 9, 0, in: berlin), calendar: berlin))
        #expect(spring == date(2026, 3, 29, 9, 0, in: berlin))
        #expect(spring.timeIntervalSince(date(2026, 3, 28, 9, 0, in: berlin)) == 23 * 3_600)

        // Fall back (Oct 25, 2026): 25 hours.
        let fall = try #require(daily.nextRun(after: date(2026, 10, 24, 9, 0, in: berlin), calendar: berlin))
        #expect(berlin.component(.hour, from: fall) == 9)
        #expect(fall.timeIntervalSince(date(2026, 10, 24, 9, 0, in: berlin)) == 25 * 3_600)

        // A slot inside the skipped hour still runs that day rather than being skipped.
        let gap = try #require(CleanupSchedule(frequency: .daily, hour: 2).nextRun(after: date(2026, 3, 28, 12, 0, in: berlin), calendar: berlin))
        #expect(berlin.isDate(gap, inSameDayAs: date(2026, 3, 29, 12, 0, in: berlin)))

        // Weekly across the change stays on Monday 9:00 local time.
        let weekly = try #require(CleanupSchedule(frequency: .weekly, weekday: 2).nextRun(after: date(2026, 3, 27, 12, 0, in: berlin), calendar: berlin))
        #expect(weekly == date(2026, 3, 30, 9, 0, in: berlin))
    }

    @Test func minimumFreeThreshold() {
        let always = CleanupSchedule(frequency: .weekly)
        #expect(always.allowsCleanup(free: 400 * gb))
        let whenLow = CleanupSchedule(frequency: .weekly, minimumFree: 20 * gb)
        #expect(whenLow.allowsCleanup(free: 19 * gb))
        #expect(!whenLow.allowsCleanup(free: 20 * gb))
        #expect(whenLow.allowsCleanup(free: nil))
    }
}
