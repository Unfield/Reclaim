import AppKit
import ReclaimCore
import SwiftUI

extension ProjectEcosystem {
    fileprivate var symbolName: String {
        switch self {
        case .javaScript: "curlybraces"
        case .rust: "gearshape.2"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .swift: "swift"
        case .gradle: "cup.and.saucer"
        case .cocoaPods: "shippingbox"
        case .dart: "diamond"
        case .zig: "bolt"
        case .elixir: "drop"
        case .terraform: "square.stack.3d.up"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .javaScript: .yellow
        case .rust: .brown
        case .python: .blue
        case .swift: .orange
        case .gradle: .green
        case .cocoaPods: .red
        case .dart: .cyan
        case .zig: .pink
        case .elixir: .purple
        case .terraform: .indigo
        }
    }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var tableSelection = Set<URL>()
    @State private var pendingTrash: [ProjectJunk]?

    private static let dayOptions: [(days: Int, label: String)] = [
        (30, String(localized: "30 days")), (90, String(localized: "90 days")),
        (180, String(localized: "6 months")), (365, String(localized: "1 year")),
    ]

    var body: some View {
        @Bindable var projects = model.projects
        let visible = projects.visibleItems
        let chosen = projects.chosenItems

        content(visible)
            .topBar {
                HStack(spacing: 10) {
                    Picker("Show", selection: $projects.filter) {
                        ForEach(ProjectsModel.Filter.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    Picker("Untouched for", selection: $projects.inactiveDays) {
                        ForEach(Self.dayOptions, id: \.days) { Text($0.label).tag($0.days) }
                    }
                    .fixedSize()
                    .opacity(projects.filter == .inactive ? 1 : 0)
                    .disabled(projects.filter != .inactive)

                    Spacer()

                    foldersMenu

                    Button {
                        projects.scan()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Scan again")
                    .disabled(projects.isCleaning)
                }
            }
            .bottomBar {
                Menu("Select") {
                    Button("Select All") { projects.setChecked(true, visible.map(\.url)) }
                    Button("Select Inactive") { projects.preselectInactive() }
                    Button("Select None") { projects.checked.removeAll() }
                }
                .fixedSize()
                .disabled(visible.isEmpty)
                Spacer()
                ActivityIndicator(isActive: projects.isScanning || projects.isCleaning)
                Text(status(visible: visible, chosen: chosen))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Move to Trash…") { pendingTrash = chosen }
                    .primaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || projects.isCleaning)
            }
            .navigationTitle("Developer Projects")
            .task {
                if !projects.hasScanned { projects.scan() }
            }
            .confirmationDialog(
                trashTitle,
                isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                presenting: pendingTrash
            ) { items in
                Button("Move to Trash", role: .destructive) {
                    Task { await projects.trash(items, appModel: model) }
                }
            } message: { items in
                Text(trashMessage(items))
            }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ visible: [ProjectJunk]) -> some View {
        let projects = model.projects
        if projects.hasScanned && projects.roots.isEmpty {
            ContentUnavailableView {
                Label("No Code Folders", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Add the folder where you keep your projects. Reclaim looks inside for dependency and build folders you can rebuild anytime.")
            } actions: {
                Button("Add Folder…", action: addFolder)
                    .primaryButtonStyle()
            }
        } else if !visible.isEmpty {
            table(visible)
        } else if projects.isScanning || !projects.hasScanned {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for projects…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !projects.roots.contains(where: ProjectsModel.isAvailable) {
            ContentUnavailableView {
                Label("Folders Not Available", systemImage: "externaldrive.badge.xmark")
            } description: {
                Text("Connect the disk with your projects, then scan again.")
            } actions: {
                Button("Scan Again") { projects.scan() }
            }
        } else if projects.filter == .inactive && !projects.items.isEmpty {
            ContentUnavailableView {
                Label("No Inactive Projects", systemImage: "checkmark.circle")
            } description: {
                Text("Every project with build folders changed \(periodDescription(projects.inactiveDays)).")
            } actions: {
                Button("Show All Projects") { projects.filter = .all }
            }
        } else {
            ContentUnavailableView(
                "Nothing to Clean",
                systemImage: "checkmark.circle",
                description: Text("No dependency or build folders found in your code folders.")
            )
        }
    }

    private func table(_ visible: [ProjectJunk]) -> some View {
        @Bindable var projects = model.projects

        return Table(visible, selection: $tableSelection, sortOrder: $projects.sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: Binding(
                    get: { projects.isChecked(item) },
                    set: { projects.setChecked($0, [item.url]) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            .width(22)

            TableColumn("Project", value: \.projectName) { item in
                HStack(spacing: 8) {
                    IconTile(systemName: item.kind.ecosystem.symbolName, tint: item.kind.ecosystem.tint, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.projectName).lineLimit(1)
                        Text(item.project.abbreviatedPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(item.project.abbreviatedPath)
            }

            TableColumn("Folder", value: \.kind.name) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.kind.name).lineLimit(1)
                        if item.kind.safety != .safe { SafetyBadge(level: item.kind.safety) }
                    }
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(item.kind.ecosystem.name) · Rebuild with “\(item.rebuildHint)”")
            }
            .width(min: 150, ideal: 200)

            TableColumn("Last Active", value: \.sortLastActive) { item in
                Text(item.lastActive?.shortDate ?? "—")
                    .foregroundStyle(.secondary)
                    .help(item.lastActive.map { String(localized: "Changed \($0.formatted(.relative(presentation: .named)))") } ?? "")
            }
            .width(110)

            TableColumn("Size", value: \.sortSize) { item in
                ZStack(alignment: .trailing) {
                    ActivityIndicator(isActive: item.size == nil).controlSize(.mini)
                    if let size = item.size { SizeText(bytes: size) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            let selected = visible.filter { urls.contains($0.url) }
            let projectURLs = Set(selected.map(\.project))
            if !selected.isEmpty {
                Button("Reveal in Finder") { selected.forEach { AppModel.revealInFinder($0.url) } }
                if selected.count == 1, let item = selected.first {
                    Button("Copy “\(item.rebuildHint)”") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.rebuildHint, forType: .string)
                    }
                }
                Divider()
                Button("Check Selected") { projects.setChecked(true, urls) }
                Button("Uncheck Selected") { projects.setChecked(false, urls) }
                Divider()
                Button(projectURLs.count == 1 ? "Never Clean This Project" : "Never Clean These Projects") {
                    projects.neverClean(projects: projectURLs)
                }
                Button("Move to Trash…") { pendingTrash = selected }
            }
        } primaryAction: { urls in
            urls.forEach(AppModel.revealInFinder)
        }
    }

    private var foldersMenu: some View {
        let projects = model.projects
        let roots = projects.roots
        let title = roots.isEmpty ? String(localized: "Choose Folders") : roots.count == 1 ? roots[0].lastPathComponent : String(localized: "\(roots.count) Folders")

        return Menu {
            if !roots.isEmpty {
                Section("Searching") {
                    ForEach(roots, id: \.self) { root in
                        Menu {
                            Button("Show in Finder") { AppModel.revealInFinder(root) }
                            Button("Remove") { projects.removeRoot(root) }
                        } label: {
                            Label(
                                ProjectsModel.isAvailable(root) ? root.abbreviatedPath : String(localized: "\(root.abbreviatedPath) (not connected)"),
                                systemImage: VolumeInfo.volume(containing: root, in: model.volumes)?.symbolName ?? "folder"
                            )
                        }
                    }
                }
                Divider()
            }
            Button("Add Folder…", action: addFolder)
            if projects.hasHiddenDefaults {
                Button("Restore Default Folders") { projects.restoreDefaultRoots() }
            }
        } label: {
            Label(title, systemImage: "folder")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Folders searched for code projects")
    }

    // MARK: Helpers

    private func addFolder() {
        let start = model.projects.roots.first ?? FileManager.default.homeDirectoryForCurrentUser
        if let url = AppModel.chooseFolder(startingAt: start) {
            model.projects.addRoot(url)
        }
    }

    private func periodDescription(_ days: Int) -> String {
        switch days {
        case 365: String(localized: "in the last year")
        case 180: String(localized: "in the last 6 months")
        default: String(localized: "in the last \(days) days")
        }
    }

    private func status(visible: [ProjectJunk], chosen: [ProjectJunk]) -> String {
        if visible.isEmpty { return model.projects.isScanning ? String(localized: "Looking for projects…") : "" }
        let size = chosen.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return String(localized: "\(chosen.count) of \(visible.count) selected · \(ByteSize.format(size))")
    }

    private var trashTitle: String {
        guard let items = pendingTrash else { return "" }
        if items.count == 1, let item = items.first { return String(localized: "Move \(item.name) from \(item.projectName) to the Trash?") }
        return String(localized: "Move \(items.count) folders to the Trash?")
    }

    private func trashMessage(_ items: [ProjectJunk]) -> String {
        let size = ByteSize.format(items.reduce(0) { $0 + ($1.size ?? 0) })
        let amount = items.contains { $0.size == nil } ? String(localized: "At least \(size)") : size
        let projectCount = Set(items.map(\.project)).count
        if items.count == 1, let item = items.first {
            return String(localized: "\(amount). Rebuild it anytime with “\(item.rebuildHint)”. You can also put it back from Recently Removed.")
        }
        let from = projectCount == 1
            ? String(localized: "\(amount) from 1 project.")
            : String(localized: "\(amount) from \(projectCount) projects.")
        return from + " " + String(localized: "Each project can rebuild them with its usual install or build command. You can also put them back from Recently Removed.")
    }
}
