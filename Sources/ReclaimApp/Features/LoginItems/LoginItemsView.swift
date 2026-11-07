import AppKit
import ReclaimCore
import SwiftUI

extension LaunchItemStatus {
    var color: Color {
        switch self {
        case .on: .green
        case .off: .secondary
        case .broken: .orange
        }
    }

    var help: String {
        switch self {
        case .on: "Starts automatically."
        case .off: "Turned off. It won't start automatically."
        case .broken: "Its program is missing, so it can't start."
        }
    }
}

private enum PendingAction {
    case disable(LaunchItem)
    case remove(LaunchItem)

    var item: LaunchItem {
        switch self {
        case .disable(let item), .remove(let item): item
        }
    }
}

struct LoginItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingAction?

    var body: some View {
        let loginItems = model.loginItems

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let message = loginItems.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                OpenAtLoginCard()

                ForEach(LaunchItemDomain.allCases, id: \.self) { domain in
                    let items = loginItems.items(in: domain)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: domain.title, trailing: loginItems.hasLoaded ? countText(items.count) : nil)
                        Text(domain.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        Card(padding: 0) {
                            if !loginItems.hasLoaded {
                                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                            } else if items.isEmpty {
                                Text("Nothing here.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            ForEach(items) { item in
                                LaunchItemRow(
                                    item: item,
                                    isBusy: loginItems.busy.contains(item.id),
                                    onToggle: { enabled in
                                        if enabled {
                                            Task { await loginItems.setEnabled(item, true) }
                                        } else {
                                            pending = .disable(item)
                                        }
                                    },
                                    onRemove: { pending = .remove(item) }
                                )
                                if item.id != items.last?.id { Divider().padding(.leading, 56) }
                            }
                        }
                    }
                }

                AboutLoginItemsNote()
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .bottomBar {
            if loginItems.hasLoaded {
                Text(summary(loginItems))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            ActivityIndicator(isActive: loginItems.isLoading)
            Button("Refresh") { Task { await loginItems.load() } }
                .secondaryButtonStyle()
                .disabled(loginItems.isLoading)
        }
        .navigationTitle("Login Items")
        .task { await loginItems.load() }
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            switch action {
            case .disable(let item):
                Button("Turn Off") { Task { await loginItems.setEnabled(item, false) } }
            case .remove(let item):
                Button("Move to Trash", role: .destructive) {
                    Task {
                        if let record = await loginItems.remove(item) {
                            model.recordTrash(title: "Removed login item \(item.displayName)", records: [record])
                        }
                    }
                }
            }
        } message: { action in
            Text(pendingMessage(action))
        }
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    private func summary(_ loginItems: LoginItemsModel) -> String {
        let total = countText(loginItems.items.count)
        let broken = loginItems.brokenCount
        return broken > 0 ? "\(total) · \(broken) broken" : total
    }

    private var pendingTitle: String {
        switch pending {
        case .disable(let item): "Turn off \(item.displayName)?"
        case .remove(let item): "Remove \(item.displayName)?"
        case nil: ""
        }
    }

    private func pendingMessage(_ action: PendingAction) -> String {
        let password = action.item.domain.requiresAdministrator ? " You'll be asked for your password." : ""
        switch action {
        case .disable(let item):
            let app = item.appName ?? "Its app"
            return "It stops now and won't start automatically until you turn it back on. \(app) may lose features like automatic updates or syncing.\(password)"
        case .remove(let item):
            let undo = item.domain.requiresAdministrator ? "" : " You can put it back from Recently Removed."
            return "Its program is missing, so it can't run anyway. Its launch file moves to the Trash.\(undo)\(password)"
        }
    }
}

// MARK: - Rows

private struct LaunchItemRow: View {
    let item: LaunchItem
    let isBusy: Bool
    let onToggle: @MainActor (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.displayName).lineLimit(1)
                    if item.appName != nil {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(when)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let problem = item.problem {
                    Text("\(problem): \(item.program ?? item.plistURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(item.command)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.command)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusBadge(status: item.status)
                .frame(width: 64)

            ZStack(alignment: .trailing) {
                if isBusy {
                    ActivityIndicator(isActive: true)
                } else if item.isBroken {
                    Button("Remove…", action: onRemove)
                        .controlSize(.small)
                } else {
                    Toggle("On", isOn: Binding(get: { item.status == .on }, set: { onToggle($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help(item.status == .on ? "Turn off" : "Turn on")
                }
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Show Launch File in Finder") { AppModel.revealInFinder(item.plistURL) }
            if let program = item.program, item.programState == .present, program.hasPrefix("/") {
                Button("Show Program in Finder") { AppModel.revealInFinder(URL(filePath: program)) }
            }
            if let app = item.appURL {
                Button("Show \(item.appName ?? "App") in Finder") { AppModel.revealInFinder(app) }
            }
            Divider()
            Button("Copy Label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if item.isBroken {
            IconTile(systemName: "exclamationmark.triangle", tint: .orange, size: 28)
        } else if let app = item.appURL {
            FileIcon(url: app, size: 28)
        } else {
            IconTile(systemName: symbol, tint: .secondary, size: 28)
        }
    }

    private var symbol: String {
        switch item.domain {
        case .userAgent: "person.crop.circle"
        case .systemAgent: "person.2"
        case .systemDaemon: "gearshape.2"
        }
    }

    private var when: String {
        var parts = [item.schedule.summary(for: item.domain)]
        // "Always running" already says it keeps itself running.
        if let detail = item.schedule.detail, item.schedule.keepAlive != .always { parts.append(detail) }
        if item.isRunning { parts.append("Running now") }
        return parts.joined(separator: " · ")
    }
}

private struct StatusBadge: View {
    let status: LaunchItemStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.14), in: Capsule())
            .help(status.help)
    }
}

// MARK: - Notes

private struct OpenAtLoginCard: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(systemName: "power", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps that open at login").fontWeight(.medium)
                    Text("Apps you've set to open at login, and app helpers allowed in the background, are managed in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

private struct AboutLoginItemsNote: View {
    var body: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Is it safe to turn these off?").fontWeight(.medium)
                    Text("Yes. Turning an item off stops it and keeps it from starting again, and you can turn it back on any time. Some apps need their helper for things like automatic updates, syncing or VPN connections, so turn it back on if an app stops working. Broken items point to a program that no longer exists, usually left behind by an app you deleted. They can't run, so removing them is safe. macOS's own items aren't shown.")
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
