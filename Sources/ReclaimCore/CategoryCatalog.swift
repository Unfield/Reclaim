import Foundation

/// The built-in set of cleanup categories.
///
/// Category roots must never overlap (no root may live inside another category's root),
/// otherwise sizes would be double counted. This is enforced by a unit test.
public enum CategoryCatalog {
    private static let day: TimeInterval = 86_400

    public static func all(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        oldDownloadsDays: Int = 90
    ) -> [CleanupCategory] {
        func path(_ relative: String) -> URL {
            home.appending(path: relative, directoryHint: .isDirectory)
        }

        return [
            // MARK: System & Apps
            CleanupCategory(
                id: "user-caches",
                name: "App Caches",
                summary: "Caches stored by apps in ~/Library/Caches. Apps recreate these as needed.",
                group: .system,
                safety: .safe,
                roots: [path("Library/Caches")],
                // Cleaned through `brew cleanup` by the Homebrew tool instead.
                excludedNames: ["Homebrew"]
            ),
            CleanupCategory(
                id: "user-logs",
                name: "Logs",
                summary: "Diagnostic logs written by apps and the system for your user account.",
                group: .system,
                safety: .safe,
                roots: [path("Library/Logs")]
            ),
            CleanupCategory(
                id: "trash",
                name: "Trash",
                summary: "Items already in your Trash. Emptying it deletes them for good.",
                group: .system,
                safety: .safe,
                roots: [path(".Trash")],
                deletesPermanently: true
            ),
            CleanupCategory(
                id: "mail-downloads",
                name: "Mail Downloads",
                summary: "Copies of attachments you opened in Mail. The originals stay in your mailbox.",
                group: .system,
                safety: .review,
                roots: [path("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]
            ),
            CleanupCategory(
                id: "ios-backups",
                name: "iPhone & iPad Backups",
                summary: "Local device backups made by Finder. Needs Full Disk Access to read.",
                group: .system,
                safety: .caution,
                roots: [path("Library/Application Support/MobileSync/Backup")]
            ),

            // MARK: Developer
            CleanupCategory(
                id: "xcode-derived-data",
                name: "Xcode DerivedData",
                summary: "Build products and indexes. Xcode rebuilds them on the next build.",
                group: .developer,
                safety: .safe,
                roots: [path("Library/Developer/Xcode/DerivedData")]
            ),
            CleanupCategory(
                id: "xcode-device-support",
                name: "Device Support Files",
                summary: "Debug symbols for devices you've connected. Re-copied when a device is plugged in.",
                group: .developer,
                safety: .review,
                roots: [
                    path("Library/Developer/Xcode/iOS DeviceSupport"),
                    path("Library/Developer/Xcode/watchOS DeviceSupport"),
                    path("Library/Developer/Xcode/tvOS DeviceSupport"),
                    path("Library/Developer/Xcode/visionOS DeviceSupport"),
                ]
            ),
            CleanupCategory(
                id: "xcode-archives",
                name: "Xcode Archives",
                summary: "Archived app builds. Keep these if you need to symbolicate crash reports.",
                group: .developer,
                safety: .caution,
                roots: [path("Library/Developer/Xcode/Archives")]
            ),
            CleanupCategory(
                id: "simulator-caches",
                name: "Simulator Caches",
                summary: "Shared caches used by the iOS Simulator.",
                group: .developer,
                safety: .safe,
                roots: [path("Library/Developer/CoreSimulator/Caches")]
            ),
            CleanupCategory(
                id: "package-caches",
                name: "Package Manager Caches",
                summary: "Download caches for npm, Gradle, Cargo, uv and other tools. Re-downloaded on demand.",
                group: .developer,
                safety: .review,
                roots: [
                    path(".npm/_cacache"),
                    path(".gradle/caches"),
                    path(".cargo/registry/cache"),
                    path(".cache"),
                    path("Library/pnpm/store"),
                ],
                // AI models are large and deliberate downloads; they're managed on the AI Models screen.
                excludedNames: ["huggingface", "lm-studio", "torch"]
            ),
            CleanupCategory(
                id: "android-images",
                name: "Android Emulator Images",
                summary: "System images used by the Android emulator. Re-downloaded by Android Studio when needed.",
                group: .developer,
                safety: .review,
                roots: [path("Library/Android/sdk/system-images"), path(".android/cache")]
            ),
            CleanupCategory(
                id: "jetbrains-old-versions",
                name: "Old JetBrains IDE Data",
                summary: "Settings and indexes left behind by older versions of IntelliJ, PyCharm, WebStorm and friends.",
                group: .developer,
                safety: .review,
                roots: [path("Library/Application Support/JetBrains")],
                selector: .olderVersions(pattern: #"([A-Za-z]+)(\d{4}\.\d+)"#)
            ),
            CleanupCategory(
                id: "editor-old-extensions",
                name: "Old Editor Extensions",
                summary: "Outdated versions of VS Code, Cursor and Windsurf extensions that were kept after updating.",
                group: .developer,
                safety: .safe,
                roots: [path(".vscode/extensions"), path(".cursor/extensions"), path(".windsurf/extensions")],
                selector: .olderVersions(pattern: #"(.+?)-(\d+\.\d+\.\d+.*)"#)
            ),
            CleanupCategory(
                id: "unity-cache",
                name: "Unity Cache",
                summary: "Downloaded Asset Store packages and the global Unity cache.",
                group: .developer,
                safety: .review,
                roots: [path("Library/Unity/cache"), path("Library/Unity/Asset Store-5.x")]
            ),

            // MARK: Personal
            CleanupCategory(
                id: "installers",
                name: "Leftover Installers",
                summary: "Disk images, installer packages, iOS firmware and macOS installers you've probably already used.",
                group: .personal,
                safety: .review,
                roots: [
                    path("Downloads"),
                    URL(filePath: "/Applications", directoryHint: .isDirectory),
                    path("Library/iTunes/iPhone Software Updates"),
                    path("Library/iTunes/iPad Software Updates"),
                ],
                selector: .matching(NameFilter(extensions: Self.installerExtensions, patterns: [Self.macOSInstallerPattern]))
            ),
            CleanupCategory(
                id: "old-downloads",
                name: "Old Downloads",
                summary: "Items in Downloads that haven't been modified in \(oldDownloadsDays) days.",
                group: .personal,
                safety: .caution,
                roots: [path("Downloads")],
                minimumAge: TimeInterval(oldDownloadsDays) * day,
                // Installers are listed under Leftover Installers instead.
                selector: .matching(NameFilter(excludedExtensions: Self.installerExtensions, excludedPatterns: [Self.macOSInstallerPattern]))
            ),
        ]
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "ipsw", "xip"]
    static let macOSInstallerPattern = #"Install macOS .+\.app"#

    public static func category(withID id: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CleanupCategory? {
        all(home: home).first { $0.id == id }
    }

    /// Each non-startup disk keeps its own Trash at `<volume>/.Trashes/<uid>`.
    public static func volumeCategories(for volumes: [VolumeInfo], userID: uid_t = getuid()) -> [CleanupCategory] {
        volumes
            .filter { !$0.isStartup && !$0.isReadOnly && $0.kind != .network }
            .map { volume in
                CleanupCategory(
                    id: volumeTrashID(for: volume),
                    name: "Trash on \(volume.name)",
                    summary: "Items you deleted from \(volume.name). They still take up space on that disk.",
                    group: .otherDisks,
                    safety: .safe,
                    roots: [volume.url.appending(path: ".Trashes/\(userID)", directoryHint: .isDirectory)],
                    deletesPermanently: true
                )
            }
    }

    /// A CLI-friendly ID such as `trash-my-passport`.
    public static func volumeTrashID(for volume: VolumeInfo) -> String {
        let slug = volume.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return "trash-" + (slug.isEmpty ? "disk" : slug)
    }

    /// Home categories plus a Trash category for each other mounted disk.
    public static func allIncludingVolumes(oldDownloadsDays: Int = 90) -> [CleanupCategory] {
        all(oldDownloadsDays: oldDownloadsDays) + volumeCategories(for: VolumeInfo.mounted())
    }
}
