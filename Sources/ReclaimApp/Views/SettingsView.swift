import ReclaimCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }
            ExclusionsSettings()
                .tabItem { Label("Exclusions", systemImage: "nosign") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.scanOnLaunch) private var scanOnLaunch = true
    @AppStorage(Prefs.oldDownloadsDays) private var oldDownloadsDays = 90
    @AppStorage(Prefs.unusedAppDays) private var unusedAppDays = 90
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Remove files by", selection: $model.cleanupMethod) {
                    Text("Moving them to the Trash").tag(CleanupMethod.moveToTrash)
                    Text("Deleting them immediately").tag(CleanupMethod.deletePermanently)
                }
                Toggle("Scan when Reclaim opens", isOn: $scanOnLaunch)
                if Updater.shared.isAvailable {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { Updater.shared.automaticallyChecksForUpdates },
                        set: { Updater.shared.automaticallyChecksForUpdates = $0 }
                    ))
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .disabled(!Notifier.isSupported)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Thresholds") {
                Picker("Old downloads are older than", selection: $oldDownloadsDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
                Picker("Apps are unused after", selection: $unusedAppDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: oldDownloadsDays) {
            Task { await model.scanCategories() }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct MenuBarSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(Prefs.menuBarShowsFreeSpace) private var showsFreeSpace = false
    @AppStorage(Prefs.lowSpaceThresholdGB) private var thresholdGB = 20
    @AppStorage(Prefs.lowSpaceNotifications) private var notifications = true

    var body: some View {
        Form {
            Section {
                Toggle("Show Reclaim in the menu bar", isOn: $showMenuBarExtra)
                Toggle("Show available space next to the icon", isOn: $showsFreeSpace)
                    .disabled(!showMenuBarExtra)
            } footer: {
                Text("While the menu bar item is shown, Reclaim keeps running after you close its window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Low Space Warning") {
                Picker("Warn when less than", selection: $thresholdGB) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB available").tag($0) }
                }
                Toggle("Send a notification", isOn: $notifications)
                    .disabled(!Notifier.isSupported)
                    .onChange(of: notifications) { _, enabled in
                        if enabled { Task { await Notifier.requestAuthorization() } }
                    }
                if !Notifier.isSupported {
                    Text("Notifications and open-at-login need the bundled app (scripts/build-app.sh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: thresholdGB) { model.updateVolume() }
    }
}

/// Paths Reclaim must never clean. Applies to the app and the CLI.
struct ExclusionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var exclusions = Exclusions.load()
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reclaim never cleans these files and folders, or anything inside them.")
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                if exclusions.paths.isEmpty {
                    Text("No exclusions").foregroundStyle(.secondary)
                }
                ForEach(exclusions.paths, id: \.self) { path in
                    HStack {
                        FileIcon(url: URL(filePath: path))
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(minHeight: 180)
            HStack {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if let selection { update { $0.remove(selection) } }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
                Text("Tip: right-click an item in a category and choose “Never Clean This”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { exclusions = Exclusions.load() }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        update { exclusions in panel.urls.forEach { exclusions.add($0) } }
    }

    private func update(_ change: (inout Exclusions) -> Void) {
        change(&exclusions)
        try? exclusions.save()
        Task { await model.scanCategories() }
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                Text("Reclaim works entirely on this Mac. Nothing is uploaded or shared.")
                Text("To measure protected folders such as Mail data, iPhone backups and some caches, add Reclaim under Full Disk Access.")
                    .foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings") { AppModel.openFullDiskAccessSettings() }
            }
        }
        .formStyle(.grouped)
    }
}
