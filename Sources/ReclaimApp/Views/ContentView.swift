import ReclaimCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            detail
        }
        // One stable toolbar for every screen, so the glass doesn't reshape when navigating.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan everything (⌘R)")
                .disabled(model.isScanning || model.isCleaning)
            }
        }
        .alert(
            reportTitle,
            isPresented: Binding(get: { model.lastReport != nil }, set: { if !$0 { model.lastReport = nil } }),
            presenting: model.lastReport
        ) { report in
            if let batchID = report.undoBatchID {
                Button("Undo") { Task { await model.putBack(batchID) } }
            }
            if report.trashed > 0 {
                Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
            }
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(reportMessage(report))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .category(let id):
            if let scan = model.scan(for: id) {
                CategoryDetailView(scan: scan)
            } else {
                ContentUnavailableView("Nothing Here", systemImage: "folder")
            }
        case .tool(let id):
            if let tool = model.tool(id) {
                ToolDetailView(tool: tool)
            }
        case .apps:
            AppsView()
        case .explorer:
            ExplorerView()
        case .largeFiles:
            LargeFilesView()
        case .memory:
            MemoryView()
        case .projects:
            ProjectsView()
        case .orphans:
            OrphansView()
        case .duplicates:
            DuplicatesView()
        case .aiModels:
            AIModelsView()
        case .icloud:
            ICloudView()
        case .activity:
            ActivityView()
        case .loginItems:
            LoginItemsView()
        case .history:
            HistoryView()
        case .recentlyRemoved:
            RecentlyRemovedView()
        case .overview, nil:
            OverviewView()
        }
    }

    private var reportTitle: String {
        guard let report = model.lastReport else { return "" }
        return report.total > 0 ? String(localized: "Cleaned up \(ByteSize.format(report.total))") : String(localized: "Cleanup finished")
    }

    private func reportMessage(_ report: CleanupSummary) -> String {
        var lines = [String]()
        if report.freed > 0 { lines.append(String(localized: "\(ByteSize.format(report.freed)) freed.")) }
        if report.trashed > 0 { lines.append(String(localized: "\(ByteSize.format(report.trashed)) moved to the Trash. Empty it to free that space.")) }
        if !report.failures.isEmpty {
            lines.append("\n" + String(localized: "\(report.failures.count) items couldn't be removed:"))
            lines += report.failures.prefix(5).map { "• \($0)" }
            if report.failures.count > 5 { lines.append(String(localized: "…and \(report.failures.count - 5) more")) }
        }
        return lines.joined(separator: "\n")
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Collapsed sidebar sections, remembered across launches.
    @AppStorage("collapsedSidebarSections") private var collapsedStorage = ""

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                .badge(badge(model.totalReclaimable))
                .tag(SidebarItem.overview)
            Label("Recently Removed", systemImage: "arrow.uturn.backward.circle")
                .badge(model.trashHistory.isEmpty ? nil : Text("\(model.trashHistory.count)"))
                .tag(SidebarItem.recentlyRemoved)

            ForEach(CategoryGroup.allCases, id: \.self) { group in
                let scans = model.scans.filter { $0.category.group == group }
                if !scans.isEmpty {
                    Section(isExpanded: expanded(group.rawValue)) {
                        ForEach(scans) { scan in
                            Label(scan.category.name, systemImage: scan.category.symbolName)
                                .badge(badge(scan.totalSize))
                                .tag(SidebarItem.category(scan.id))
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }

            if !model.visibleTools.isEmpty {
                Section(isExpanded: expanded("Maintenance")) {
                    ForEach(model.visibleTools, id: \.id) { tool in
                        Label(tool.name, systemImage: ToolSymbols.name(for: tool.id))
                            .badge(badge(model.toolReclaimable(tool.id)))
                            .tag(SidebarItem.tool(tool.id))
                    }
                } header: {
                    Text("Maintenance")
                }
            }

            Section(isExpanded: expanded("Find & Remove")) {
                Label("Applications", systemImage: "square.grid.2x2").tag(SidebarItem.apps)
                Label("App Leftovers", systemImage: "questionmark.folder").tag(SidebarItem.orphans)
                Label("Developer Projects", systemImage: "hammer").tag(SidebarItem.projects)
                Label("Duplicates", systemImage: "doc.on.doc").tag(SidebarItem.duplicates)
                Label("AI Models", systemImage: "brain").tag(SidebarItem.aiModels)
                Label("iCloud Drive", systemImage: "icloud").tag(SidebarItem.icloud)
                Label("Large Files", systemImage: "doc.text.magnifyingglass").tag(SidebarItem.largeFiles)
                Label("Space Explorer", systemImage: "chart.bar.doc.horizontal").tag(SidebarItem.explorer)
            } header: {
                Text("Find & Remove")
            }

            Section(isExpanded: expanded("Monitor")) {
                Label("Memory", systemImage: "memorychip").tag(SidebarItem.memory)
                Label("CPU & Energy", systemImage: "cpu").tag(SidebarItem.activity)
                Label("Login Items", systemImage: "power").tag(SidebarItem.loginItems)
                Label("Disk History", systemImage: "chart.xyaxis.line").tag(SidebarItem.history)
            } header: {
                Text("Monitor")
            }
        }
    }

    private func expanded(_ section: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedStorage.split(separator: "|").contains(Substring(section)) },
            set: { isExpanded in
                var collapsed = Set(collapsedStorage.split(separator: "|").map(String.init))
                if isExpanded { collapsed.remove(section) } else { collapsed.insert(section) }
                collapsedStorage = collapsed.sorted().joined(separator: "|")
            }
        )
    }

    private func badge(_ bytes: Int64?) -> Text? {
        guard let bytes, bytes > 0 else { return nil }
        return Text(ByteSize.format(bytes))
    }
}
