import AppKit
import ReclaimCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// Keep running in the menu bar after the window closes, if the menu bar item is enabled.
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
            }
            CommandGroup(replacing: .help) {
                Link("Reclaim on GitHub", destination: ReclaimInfo.repositoryURL)
                Link("Check for Updates…", destination: ReclaimInfo.releasesURL)
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
