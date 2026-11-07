import Charts
import ReclaimCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var history = model.history
        let volumes = history.chartableVolumes
        let selected = volumes.first { $0.id == history.selectedVolumeKey } ?? volumes.first

        Group {
            if let selected {
                ScrollView {
                    HistoryContent(volume: selected, range: history.range)
                        .padding(20)
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                }
                .topBar {
                    HStack(spacing: 10) {
                        Picker("Disk", selection: Binding(get: { selected.id }, set: { history.selectedVolumeKey = $0 })) {
                            ForEach(volumes) { volume in
                                Label(volume.name, systemImage: symbol(for: volume)).tag(volume.id)
                            }
                        }
                        .fixedSize()

                        Spacer()

                        Picker("Range", selection: $history.range) {
                            ForEach(HistoryRange.allCases) { range in
                                Text(range.title).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } else if !history.isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Collecting Data", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Reclaim records free space every hour while it's running. Check back in a few days.")
                }
            }
        }
        .navigationTitle("Disk History")
    }

    private func symbol(for volume: VolumeHistory) -> String {
        model.volumes.first { model.history.key(for: $0) == volume.id }?.symbolName
            ?? (volume.isStartup ? "internaldrive" : "externaldrive")
    }
}

// MARK: - Content

private struct HistoryContent: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeHistory
    let range: HistoryRange

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-Double(range.days) * 86_400)
        let mounted = model.volumes.first { model.history.key(for: $0) == volume.id }
        let latest = volume.latest
        let capacity = mounted?.totalCapacity ?? latest?.capacity ?? 0
        let free = mounted?.availableForImportantUsage ?? latest?.free ?? 0
        let tint = mounted?.usageTint ?? Self.tint(free: free, capacity: capacity)
        let forecast = model.history.forecasts[volume.id]
        let points = Self.points(for: volume, range: range, since: start)
        let threshold = max(2_000_000_000, capacity / 200)
        let changes = Array(DiskHistory.notableChanges(in: points, threshold: threshold).prefix(6))

        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                StatCard(
                    title: String(localized: "Free Now"),
                    symbol: mounted?.symbolName ?? (volume.isStartup ? "internaldrive" : "externaldrive"),
                    value: ByteSize.format(free),
                    detail: mounted != nil
                        ? String(localized: "of \(ByteSize.format(capacity))")
                        : String(localized: "Not connected. Last seen \(volume.lastSeen.formatted(.dateTime.month(.abbreviated).day())).")
                )
                changeCard(since: start)
                forecastCard(forecast, now: now)
            }

            FreeSpaceChart(points: points, forecast: forecast, start: start, now: now, range: range, tint: tint)

            if !changes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: String(localized: "Biggest Changes"), trailing: String(localized: "\(ByteSize.format(threshold)) or more"))
                    Card(padding: 0) {
                        ForEach(changes) { change in
                            ChangeRow(change: change, showsTime: range != .year)
                            if change.id != changes.last?.id { Divider().padding(.leading, 56) }
                        }
                    }
                }
            }
        }
    }

    private func changeCard(since start: Date) -> StatCard {
        guard let change = volume.change(since: start) else {
            return StatCard(title: String(localized: "Change"), symbol: "arrow.up.arrow.down", value: "—", detail: String(localized: "Not enough data yet"))
        }
        let detail: String
        if change.days >= Double(range.days) - 1 {
            detail = range == .year ? String(localized: "in the last year") : String(localized: "in the last \(range.days) days")
        } else {
            detail = String(localized: "since \(change.start.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return StatCard(title: String(localized: "Change"), symbol: "arrow.up.arrow.down", value: DiskHistoryFormat.signedSize(change.delta), detail: detail)
    }

    private func forecastCard(_ forecast: DiskForecast?, now: Date) -> StatCard {
        let title = String(localized: "Forecast")
        let symbol = "chart.line.downtrend.xyaxis"
        guard let forecast else {
            return StatCard(
                title: title, symbol: symbol, value: String(localized: "Collecting data"),
                detail: String(localized: "Needs at least \(DiskForecaster.minimumDays) days of history")
            )
        }
        guard let days = forecast.daysUntilFull, let full = forecast.fullDate else {
            return StatCard(
                title: title, symbol: symbol, value: String(localized: "Not filling up"),
                detail: forecast.bytesPerDay < 0
                    ? String(localized: "Free space is shrinking very slowly")
                    : String(localized: "Free space is steady or growing")
            )
        }
        let sameYear = Calendar.current.isDate(full, equalTo: now, toGranularity: .year)
        let date = full.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
        return StatCard(
            title: title, symbol: symbol,
            value: days < 1 ? String(localized: "Full within a day") : String(localized: "Full around \(date)"),
            detail: String(localized: "At this rate. Losing about \(ByteSize.format(Int64(-forecast.bytesPerDay))) a day"),
            valueTint: days < 7 ? .red : days < 30 ? .orange : nil
        )
    }

    /// Raw samples for short ranges; one point per day (its lowest free space) for the year, plus the latest sample.
    private static func points(for volume: VolumeHistory, range: HistoryRange, since start: Date) -> [DiskSample] {
        guard range == .year else { return volume.samples(since: start) }
        var points = volume.dailyMinimums().filter { $0.date >= start }
        if let latest = volume.latest, latest.date > (points.last?.date ?? .distantPast) { points.append(latest) }
        return points
    }

    /// Same thresholds as `VolumeInfo.usageTint`, for disks that aren't connected.
    private static func tint(free: Int64, capacity: Int64) -> Color {
        let used = capacity > 0 ? Double(capacity - free) / Double(capacity) : 0
        return used > 0.9 ? .red : used > 0.75 ? .orange : .accentColor
    }
}

// MARK: - Summary cards

private struct StatCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var valueTint: Color?

    var body: some View {
        Card {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueTint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 2)
        }
    }
}

