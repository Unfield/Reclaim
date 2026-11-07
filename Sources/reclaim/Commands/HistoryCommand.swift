import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let historyUsage = """
  reclaim history                    Free space over time and when each disk will be full
      --days <n>                     Period to look back over (default: 30)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let historyOptionsWithValues: Set<String> = ["days"]

func runHistory(_ args: Arguments) async throws {
    var days = 30
    if let text = args.value("days") {
        guard let parsed = Int(text), (1...730).contains(parsed) else { throw UsageError("invalid number of days '\(text)' (1–730)") }
        days = parsed
    }

    // The app does the recording; the CLI only reads what it wrote.
    let history = DiskHistoryStore.load(from: DiskHistoryStore.defaultFile)
    let volumes = history.volumes
        .filter { $0.sampleCount > 0 }
        .sorted { lhs, rhs in
            if lhs.isStartup != rhs.isStartup { return lhs.isStartup }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    guard !volumes.isEmpty else {
        print("No disk history yet.")
        print(Style.dim("The Reclaim app records free space every hour while it's running. Open it and check back in a few days."))
        return
    }

    let now = Date()
    let start = now.addingTimeInterval(-Double(days) * 86_400)
    var mounted = [String: VolumeInfo]()
    for volume in VolumeInfo.mounted() where DiskHistory.shouldRecord(volume) {
        mounted[DiskHistory.key(for: volume)] = volume
    }
    let period = days == 1 ? "1 day" : "\(days) days"
    let short = Date.FormatStyle.dateTime.month(.abbreviated).day()

    print(Style.bold("Disk history") + Style.dim("  last \(period), recorded by the Reclaim app while it's running"))
    for volume in volumes {
        print()
        let live = mounted[volume.id]
        let latest = volume.latest
        let free = live?.availableForImportantUsage ?? latest?.free ?? 0
        let capacity = live?.totalCapacity ?? latest?.capacity ?? 0

        let note = volume.isStartup ? "startup disk" : live == nil ? "not connected, last seen \(volume.lastSeen.formatted(short))" : nil
        print(Style.bold(volume.name) + (note.map { Style.dim("  (\($0))") } ?? ""))
        print("  Free       \(ByteSize.format(free)) of \(ByteSize.format(capacity))")

        if let change = volume.change(since: start) {
            let delta = change.delta + (live.map { $0.availableForImportantUsage - (latest?.free ?? 0) } ?? 0)
            let span = change.days >= Double(days) - 1 ? "in \(period)" : "since \(change.start.formatted(short))"
            let text = DiskHistoryFormat.signedSize(delta)
            print("  Change     \(delta < 0 ? Style.yellow(text) : text) \(span)")
        } else {
            print("  Change     " + Style.dim("not enough data yet"))
        }

        let samples = volume.samples(since: start)
        if samples.count >= 2 {
            let buckets = DiskHistory.buckets(samples, from: start, to: now, count: 30)
            let line = DiskHistory.sparkline(buckets, minimumSpan: max(1_000_000_000, capacity / 100))
            print("  Trend      \(Style.cyan(line))  " + Style.dim("\(start.formatted(short)) → today"))
        }

        print("  Forecast   " + forecastText(DiskForecaster.forecast(for: volume, now: now), now: now))
    }
}

private func forecastText(_ forecast: DiskForecast?, now: Date) -> String {
    guard let forecast else {
        return Style.dim("needs at least \(DiskForecaster.minimumDays) days of recent data")
    }
    guard let days = forecast.daysUntilFull, let full = forecast.fullDate else {
        return Style.green("Not filling up")
    }
    let sameYear = Calendar.current.isDate(full, equalTo: now, toGranularity: .year)
    let date = full.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    let headline = days < 1 ? "Full within a day" : "Full around \(date) (in \(DiskHistoryFormat.approximateDuration(days: days)))"
    let colored = days < 7 ? Style.red(headline) : days < 30 ? Style.yellow(headline) : headline
    return colored + Style.dim(", losing about \(ByteSize.format(Int64(-forecast.bytesPerDay))) a day")
}
