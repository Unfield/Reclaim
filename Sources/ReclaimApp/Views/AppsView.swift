import ReclaimCore
import SwiftUI

struct AppsView: View {
    enum Filter: String, CaseIterable {
        case unused = "Unused"
        case all = "All Apps"

        var title: String {
            switch self {
            case .unused: String(localized: "Unused")
            case .all: String(localized: "All Apps")
            }
        }
    }

    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.unusedAppDays) private var unusedDays = 90
    @State private var filter = Filter.unused
    @State private var search = ""
    @State private var selection: InstalledApp.ID?
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.size, order: .reverse)]
    @State private var appToUninstall: InstalledApp?

    private var visibleApps: [InstalledApp] {
        var apps = filter == .unused ? model.unusedApps(days: unusedDays) : model.apps
        if !search.isEmpty {
            apps = apps.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }
        }
        return apps.sorted(using: sortOrder)
    }

    var body: some View {
        let apps = visibleApps
        let selectedApp = apps.first { $0.id == selection }

        Group {
            if model.isLoadingApps && model.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Measuring apps…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? (filter == .unused ? "No Unused Apps" : "No Apps Found") : "No Results",
                    systemImage: search.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    description: Text(search.isEmpty && filter == .unused ? "Every app has been opened recently." : "")
                )
            } else {
                Table(apps, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { app in
                        HStack(spacing: 8) {
                            FileIcon(url: app.url, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                if let version = app.version {
                                    Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    TableColumn("Last Opened", value: \.sortDate) { app in
                        Text(app.lastUsed?.shortDate ?? String(localized: "Never"))
                            .foregroundStyle(app.lastUsed == nil ? .secondary : .primary)
                    }
                    .width(120)
                    TableColumn("Size", value: \.size) { app in
                        SizeText(bytes: app.size).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)
                }
                .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                    if let app = model.apps.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") { AppModel.revealInFinder(app.url) }
                        Divider()
                        Button("Uninstall…") { appToUninstall = app }
                    }
                } primaryAction: { ids in
                    appToUninstall = model.apps.first { ids.contains($0.id) }
                }
            }
        }
        .topBar {
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Picker("Not opened in", selection: $unusedDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                .fixedSize()
                .opacity(filter == .unused ? 1 : 0)
                .disabled(filter != .unused)

                Spacer()

                SearchField(text: $search, prompt: "Search apps")
                    .frame(width: 200)

                Button {
                    Task { await model.loadApps() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Rescan apps")
                .disabled(model.isLoadingApps)
            }
        }
        .bottomBar {
            ActivityIndicator(isActive: model.isLoadingApps)
            Text("\(apps.count) apps · \(ByteSize.format(apps.reduce(0) { $0 + $1.size }))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Reveal in Finder") { selectedApp.map { AppModel.revealInFinder($0.url) } }
                .secondaryButtonStyle()
                .disabled(selectedApp == nil)
            Button("Uninstall…") { appToUninstall = selectedApp }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(selectedApp == nil)
        }
        .navigationTitle("Applications")
        .task {
            if !model.appsLoaded { await model.loadApps() }
        }
        // Drag an app here (from Finder or the Dock's Applications stack) to uninstall it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            model.requestUninstall(url)
            return true
        }
        .onChange(of: model.uninstallRequest, initial: true) { _, request in
            guard let request else { return }
            appToUninstall = request
            model.uninstallRequest = nil
        }
        .sheet(item: $appToUninstall) { app in
            UninstallSheet(app: app)
        }
    }
}

/// An inline search field, so search doesn't add and remove toolbar items when switching screens.
struct SearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct UninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp

    @State private var leftovers: [CleanupItem]?
    @State private var selectedLeftovers = Set<URL>()
    @State private var isWorking = false
    @State private var isRunning = false
    @State private var result: CleanupReport?
    @State private var needsAdministrator = false
    @State private var errorMessage: String?

    private var chosenLeftovers: [CleanupItem] {
        (leftovers ?? []).filter { selectedLeftovers.contains($0.url) }
    }

    private var total: Int64 {
        app.size + chosenLeftovers.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                FileIcon(url: app.url, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall \(app.name)").font(.title2.weight(.semibold))
                    Text([app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Last opened: \(app.lastUsed?.shortDate ?? String(localized: "never"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let result {
                resultView(result)
            } else {
                filesList
            }

            if isRunning && result == nil {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(app.name) is running.")
                    Spacer()
                    Button("Quit \(app.name)") {
                        AppModel.quit(app)
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            isRunning = AppModel.isRunning(app)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            HStack(spacing: 10) {
                ActivityIndicator(isActive: isWorking)
                Spacer()
                if result == nil || needsAdministrator {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if needsAdministrator {
                    Button("Use Administrator Password…") { Task { await uninstallAsAdministrator() } }
                        .primaryButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking)
                } else if result != nil {
                    Button("Done") { dismiss() }
                        .primaryButtonStyle()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Move \(ByteSize.format(total)) to Trash") { Task { await uninstall() } }
                        .primaryButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || isRunning || leftovers == nil)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 580)
        .task {
            isRunning = AppModel.isRunning(app)
            let found = await model.leftovers(for: app)
            leftovers = found
            selectedLeftovers = Set(found.map(\.url))
        }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Card(padding: 0) {
                fileRow(path: app.url.abbreviatedPath, size: app.size) {
                    Image(systemName: "checkmark.square.fill").foregroundStyle(.tint)
                }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        if let leftovers {
                            if leftovers.isEmpty {
                                Text("No support files found.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            ForEach(leftovers) { item in
                                fileRow(path: item.url.abbreviatedPath, size: item.size) {
                                    Toggle("", isOn: Binding(
                                        get: { selectedLeftovers.contains(item.url) },
                                        set: { if $0 { selectedLeftovers.insert(item.url) } else { selectedLeftovers.remove(item.url) } }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                }
                                .contextMenu { Button("Reveal in Finder") { AppModel.revealInFinder(item.url) } }
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Looking for support files…").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }
                    }
                }
                .frame(height: 200)
            }
            Text("Support files are settings, caches and data the app stored in your Library. Uncheck anything you want to keep.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fileRow<Leading: View>(path: String, size: Int64, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 10) {
            leading().frame(width: 18)
            Text(path).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            SizeText(bytes: size).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func resultView(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !report.removed.isEmpty {
                Label("Moved \(ByteSize.format(report.bytesFreed)) to the Trash.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(report.failures, id: \.item.url) { failure in
                Label("\(failure.item.name): \(failure.message)", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if needsAdministrator {
                Text("\(app.name) is owned by another user. You can move it to the Trash with an administrator password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        let report = await model.uninstall(app, leftovers: chosenLeftovers)
        result = report
        needsAdministrator = report.failures.contains { $0.item.url == app.url }
    }

    private func uninstallAsAdministrator() async {
        isWorking = true
        defer { isWorking = false }
        do {
            result = try await model.uninstallAsAdministrator(app, leftovers: chosenLeftovers)
            needsAdministrator = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
