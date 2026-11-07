import Foundation
import Observation
import Sparkle

/// Wraps Sparkle. Updates only work in the bundled app (it needs `SUFeedURL` and `SUPublicEDKey` in Info.plist),
/// so `swift run` builds simply report that updates are unavailable.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleIdentifier != nil, info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { _, change in
            let value = change.newValue ?? false
            Task { @MainActor in Updater.shared.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
