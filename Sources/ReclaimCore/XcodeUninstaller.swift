import Foundation

/// The parts of removing Xcode completely that go beyond moving the app and its support files to the Trash:
/// simulator runtimes (installed system-wide since Xcode 15) and the active developer directory.
public struct XcodeUninstaller: Sendable {
    /// Shared by Xcode and Xcode-beta.
    public static let bundleID = "com.apple.dt.Xcode"

    /// Locations in ~/Library that belong to Xcode and the Simulator, on top of the usual bundle ID locations.
    /// They're shared by every copy of Xcode, so they're only offered when removing the last one.
    static let libraryPaths = [
        "Developer/Xcode", // DerivedData, Archives, device support, snippets, themes and key bindings
        "Developer/CoreSimulator", // Simulators and their data
        "Developer/XCTestDevices", // Simulator clones for parallel testing
        "Developer/XCPGDevices", // Playground simulators
        "Developer/DVTDownloads",
        "Caches/com.apple.dt.xcodebuild",
        "Logs/CoreSimulator",
        "Preferences/com.apple.dt.xcodebuild.plist",
        "Preferences/com.apple.iphonesimulator.plist",
        "Saved Application State/com.apple.iphonesimulator.savedState",
    ]

    let run: XcodeSimulatorsTool.CommandRunner

    public init() {
        self.init(run: { command, arguments, timeout in try await Shell.run(command, arguments, timeout: timeout) })
    }

    init(run: @escaping XcodeSimulatorsTool.CommandRunner) {
        self.run = run
    }

    /// The `simctl` inside this copy of Xcode. Used directly rather than through `xcrun`, which goes by
    /// `xcode-select` and may point at another Xcode or only the Command Line Tools.
    static func simctl(in app: URL) -> String {
        app.appending(path: "Contents/Developer/usr/bin/simctl").path(percentEncoded: false)
    }

    /// Simulator runtimes that can be deleted. Empty if they can't be listed (before Xcode 15 they lived inside the app).
    public func runtimes(for app: URL) async -> [XcodeSimulatorsTool.Runtime] {
        let simctl = Self.simctl(in: app)
        guard FileManager.default.isExecutableFile(atPath: simctl),
              let result = try? await run(simctl, ["runtime", "list", "--json"], 120), result.succeeded,
              let runtimes = XcodeSimulatorsTool.parseRuntimes(result.output) else { return [] }
        return runtimes
            .filter { $0.isDeletable && !($0.state?.localizedCaseInsensitiveContains("delet") ?? false) }
            .sorted { ($0.platformKey, $0.version ?? "") < ($1.platformKey, $1.version ?? "") }
    }

    /// Shuts down running simulators so their data can be removed. Fails harmlessly when none are running.
    public func shutdownSimulators(using app: URL) async {
        _ = try? await run(Self.simctl(in: app), ["shutdown", "all"], 300)
    }

    /// Deletes simulator runtimes. Must run while Xcode is still installed, since it needs Xcode's `simctl`.
    /// - Returns: The bytes freed and a message for each runtime that couldn't be deleted.
    public func deleteRuntimes(_ runtimes: [XcodeSimulatorsTool.Runtime], using app: URL) async -> (freed: Int64, failures: [String]) {
        var freed: Int64 = 0
        var failures = [String]()
        for runtime in runtimes {
            do {
                let result = try await run(Self.simctl(in: app), ["runtime", "delete", runtime.identifier], 600)
                if result.succeeded {
                    freed += runtime.sizeBytes ?? 0
                } else {
                    failures.append(String(localized: "\(runtime.displayName): \(result.failureMessage)"))
                }
            } catch {
                failures.append(String(localized: "\(runtime.displayName): \(error.localizedDescription)"))
            }
        }
        return (freed, failures)
    }

    /// Whether `xcode-select` points into this Xcode. Once it's gone, `git`, `clang` and friends would fail with
    /// "invalid active developer path" until the selection is reset. Check this before removing Xcode.
    public func isActiveDeveloperDirectory(_ app: URL) async -> Bool {
        guard let result = try? await run("/usr/bin/xcode-select", ["-p"], 30), result.succeeded else { return false }
        return Self.path(result.output.trimmingCharacters(in: .whitespacesAndNewlines), isInside: app)
    }

    /// Points `xcode-select` back at the default (the Command Line Tools, if installed). Asks for an administrator password.
    public func resetDeveloperDirectory() async throws {
        let result = try await Shell.runAsAdministrator(
            "/usr/bin/xcode-select",
            ["--reset"],
            prompt: String(localized: "Reclaim needs your password to reset the active developer directory.")
        )
        guard result.succeeded else { throw ShellError.failed(command: "xcode-select --reset", message: result.failureMessage) }
    }

    static func path(_ path: String, isInside app: URL) -> Bool {
        guard !path.isEmpty else { return false }
        let bundle = app.normalizedPath
        let normalized = URL(filePath: path).normalizedPath
        return normalized == bundle || normalized.hasPrefix(bundle + "/")
    }
}

extension AppInventory {
    /// Other copies of Xcode (e.g. a beta next to the release) in the Applications folders.
    public func otherXcodeInstallations(than app: InstalledApp) -> [URL] {
        let path = app.url.normalizedPath
        return findBundles().filter {
            $0.normalizedPath != path && Bundle(url: $0)?.bundleIdentifier == XcodeUninstaller.bundleID
        }
    }
}
