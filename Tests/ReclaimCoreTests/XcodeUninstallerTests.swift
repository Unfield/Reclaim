import Foundation
import Testing
@testable import ReclaimCore

@Suite struct XcodeUninstallerTests {
    typealias FakeShell = XcodeSimulatorsToolTests.FakeShell

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "ReclaimXcode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// A minimal app bundle with an Info.plist (and optionally an executable `simctl`).
    @discardableResult
    private func makeBundle(at url: URL, bundleID: String, simctl: Bool = false) throws -> URL {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        if simctl {
            let tool = URL(filePath: XcodeUninstaller.simctl(in: url))
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        return url
    }

    private func xcode(at url: URL) -> InstalledApp {
        InstalledApp(url: url, name: url.deletingPathExtension().lastPathComponent, bundleID: XcodeUninstaller.bundleID, version: "16.0", size: 1_000, lastUsed: nil, dateAdded: nil)
    }

    @Test func xcodeCanBeUninstalledButOtherAppleAppsCannot() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let uninstaller = AppUninstaller(inventory: AppInventory(roots: [home.appending(path: "Applications")], home: home))

        let app = xcode(at: home.appending(path: "Applications/Xcode.app"))
        #expect(app.isXcode)
        #expect(!app.isAppleApp)
        try uninstaller.validate(app)

        let pages = InstalledApp(url: home.appending(path: "Applications/Pages.app"), name: "Pages", bundleID: "com.apple.iWork.Pages", version: nil, size: 1, lastUsed: nil, dateAdded: nil)
        #expect(pages.isAppleApp)
        #expect(throws: UninstallError.self) { try uninstaller.validate(pages) }
    }

    @Test func offersXcodeDataAsLeftovers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appending(path: "Library")
        for path in [
            "Developer/Xcode/DerivedData/App-abc/x", "Developer/CoreSimulator/Devices/AAAA/data", "Caches/com.apple.dt.Xcode/x",
            "Preferences/com.apple.dt.Xcode.plist", "Logs/CoreSimulator/x",
            // Not Xcode's: other developer tools and unrelated Apple data.
            "Developer/Toolchains/swift.xctoolchain", "Caches/com.apple.Safari/x",
        ] {
            let url = library.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: url)
        }
        let applications = home.appending(path: "Applications")
        let appURL = try makeBundle(at: applications.appending(path: "Xcode.app"), bundleID: XcodeUninstaller.bundleID)

        let inventory = AppInventory(roots: [applications], home: home)
        let leftovers = inventory.leftovers(for: xcode(at: appURL))
        let names = Set(leftovers.map { $0.url.path.replacingOccurrences(of: library.path + "/", with: "") })
        #expect(names == [
            "Developer/Xcode", "Developer/CoreSimulator", "Caches/com.apple.dt.Xcode",
            "Preferences/com.apple.dt.Xcode.plist", "Logs/CoreSimulator",
        ])

        // Removing the leftovers is limited to those locations too.
        let report = AppUninstaller(inventory: inventory).removeLeftovers(
            leftovers + [CleanupItem(url: library.appending(path: "Developer/Toolchains"), size: 1, modified: nil)],
            of: xcode(at: appURL),
            method: .deletePermanently
        )
        #expect(report.removed.count == 5)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "Developer/Toolchains").path))
        #expect(!FileManager.default.fileExists(atPath: library.appending(path: "Developer/Xcode").path))
    }

    @Test func keepsSharedDataWhileAnotherXcodeIsInstalled() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let developer = home.appending(path: "Library/Developer/Xcode/DerivedData")
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        let applications = home.appending(path: "Applications")
        let release = try makeBundle(at: applications.appending(path: "Xcode.app"), bundleID: XcodeUninstaller.bundleID)
        let beta = try makeBundle(at: applications.appending(path: "Xcode-beta.app"), bundleID: XcodeUninstaller.bundleID)
        try makeBundle(at: applications.appending(path: "Other.app"), bundleID: "com.example.other")

        let inventory = AppInventory(roots: [applications], home: home)
        #expect(inventory.otherXcodeInstallations(than: xcode(at: release)).map(\.normalizedPath) == [beta.normalizedPath])
        #expect(inventory.leftovers(for: xcode(at: release)).isEmpty)
    }

    @Test func listsAndDeletesRuntimesWithXcodesOwnSimctl() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try makeBundle(at: home.appending(path: "Applications/Xcode.app"), bundleID: XcodeUninstaller.bundleID, simctl: true)
        let simctl = XcodeUninstaller.simctl(in: app)
        let shell = FakeShell([
            "\(simctl) runtime list --json": XcodeSimulatorsToolTests.ok(XcodeSimulatorsToolTests.runtimesJSON),
            "\(simctl) runtime delete 33333333-CCCC-4000-8000-000000000003": XcodeSimulatorsToolTests.failure("Unable to delete runtime"),
        ])
        let uninstaller = XcodeUninstaller(run: { command, arguments, _ in shell.run(command, arguments) })

        // Everything deletable is offered, including runtimes simulators still use. Bundled and already-deleting ones aren't.
        let runtimes = await uninstaller.runtimes(for: app)
        #expect(runtimes.map(\.displayName) == ["iOS 17.0", "iOS 18.2", "watchOS 10.0"])

        let (freed, failures) = await uninstaller.deleteRuntimes(runtimes, using: app)
        #expect(freed == 7_011_510_272 + 8_500_000_000)
        #expect(failures.count == 1)
        #expect(failures.first?.hasPrefix("watchOS 10.0") == true)
        #expect(shell.commands.filter { $0.contains("runtime delete") }.count == 3)
    }

    @Test func noRuntimesWithoutSimctl() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try makeBundle(at: home.appending(path: "Applications/Xcode.app"), bundleID: XcodeUninstaller.bundleID)
        let shell = FakeShell([:])
        let uninstaller = XcodeUninstaller(run: { command, arguments, _ in shell.run(command, arguments) })
        #expect(await uninstaller.runtimes(for: app).isEmpty)
        #expect(shell.commands.isEmpty)
    }

    @Test func detectsActiveDeveloperDirectory() async {
        let app = URL(filePath: "/Applications/Xcode.app", directoryHint: .isDirectory)
        func uninstaller(_ result: ShellResult) -> XcodeUninstaller {
            let shell = FakeShell(["/usr/bin/xcode-select -p": result])
            return XcodeUninstaller(run: { command, arguments, _ in shell.run(command, arguments) })
        }
        #expect(await uninstaller(XcodeSimulatorsToolTests.ok("/Applications/Xcode.app/Contents/Developer\n")).isActiveDeveloperDirectory(app))
        #expect(await !uninstaller(XcodeSimulatorsToolTests.ok("/Applications/Xcode-beta.app/Contents/Developer\n")).isActiveDeveloperDirectory(app))
        #expect(await !uninstaller(XcodeSimulatorsToolTests.ok("/Library/Developer/CommandLineTools\n")).isActiveDeveloperDirectory(app))
        #expect(await !uninstaller(XcodeSimulatorsToolTests.failure("unable to get active developer directory")).isActiveDeveloperDirectory(app))
    }
}
