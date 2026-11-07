import AppKit
import ReclaimCore
import SwiftUI

extension ThermalLevel {
    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }
}

private extension CPULoad {
    var tint: Color { total > 0.85 ? .red : total > 0.6 ? .orange : .green }
}

/// Fixed colors for the CPU breakdown, shared by the bar and its legend.
private enum CPUSegment: CaseIterable {
    case user, system

    var title: String {
        switch self {
        case .user: "User"
        case .system: "System"
        }
    }

    var color: Color {
        switch self {
        case .user: .blue
        case .system: .orange
        }
    }

    var help: String {
        switch self {
        case .user: "Time spent running apps and their helpers."
        case .system: "Time spent in macOS itself, for example handling files, graphics and networking."
        }
    }

    func value(in load: CPULoad) -> Double {
        switch self {
        case .user: load.user
        case .system: load.system
        }
    }
}

private func percentText(_ value: Double) -> String { CPUMonitor.formatPercent(value) }
private func powerText(_ watts: Double) -> String { CPUMonitor.formatPower(watts) }

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingQuit: (group: CPUProcessGroup, force: Bool)?

    var body: some View {
        let activity = model.activity
        let groups = Array(activity.groups.prefix(15))
        let scale = max(100, groups.map(\.cpu).max() ?? 0)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let load = activity.load {
                    CPUSummary(load: load, thermal: activity.thermal, isLowPowerMode: activity.isLowPowerMode, info: activity.info)
                } else {
                    Card { ProgressView().frame(maxWidth: .infinity, minHeight: 150) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Using the Most CPU", trailing: groups.isEmpty ? nil : "100% = one full core")
                    Card(padding: 0) {
                        if groups.isEmpty {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(groups) { group in
                            CPUProcessRow(
                                group: group,
                                fraction: group.cpu / scale,
                                history: activity.history[group.id] ?? [],
                                showsPower: activity.hasEnergyData
                            ) { force in
                                pendingQuit = (group, force)
                            }
                            if group.id != groups.last?.id { Divider().padding(.leading, 56) }
                        }
                    }
                }

                AboutCPUNote(coreCount: activity.info.coreCount)
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .bottomBar {
            Label("Temperature: \(activity.thermal.label)", systemImage: "circle.fill")
                .labelStyle(StatusDotLabelStyle(color: activity.thermal.color))
                .foregroundStyle(.secondary)
                .help(activity.thermal.explanation)
            if activity.isLowPowerMode {
                Label("Low Power Mode", systemImage: "battery.25percent")
                    .foregroundStyle(.secondary)
                    .help("Your Mac trades some speed for longer battery life.")
            }
            Spacer()
            Button("Open Activity Monitor") { openActivityMonitor() }
                .secondaryButtonStyle()
        }
        .navigationTitle("CPU & Energy")
        .task {
            // Live updates while the screen is visible; stops automatically when you navigate away.
            while !Task.isCancelled {
                await activity.refresh()
                try? await Task.sleep(for: ActivityModel.refreshInterval)
            }
        }
        .confirmationDialog(
            quitTitle,
            isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            presenting: pendingQuit
        ) { pending in
            Button(pending.force ? "Force Quit" : "Quit", role: pending.force ? .destructive : nil) {
                model.quit(pending.group.processGroup, force: pending.force)
            }
        } message: { pending in
            Text(pending.force
                ? "Unsaved changes in \(pending.group.name) will be lost."
                : "\(pending.group.name) is using \(percentText(pending.group.cpu)) CPU right now. It may ask you to save changes.")
        }
    }

    private var quitTitle: String {
        guard let pending = pendingQuit else { return "" }
        return "\(pending.force ? "Force quit" : "Quit") \(pending.group.name)?"
    }

    private func openActivityMonitor() {
        let url = URL(filePath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct StatusDotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(color)
            configuration.title
        }
    }
}

// MARK: - Summary

private struct CPUSummary: View {
    let load: CPULoad
    let thermal: ThermalLevel
    let isLowPowerMode: Bool
    let info: CPUInfo

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 28) {
                CPURing(load: load)
                    .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(thermal.label)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(thermal.color)
                    Text(thermal.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLowPowerMode {
                        Text("Low Power Mode is on, so your Mac trades some speed for battery life.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CPUSegment.allCases, id: \.self) { segment in
                        HStack(spacing: 8) {
                            Circle().fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.title)
                            Spacer(minLength: 8)
                            Text(percentText(segment.value(in: load) * 100))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .font(.callout)
                        .help(segment.help)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(.quaternary).frame(width: 8, height: 8)
                        Text("Idle")
                        Spacer(minLength: 8)
                        Text(percentText(load.idle * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .font(.callout)
                    .help("Capacity that's free right now.")
                    Divider().padding(.vertical, 2)
                    coreRow("Cores", "\(info.coreCount)")
                        .help(info.summary)
                    if let performance = info.performanceCores, let efficiency = info.efficiencyCores, performance > 0, efficiency > 0 {
                        coreRow("Performance / Efficiency", "\(performance) / \(efficiency)")
                            .help("Fast cores for demanding work, and power-saving cores for background tasks.")
                    }
                }
                .frame(width: 230)
            }

            CPUBar(load: load)
                .frame(height: 10)
                .padding(.top, 18)
        }
    }

    private func coreRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct CPURing: View {
    let load: CPULoad

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: load.total)
                .stroke(load.tint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: load.total)
            VStack(spacing: 2) {
                Text(percentText(load.total * 100))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("CPU in use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("How busy all cores are together, averaged over the last couple of seconds.")
    }
}

private struct CPUBar: View {
    let load: CPULoad

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(CPUSegment.allCases, id: \.self) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * segment.value(in: load)))
                        .help("\(segment.title): \(percentText(segment.value(in: load) * 100))")
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
            .animation(.smooth, value: load)
        }
    }
}