// MARK: - Chart

private struct FreeSpaceChart: View {
    let points: [DiskSample]
    let forecast: DiskForecast?
    let start: Date
    let now: Date
    let range: HistoryRange
    let tint: Color
    @State private var hoverDate: Date?

    /// The dashed forecast: from the latest sample towards "full", at most half a range into the future.
    private var projection: [DiskSample] {
        guard let forecast, let days = forecast.daysUntilFull, forecast.asOf >= start else { return [] }
        let horizon = now.addingTimeInterval(Double(range.days) / 2 * 86_400)
        let end = min(forecast.asOf.addingTimeInterval(days * 86_400), max(horizon, forecast.asOf))
        guard end > forecast.asOf else { return [] }
        return [
            DiskSample(date: forecast.asOf, free: forecast.current, capacity: 0),
            DiskSample(date: end, free: forecast.projectedFree(at: end), capacity: 0),
        ]
    }

    var body: some View {
        let projection = projection
        let end = max(now, projection.last?.date ?? now)
        let top = max(points.map(\.free).max() ?? 0, projection.first?.free ?? 0, 1)
        let hover = hoverInfo(projection: projection)
        let shown = hover ?? points.last.map { (date: $0.date, free: $0.free, isForecast: false) }
        let reachesFull = projection.last.map { $0.free == 0 } ?? false

        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Free Space").font(.headline)
                Spacer()
                Text(shown.map { point in
                    let text = String(localized: "\(ByteSize.format(point.free)) free · \(format(point.date))")
                    return point.isForecast ? String(localized: "Forecast: \(text)") : text
                } ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)), series: .value("Series", "Free"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(Array(projection.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)), series: .value("Series", "Forecast"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                if reachesFull, let full = projection.last {
                    PointMark(x: .value("Date", full.date), y: .value("Free", 0.0))
                        .foregroundStyle(.red)
                        .symbolSize(40)
                        .annotation(position: .top, alignment: .trailing, spacing: 4) {
                            Text("Full").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        }
                }
                if let hover {
                    RuleMark(x: .value("Date", hover.date))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Date", hover.date), y: .value("Free", Double(hover.free)))
                        .foregroundStyle(hover.isForecast ? Color.secondary : tint)
                        .symbolSize(40)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...(Double(top) * 1.15))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(ByteSize.format(Int64(bytes))) }
                    }
                }
            }
            .chartXSelection(value: $hoverDate)
            .overlay {
                if points.isEmpty {
                    Text("No data in this period").foregroundStyle(.secondary)
                }
            }
            .frame(height: 260)
            .padding(.top, 14)

            HStack(spacing: 16) {
                LegendItem(title: String(localized: "Free space"), color: tint, dashed: false)
                LegendItem(title: String(localized: "At the current rate"), color: .secondary, dashed: true)
                    .opacity(projection.isEmpty ? 0 : 1)
                Spacer()
                Text(range == .year ? "Lowest free space each day" : "Recorded hourly while Reclaim runs")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.top, 12)
        }
    }

    private func hoverInfo(projection: [DiskSample]) -> (date: Date, free: Int64, isForecast: Bool)? {
        guard let hoverDate else { return nil }
        if let last = points.last, let forecast, projection.count == 2, hoverDate > last.date, hoverDate > forecast.asOf {
            let date = min(hoverDate, projection[1].date)
            return (date, forecast.projectedFree(at: date), true)
        }
        guard let nearest = points.min(by: { abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate)) }) else {
            return nil
        }
        return (nearest.date, nearest.free, false)
    }

    private func format(_ date: Date) -> String {
        range == .year
            ? date.formatted(.dateTime.month(.abbreviated).day().year())
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

private struct LegendItem: View {
    let title: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
            .frame(width: 16, height: 2)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Changes

private struct ChangeRow: View {
    let change: DiskChange
    let showsTime: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: change.isGain ? "arrow.up.right" : "arrow.down.right", tint: change.isGain ? .green : .orange, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.isGain
                    ? String(localized: "Freed up \(ByteSize.format(change.delta))")
                    : String(localized: "\(ByteSize.format(-change.delta)) used"))
                Text(when)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("\(ByteSize.format(change.freeAfter)) free after")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var when: String {
        let day = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if change.end.timeIntervalSince(change.start) > 36 * 3_600 {
            return String(localized: "Between \(change.start.formatted(day)) and \(change.end.formatted(day))")
        }
        return showsTime ? change.end.formatted(day.hour().minute()) : change.end.formatted(day)
    }
}
