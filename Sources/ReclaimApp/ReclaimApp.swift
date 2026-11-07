import AppKit
import ReclaimCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        MainActor.assumeIsolated {
            AppModel.shared.start()
            _ = Updater.shared
        }
    }

    /// Keep running in the menu bar after the window closes, if the menu bar item is enabled.
    /// Apps dropped on Reclaim's Dock icon open the uninstaller.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let app = urls.first(where: { $0.pathExtension == "app" }) else { return }
        MainActor.assumeIsolated {
            AppModel.shared.requestUninstall(app)
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Reclaim" }?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Prefs.bool(Prefs.showMenuBarExtra)
    }
}

@main
struct ReclaimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Prefs.showMenuBarExtra) private var showMenuBarExtra = true
    private let model = AppModel.shared

    init() {
        Prefs.register()
    }

    var body: some Scene {
        Window("Reclaim", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 580)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Rescan Everything") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Divider()
                Button("Overview") { model.selection = .overview }.keyboardShortcut("1")
                Button("Applications") { model.selection = .apps }.keyboardShortcut("2")
                Button("Space Explorer") { model.selection = .explorer }.keyboardShortcut("3")
                Button("Large Files") { model.selection = .largeFiles }.keyboardShortcut("4")
                Button("Memory") { model.selection = .memory }.keyboardShortcut("5")
                Button("Developer Projects") { model.selection = .projects }.keyboardShortcut("6")
                Button("Duplicates") { model.selection = .duplicates }.keyboardShortcut("7")
                Button("Disk History") { model.selection = .history }.keyboardShortcut("8")
            }
            // Kept separate from the system Undo so ⌘Z keeps working in text fields.
            CommandGroup(after: .undoRedo) {
                Button("Put Back “\(model.trashHistory.first?.title ?? String(localized: "Last Cleanup"))”") {
                    if let batch = model.trashHistory.first { Task { await model.putBack(batch.id) } }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.trashHistory.isEmpty)
            }
            CommandGroup(after: .appInfo) {
                if Updater.shared.isAvailable {
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .help) {
                Link("Reclaim on GitHub", destination: ReclaimInfo.repositoryURL)
                Link("Release Notes", destination: ReclaimInfo.releasesURL)
                Divider()
                Link("Report an Issue…", destination: ReclaimInfo.issuesURL)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