// MARK: - Rows

private struct CPUProcessRow: View {
    @Environment(AppModel.self) private var model
    let group: CPUProcessGroup
    let fraction: Double
    let history: [Double]
    let showsPower: Bool
    let onQuit: (_ force: Bool) -> Void

    var body: some View {
        let processGroup = group.processGroup
        let canQuit = model.canQuit(processGroup)

        HStack(spacing: 12) {
            Group {
                if let bundle = group.bundleURL {
                    FileIcon(url: bundle, size: 28)
                } else {
                    IconTile(systemName: group.isSystem ? "gearshape" : "terminal", tint: .secondary, size: 28)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Sparkline(values: history)
                .frame(width: 64, height: 20)
                .help("CPU use over the last minute")

            Capsule()
                .fill(.quaternary)
                .frame(width: 100, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint).frame(width: max(3, 100 * min(1, fraction)), height: 6)
                        .animation(.smooth, value: fraction)
                }

            Text(percentText(group.cpu))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)

            if showsPower {
                Text(powerText(group.power ?? 0))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                    .help("Estimated power use. Lower means longer battery life.")
            }

            Button("Quit") { onQuit(false) }
                .controlSize(.small)
                .opacity(canQuit ? 1 : 0)
                .disabled(!canQuit)
                .frame(width: 56)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contextMenu {
            if canQuit {
                Button("Quit \(group.name)") { onQuit(false) }
                Button("Force Quit \(group.name)") { onQuit(true) }
            }
            if let bundle = group.bundleURL {
                Divider()
                Button("Reveal in Finder") { AppModel.revealInFinder(bundle) }
            }
        }
    }

    private var subtitle: String {
        var parts = [String]()
        if group.processCount > 1 { parts.append("\(group.processCount) processes") }
        if group.isSystem { parts.append("Part of macOS") }
        return parts.isEmpty ? (group.bundleURL == nil ? group.id : "App") : parts.joined(separator: " · ")
    }
}

/// A tiny line chart of recent CPU use. New samples enter from the right; the scale is at least 10%
/// so idle apps draw a flat line instead of magnifying noise.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = max(10, values.max() ?? 0)
            let height = size.height - 2
            let step = size.width / CGFloat(ActivityModel.historyLength - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + step * CGFloat(index), y: 1 + height - height * CGFloat(min(value, peak) / peak))
            }

            var line = Path()
            line.addLines(points)
            var area = line
            if let first = points.first, let last = points.last {
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
            }
            context.fill(area, with: .color(.accentColor.opacity(0.15)))
            context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct AboutCPUNote: View {
    let coreCount: Int

    var body: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's normal?").fontWeight(.medium)
                    Text("Most apps sit near 0% when you aren't using them, and that's fine: idle apps don't slow your Mac down or drain the battery, so there's no need to quit them. Short bursts are normal too, for example while a page loads or Spotlight indexes new files. Look for apps that stay high while you aren't using them. Those make your Mac warm and drain the battery. 100% means one core is fully busy, so with \(coreCount) cores an app can go up to \(coreCount * 100)%.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
        }
    }
}
