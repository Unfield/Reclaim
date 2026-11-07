import ReclaimCore
import SwiftUI

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Fixed colors for the memory breakdown, shared by the bar and its legend.
private enum MemorySegment: CaseIterable {
    case app, wired, compressed, cached

    var title: String {
        switch self {
        case .app: "App Memory"
        case .wired: "Wired"
        case .compressed: "Compressed"
        case .cached: "Cached Files"
        }
    }

    var color: Color {
        switch self {
        case .app: .blue
        case .wired: .orange
        case .compressed: .purple
        case .cached: .teal.opacity(0.55)
        }
    }

    var help: String {
        switch self {
        case .app: "Memory used by apps and their helper processes."
        case .wired: "Memory the system needs to keep in RAM at all times."
        case .compressed: "Memory macOS compressed to make room. Some compression is normal."
        case .cached: "Recently used files kept in RAM for speed. Given back instantly when apps need it."
        }
    }

    func value(in stats: MemoryStats) -> Int64 {
        switch self {
        case .app: stats.appMemory
        case .wired: stats.wired
        case .compressed: stats.compressed
        case .cached: stats.cachedFiles
        }
    }
}

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingPurge = false
    @State private var pendingQuit: (group: ProcessGroup, force: Bool)?

    var body: some View {
        let groups = Array(model.memoryGroups.prefix(15))
        let heaviest = groups.map(\.memory).max() ?? 1

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let stats = model.memory {
                    MemorySummary(stats: stats)
                } else {
                    Card { ProgressView().frame(maxWidth: .infinity, minHeight: 150) }
                }

                if let message = model.purgeMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Using the Most Memory", trailing: groups.isEmpty ? nil : "Your apps and processes")
                    Card(padding: 0) {
                        if groups.isEmpty {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(groups) { group in
                            ProcessRow(group: group, fraction: Double(group.memory) / Double(max(1, heaviest))) { force in
                                pendingQuit = (group, force)
                            }
                            if group.id != groups.last?.id { Divider().padding(.leading, 56) }
                        }
                    }
                }

                AboutMemoryNote()
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .bottomBar {
            if let stats = model.memory {
                Label("Memory pressure: \(stats.pressure.label)", systemImage: "circle.fill")
                    .labelStyle(PressureLabelStyle(color: stats.pressure.color))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ActivityIndicator(isActive: model.isPurging)
            Button("Clear Memory Caches…") { confirmingPurge = true }
                .secondaryButtonStyle()
                .disabled(model.isPurging)
        }
        .navigationTitle("Memory")
        .task {
            // Live updates while the screen is visible; stops automatically when you navigate away.
            while !Task.isCancelled {
                await model.refreshMemory()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Clear memory caches?", isPresented: $confirmingPurge) {
            Button("Clear Caches") { Task { await model.purgeMemory() } }
        } message: {
            Text("This drops cached files from memory (like `sudo purge`). macOS already does this automatically whenever apps need memory, so it rarely helps, and apps can feel slower for a moment while the cache refills.\n\nTo actually free memory, quit apps you aren't using. You'll be asked for an administrator password.")
        }
        .confirmationDialog(
            quitTitle,
            isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            presenting: pendingQuit
        ) { pending in
            Button(pending.force ? "Force Quit" : "Quit", role: pending.force ? .destructive : nil) {
                model.quit(pending.group, force: pending.force)
            }
        } message: { pending in
            Text(pending.force
                ? "Unsaved changes in \(pending.group.name) will be lost."
                : "Frees about \(ByteSize.formatMemory(pending.group.memory)). \(pending.group.name) may ask you to save changes.")
        }
    }

    private var quitTitle: String {
        guard let pending = pendingQuit else { return "" }
        return "\(pending.force ? "Force quit" : "Quit") \(pending.group.name)?"
    }
}

private struct PressureLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(color)
            configuration.title
        }
    }
}

// MARK: - Summary

private struct MemorySummary: View {
    let stats: MemoryStats

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .center, spacing: 28) {
                PressureRing(stats: stats)
                    .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Memory Pressure")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(stats.pressure.label)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(stats.pressure.color)
                    Text(stats.pressure.explanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if stats.swapUsed > 0 {
                        Text("Swap used: \(ByteSize.formatMemory(stats.swapUsed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(MemorySegment.allCases, id: \.self) { segment in
                        HStack(spacing: 8) {
                            Circle().fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.title)
                            Spacer(minLength: 8)
                            Text(ByteSize.formatMemory(segment.value(in: stats)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .help(segment.help)
                    }
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text("Free")
                        Spacer()
                        Text(ByteSize.formatMemory(stats.free)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .frame(width: 230)
            }

            MemoryBar(stats: stats)
                .frame(height: 10)
                .padding(.top, 18)
        }
    }
}

private struct PressureRing: View {
    let stats: MemoryStats

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: stats.usedFraction)
                .stroke(stats.pressure.color.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: stats.usedFraction)
            VStack(spacing: 2) {
                Text(ByteSize.formatMemory(stats.used))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(ByteSize.formatMemory(stats.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Memory used by apps, the system and compression. Cached files aren't counted.")
    }
}

private struct MemoryBar: View {
    let stats: MemoryStats

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(MemorySegment.allCases, id: \.self) { segment in
                    let width = geometry.size.width * Double(segment.value(in: stats)) / Double(max(1, stats.total))
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, width))
                        .help("\(segment.title): \(ByteSize.formatMemory(segment.value(in: stats)))")
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
            .animation(.smooth, value: stats)
        }
    }
}

// MARK: - Rows

private struct ProcessRow: View {
    @Environment(AppModel.self) private var model
    let group: ProcessGroup
    let fraction: Double
    let onQuit: (_ force: Bool) -> Void

    var body: some View {
        let canQuit = model.canQuit(group)

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Capsule()
                .fill(.quaternary)
                .frame(width: 120, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint).frame(width: max(3, 120 * fraction), height: 6)
                }

            Text(ByteSize.formatMemory(group.memory))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)

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

private struct AboutMemoryNote: View {
    var body: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About “RAM cleaning”").fontWeight(.medium)
                    Text("macOS deliberately keeps memory full: unused RAM is used to cache files so your Mac stays fast, and that cache is given back instantly when an app needs it. So high memory use isn't a problem. Memory pressure is the number that matters. If it's elevated, quitting apps you don't need is the only thing that really helps, and that's what the list above is for.")
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
