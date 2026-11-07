import ReclaimCore
import SwiftUI

/// Everything Reclaim moved to the Trash that's still there, with Put Back.
struct RecentlyRemovedView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = Set<UUID>()
    @State private var working: UUID?

    var body: some View {
        Group {
            if model.trashHistory.isEmpty {
                ContentUnavailableView(
                    "Nothing to Put Back",
                    systemImage: "arrow.uturn.backward.circle",
                    description: Text("Items Reclaim moves to the Trash show up here until you empty the Trash.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.trashHistory) { batch in
                            BatchCard(
                                batch: batch,
                                isExpanded: expanded.contains(batch.id),
                                isWorking: working == batch.id,
                                toggle: { toggle(batch.id) },
                                putBack: { putBack(batch.id) }
                            )
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .bottomBar {
            Text("Emptying the Trash removes items from this list for good.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Empty Trash…") { NSWorkspace.shared.open(URL(filePath: NSHomeDirectory()).appending(path: ".Trash")) }
                .secondaryButtonStyle()
        }
        .navigationTitle("Recently Removed")
        .onAppear { model.refreshTrashHistory() }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func putBack(_ id: UUID) {
        working = id
        Task {
            await model.putBack(id)
            working = nil
        }
    }
}

private struct BatchCard: View {
    let batch: TrashBatch
    let isExpanded: Bool
    let isWorking: Bool
    let toggle: () -> Void
    let putBack: () -> Void

    var body: some View {
        Card(padding: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                IconTile(systemName: "trash", tint: .secondary, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batch.title).fontWeight(.medium).lineLimit(1)
                    Text("\(batch.date.formatted(date: .abbreviated, time: .shortened)) · \(batch.records.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SizeText(bytes: batch.totalSize).foregroundStyle(.secondary)
                ActivityIndicator(isActive: isWorking)
                Button("Put Back", action: putBack)
                    .disabled(isWorking)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(batch.records.prefix(200)) { record in
                        HStack {
                            Text(record.original.abbreviatedPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            SizeText(bytes: record.size).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if batch.records.count > 200 {
                        Text("…and \(batch.records.count - 200) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}
