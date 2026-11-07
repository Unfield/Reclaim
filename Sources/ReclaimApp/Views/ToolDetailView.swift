import ReclaimCore
import SwiftUI

struct ToolDetailView: View {
    @Environment(AppModel.self) private var model
    let tool: any MaintenanceTool
    @State private var confirming = false
    @State private var snapshotToDelete: ToolEntry?

    private var isTimeMachine: Bool { tool.id == "time-machine" }

    var body: some View {
        let state = model.toolState(tool.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(
                    title: tool.name,
                    symbol: ToolSymbols.name(for: tool.id),
                    tint: ChartPalette.color(for: tool.id),
                    safety: tool.safety,
                    summary: tool.summary,
                    size: model.toolReclaimable(tool.id)
                )

                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                content(state)
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .bottomBar {
            Button {
                Task { await model.refreshTool(tool.id) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .secondaryButtonStyle()
            .disabled(state.isLoading || state.isCleaning)
            Spacer()
            ActivityIndicator(isActive: state.isCleaning || state.isLoading)
            Button(isTimeMachine ? "Delete All Snapshots…" : "Clean Up…") { confirming = true }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(state.status?.isReady != true || state.status?.entries.isEmpty == true || state.isCleaning || model.isCleaning)
        }
        .navigationTitle(tool.name)
        .task {
            if state.status == nil { await model.refreshTool(tool.id) }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(isTimeMachine ? "Delete Snapshots" : "Clean Up", role: .destructive) {
                Task { await model.cleanTool(tool.id) }
            }
        } message: {
            Text(confirmMessage)
        }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: Binding(get: { snapshotToDelete != nil }, set: { if !$0 { snapshotToDelete = nil } }),
            presenting: snapshotToDelete
        ) { entry in
            Button("Delete Snapshot", role: .destructive) {
                if let name = entry.detail { Task { await model.deleteSnapshot(named: name) } }
            }
        } message: { entry in
            Text("The local snapshot from \(entry.title) will be removed. Backups on your Time Machine disk aren't affected.")
        }
    }

    @ViewBuilder
    private func content(_ state: ToolState) -> some View {
        switch state.status?.availability {
        case nil:
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(tool.name)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
        case .notInstalled:
            ContentUnavailableView("\(tool.name) Isn't Installed", systemImage: ToolSymbols.name(for: tool.id))
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("\(tool.name) Isn't Available", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("Try Again") { Task { await model.refreshTool(tool.id) } }
            }
        case .ready:
            if let status = state.status { readyContent(status, state: state) }
        }
    }

    @ViewBuilder
    private func readyContent(_ status: ToolStatus, state: ToolState) -> some View {
        if !tool.options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: String(localized: "Options"))
                Card(padding: 0) {
                    ForEach(tool.options) { option in
                        Toggle(isOn: Binding(
                            get: { model.toolState(tool.id).options.contains(option.id) },
                            set: { model.setOption(option.id, enabled: $0, toolID: tool.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(option.title).fontWeight(.medium)
                                    SafetyBadge(level: option.safety)
                                }
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        if option.id != tool.options.last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: isTimeMachine ? String(localized: "Local Snapshots") : String(localized: "What Will Be Removed"))
            Card(padding: 0) {
                if status.entries.isEmpty {
                    Text(isTimeMachine ? "No local snapshots." : "Nothing to clean up.")
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                ForEach(status.entries) { entry in
                    let included = entry.optionID.map(state.options.contains) ?? true
                    HStack(spacing: 12) {
                        Image(systemName: included ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(included ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if let size = entry.size {
                            SizeText(bytes: size).foregroundStyle(included ? .primary : .secondary)
                        }
                        if isTimeMachine {
                            Button("Delete…") { snapshotToDelete = entry }
                                .controlSize(.small)
                                .disabled(state.isCleaning)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .help(included ? "" : "Turn on the matching option to include this.")
                    if entry.id != status.entries.last?.id { Divider().padding(.leading, 44) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let note = status.note { Text(note) }
                if isTimeMachine, let volume = model.volume {
                    Text("Purgeable space on \(volume.name): \(ByteSize.format(volume.purgeableCapacity))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var confirmTitle: String {
        if isTimeMachine { return String(localized: "Delete all local Time Machine snapshots?") }
        return String(localized: "Clean up \(model.toolReclaimable(tool.id).map(ByteSize.format) ?? tool.name)?")
    }

    private var confirmMessage: String {
        if isTimeMachine {
            return String(localized: "Backups on your Time Machine disk aren't affected. You may be asked for an administrator password.")
        }
        let enabled = tool.options.filter { model.toolState(tool.id).options.contains($0.id) }.map(\.title)
        let message = String(localized: "This runs \(tool.name)'s own cleanup and can't be undone.")
        guard !enabled.isEmpty else { return message }
        return message + "\n" + String(localized: "Including: \(enabled.joined(separator: ", ")).")
    }
}
