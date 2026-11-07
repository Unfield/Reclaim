import Foundation
import UserNotifications

/// UserDefaults keys shared by `@AppStorage` in views and the model.
enum Prefs {
    static let cleanupMethod = "cleanupMethod"
    static let oldDownloadsDays = "oldDownloadsDays"
    static let unusedAppDays = "unusedAppDays"
    static let scanOnLaunch = "scanOnLaunch"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let menuBarShowsFreeSpace = "menuBarShowsFreeSpace"
    static let lowSpaceThresholdGB = "lowSpaceThresholdGB"
    static let lowSpaceNotifications = "lowSpaceNotifications"

    static var defaults: [String: Any] { [
        cleanupMethod: "moveToTrash",
        oldDownloadsDays: 90,
        unusedAppDays: 90,
        scanOnLaunch: true,
        showMenuBarExtra: true,
        menuBarShowsFreeSpace: false,
        lowSpaceThresholdGB: 20,
        lowSpaceNotifications: true,
    ] }

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

enum Notifier {
    /// Notifications need a real app bundle; `swift run` launches a bare executable.
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard isSupported else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(title: String, body: String) async {
        guard isSupported, await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-space", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
