import Foundation
import Testing
@testable import ReclaimCore

// MARK: - Fixtures

private func makeDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int = 4_096) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

private func makeBundle(_ url: URL, id: String, plistPath: String = "Contents/Info.plist") throws {
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    let file = url.appending(path: plistPath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try plist.write(to: file)
}

private func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
}

/// A fake home with a fake ~/Library, an Applications folder, a launchd folder and canned LaunchServices answers.
private struct Fixture {
    let root: URL
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var library: URL { home.appending(path: "Library", directoryHint: .isDirectory) }
    var apps: URL { root.appending(path: "Applications", directoryHint: .isDirectory) }
    var services: URL { root.appending(path: "LaunchDaemons", directoryHint: .isDirectory) }

    init() throws {
        root = try makeDirectory("ReclaimOrphans")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ folder: String, _ name: String) -> URL {
        library.appending(path: folder, directoryHint: .isDirectory).appending(path: name)
    }

    func finder(
        exclusions: Exclusions = Exclusions(),
        launchServices: [String: [URL]] = [:],
        running: [String] = []
    ) -> OrphanFinder {
        OrphanFinder(
            home: home,
            appRoots: [apps],
            serviceFolders: [services],
            exclusions: exclusions,
            applicationURLs: { launchServices[$0] ?? [] },
            runningBundleIDs: { running }
        )
    }
}

// MARK: - IDs and names

@Suite struct LeftoverIDTests {
    @Test func recognizesReverseDNSNames() {
        #expect(OrphanFinder.looksLikeBundleID("com.vendor.App"))
        #expect(OrphanFinder.looksLikeBundleID("net.raymondhill.uBlock-Origin_Lite"))
        #expect(OrphanFinder.looksLikeBundleID("com.unity3d.UnityEditor5.x"))
        #expect(!OrphanFinder.looksLikeBundleID("com.vendor"))
        #expect(!OrphanFinder.looksLikeBundleID("Some App"))
        #expect(!OrphanFinder.looksLikeBundleID("com.vendor.My App"))
        #expect(!OrphanFinder.looksLikeBundleID("com..vendor.App"))
        #expect(!OrphanFinder.looksLikeBundleID("com.vendor.App."))
        #expect(!OrphanFinder.looksLikeBundleID("com.vendör.App"))
        #expect(!OrphanFinder.looksLikeBundleID("com.vendor/evil.App"))
    }

    @Test func neverOffersAppleGroupsOrSharedIDs() {
        #expect(OrphanFinder.isCandidate("com.vendor.App"))
        #expect(!OrphanFinder.isCandidate("com.apple.Safari"))
        #expect(!OrphanFinder.isCandidate("COM.APPLE.Safari"))
        #expect(!OrphanFinder.isCandidate("group.com.vendor.shared"))
        #expect(!OrphanFinder.isCandidate("systemgroup.com.apple.x"))
        #expect(!OrphanFinder.isCandidate("ABCDE12345.com.vendor.shared"))
        #expect(!OrphanFinder.isCandidate("org.swift.swiftpm"))
    }

    @Test func parsesEntryNamesPerFolder() {
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App.plist", kind: .preferences) == "com.vendor.App")
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App", kind: .preferences) == nil)
        #expect(OrphanFinder.bundleID(fromEntry: ".plist", kind: .preferences) == nil)
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App.savedState", kind: .savedState) == "com.vendor.App")
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App.binarycookies", kind: .cookies) == "com.vendor.App")
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App.binarycookies", kind: .httpStorages) == "com.vendor.App")
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App", kind: .httpStorages) == "com.vendor.App")
        #expect(OrphanFinder.bundleID(fromEntry: "com.vendor.App", kind: .containers) == "com.vendor.App")
        #expect(OrphanFinder.bundleID(fromEntry: "com.apple.Safari.plist", kind: .preferences) == nil)
        #expect(OrphanFinder.bundleID(fromEntry: "Vendor App", kind: .applicationSupport) == nil)
    }

    @Test func installedIDsCoverDottedPrefixesBothWays() {
        let index = InstalledBundleIndex(["com.google.Chrome", "com.vendor.App.LoginHelper"])
        #expect(index.covers("com.google.Chrome"))
        #expect(index.covers("COM.GOOGLE.CHROME"))
        #expect(index.covers("com.google.Chrome.helper"))
        #expect(index.covers("com.google.Chrome.helper.Renderer"))
        #expect(index.covers("com.vendor.App"))
        // Siblings and look-alikes aren't covered.
        #expect(!index.covers("com.google.ChromeCanary"))
        #expect(!index.covers("com.google.Drive"))
        #expect(!index.covers("com.vendor.AppPro"))
        #expect(!index.covers("com.vendor.Other"))
    }

    @Test func guessesReadableNames() {
        #expect(OrphanFinder.guessName(for: "com.hnc.Discord") == "Discord")
        #expect(OrphanFinder.guessName(for: "com.spotify.client") == "Spotify")
        #expect(OrphanFinder.guessName(for: "com.raycast.macos") == "Raycast")
        #expect(OrphanFinder.guessName(for: "com.mitchellh.ghostty") == "Ghostty")
        #expect(OrphanFinder.guessName(for: "net.raymondhill.uBlock-Origin-Lite") == "uBlock Origin Lite")
        #expect(OrphanFinder.guessName(for: "com.vendor.my-tool") == "My Tool")
        #expect(OrphanFinder.guessName(for: "com.vendor.App", appURL: URL(filePath: "/Applications/Vendor Studio.app")) == "Vendor Studio")
    }
}

// MARK: - Scanning

@Suite struct OrphanScanTests {
    @Test func findsLeftoversOfRemovedAppsOnly() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }

        // An installed app with nested helpers, extensions, frameworks and a helper tool.
        let installed = f.apps.appending(path: "Installed.app")
        try makeBundle(installed, id: "com.vendor.Installed")
        try makeBundle(installed.appending(path: "Contents/Library/LoginItems/Login.app"), id: "com.vendor.LoginHelper")
        try makeBundle(installed.appending(path: "Contents/PlugIns/Share.appex"), id: "com.vendor.ShareExtension")
        try makeBundle(installed.appending(path: "Contents/XPCServices/Worker.xpc"), id: "com.vendor.Worker")
        try makeBundle(installed.appending(path: "Contents/Frameworks/Kit.framework"), id: "com.vendor.Kit", plistPath: "Resources/Info.plist")
        try write(installed.appending(path: "Contents/Library/LaunchServices/com.vendor.privileged-tool"))
        // An app in a subfolder of Applications.
        try makeBundle(f.apps.appending(path: "Suite/Nested.app"), id: "com.nested.App")
        // A launch daemon left by another vendor.
        let daemon = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.daemon.Agent", "AssociatedBundleIdentifiers": ["com.daemon.Manager"]], format: .xml, options: 0
        )
        try daemon.write(to: f.services.appending(path: "com.daemon.agent-job.plist"))

        // Leftovers of a removed app, in every kind of folder.
        try write(f.url("Application Support", "com.gone.Widget/data.bin"), bytes: 64_000)
        try write(f.url("Caches", "com.gone.Widget/cache.bin"), bytes: 32_000)
        try write(f.url("Containers", "com.gone.Widget/Data/file"))
        try write(f.url("Preferences", "com.gone.Widget.plist"))
        try write(f.url("Saved Application State", "com.gone.Widget.savedState/windows.plist"))
        try write(f.url("HTTPStorages", "com.gone.Widget.binarycookies"))
        try write(f.url("WebKit", "com.gone.Widget/db"))
        try write(f.url("Logs", "com.gone.Widget/log.txt"))
        try write(f.url("Application Scripts", "com.gone.Widget/.keep"))
        try write(f.url("Cookies", "com.gone.Widget.binarycookies"))
        try write(f.url("Containers", "com.gone.Widget.ShareExtension/Data/file"))
        try write(f.url("Caches", "com.small.Tool/x"), bytes: 1_000)

        // Not leftovers.
        for name in [
            "com.vendor.Installed", "com.vendor.Installed.ShipIt", "com.vendor.LoginHelper", "com.vendor.ShareExtension",
            "com.vendor.Worker", "com.vendor.Kit", "com.vendor.privileged-tool", "com.nested.App", "com.daemon.Agent",
            "com.daemon.Manager", "com.running.App", "com.ls.Known", "com.apple.Safari", "Some Folder", "group.com.gone.shared",
        ] {
            try write(f.url("Caches", "\(name)/x"))
        }
        try write(f.url("Preferences", "com.gone.Widget"))  // Preferences entries must be plists.
        try FileManager.default.createDirectory(at: f.apps.appending(path: "Known.app"), withIntermediateDirectories: true)

        let scan = await f.finder(
            launchServices: ["com.ls.Known": [f.apps.appending(path: "Known.app")]],
            running: ["com.running.App"]
        ).scan()

        #expect(scan.groups.map(\.bundleID) == ["com.gone.Widget", "com.small.Tool"])
        let widget = try #require(scan.groups.first)
        #expect(widget.name == "Widget")
        #expect(widget.safety == .review)
        #expect(widget.locations.count == 11)
        #expect(Set(widget.locations.map(\.kind)) == Set(LeftoverKind.allCases))
        #expect(widget.locations.contains { $0.bundleID == "com.gone.Widget.ShareExtension" })
        #expect(widget.locations.first?.kind == .applicationSupport)  // largest first

        // Containers aren't read during a scan (privacy prompts), everything else is measured.
        for location in widget.locations {
            #expect((location.size == nil) == (location.kind == .containers))
        }
        #expect(widget.hasUnmeasuredLocations)
        #expect(widget.size >= 96_000)
        #expect(widget.lastModified != nil)

        let container = try #require(widget.locations.first { $0.kind == .containers && $0.bundleID == "com.gone.Widget" })
        #expect((OrphanFinder.measured(container).size ?? 0) > 0)
    }

    @Test func launchServicesOnlyCountsAppsThatStillExist() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try write(f.url("Caches", "com.ls.Stale/x"))
        try write(f.url("Caches", "com.ls.Trashed/x"))
        let trashed = f.home.appending(path: ".Trash/Trashed.app")
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)

        let scan = await f.finder(launchServices: [
            "com.ls.Stale": [f.apps.appending(path: "Stale Thing.app")],
            "com.ls.Trashed": [trashed],
        ]).scan()

        #expect(scan.groups.map(\.bundleID).sorted() == ["com.ls.Stale", "com.ls.Trashed"])
        #expect(scan.groups.first { $0.bundleID == "com.ls.Stale" }?.name == "Stale Thing")
    }

    @Test func skipsExcludedPathsAndSymlinks() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try write(f.url("Caches", "com.gone.Widget/x"))
        try write(f.url("Logs", "com.gone.Widget/x"))
        let elsewhere = f.root.appending(path: "Elsewhere")
        try write(elsewhere.appending(path: "important.txt"))
        try FileManager.default.createSymbolicLink(at: f.url("Caches", "com.link.App"), withDestinationURL: elsewhere)

        var exclusions = Exclusions()
        exclusions.add(f.url("Caches", "com.gone.Widget"))
        let scan = await f.finder(exclusions: exclusions).scan()

        #expect(scan.groups.map(\.bundleID) == ["com.gone.Widget"])
        #expect(scan.groups.first?.locations.map(\.kind) == [.logs])
    }

    @Test func emptyLibraryHasNoLeftovers() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let scan = await f.finder().scan()
        #expect(scan.groups.isEmpty)
        #expect(scan.unreadableFolders.isEmpty)
    }
}

// MARK: - Removal safety

@Suite struct LeftoverRemovalTests {
    private func location(_ f: Fixture, _ folder: String, _ name: String, id: String, kind: LeftoverKind) -> LeftoverLocation {
        LeftoverLocation(bundleID: id, kind: kind, url: f.url(folder, name), size: 1, modified: nil)
    }

    @Test func removesScannedLeftovers() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try write(f.url("Caches", "com.gone.Widget/x"))
        try write(f.url("Preferences", "com.gone.Widget.plist"))
        try write(f.url("Containers", "com.gone.Widget/Data/x"))

        let finder = f.finder()
        let group = try #require(await finder.scan().groups.first)
        let report = finder.remove(group.locations, method: .deletePermanently)

        #expect(report.failures.isEmpty)
        #expect(report.removed.count == 3)
        #expect(report.removed.allSatisfy { $0.size > 0 })  // unmeasured containers are measured before removal
        #expect(group.locations.allSatisfy { !exists($0.url) })
        #expect(exists(f.url("Caches", "")))
    }

    @Test func refusesPathsThatArentExactlyLeftoverLocations() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try write(f.url("Caches", "com.gone.Widget/cache.bin"))
        try write(f.url("Caches", "com.small.Tool/x"))
        try write(f.url("Application Support", "Widget/x"))
        try write(f.url("Caches", "com.apple.Safari/x"))
        try write(f.home.appending(path: "Documents/com.gone.Widget/x"))

        let attempts = [
            location(f, "Caches", "com.gone.Widget/cache.bin", id: "com.gone.Widget", kind: .caches),  // inside, not the entry
            LeftoverLocation(bundleID: "com.gone.Widget", kind: .caches, url: f.library.appending(path: "Caches"), size: 1, modified: nil),
            location(f, "Application Support", "Widget", id: "com.gone.Widget", kind: .applicationSupport),  // name-based
            location(f, "Caches", "com.small.Tool", id: "com.gone.Widget", kind: .caches),  // another app's ID
            location(f, "Caches", "com.gone.Widget", id: "com.gone.Widget", kind: .preferences),  // wrong folder
            location(f, "Caches", "com.apple.Safari", id: "com.apple.Safari", kind: .caches),  // Apple
            LeftoverLocation(bundleID: "com.gone.Widget", kind: .caches, url: f.home.appending(path: "Documents/com.gone.Widget"), size: 1, modified: nil),
            LeftoverLocation(bundleID: "com.small.Tool", kind: .caches, url: f.url("Caches", "com.gone.Widget/../com.small.Tool"), size: 1, modified: nil),
            LeftoverLocation(bundleID: "com.small.Tool", kind: .caches, url: f.url("Caches", "./com.small.Tool"), size: 1, modified: nil),
        ]
        let report = f.finder().remove(attempts, method: .deletePermanently)

        #expect(report.removed.isEmpty)
        #expect(report.failures.count == attempts.count)
        #expect(exists(f.url("Caches", "com.gone.Widget/cache.bin")))
        #expect(exists(f.url("Caches", "com.small.Tool/x")))
        #expect(exists(f.url("Application Support", "Widget/x")))
        #expect(exists(f.url("Caches", "com.apple.Safari/x")))
        #expect(exists(f.home.appending(path: "Documents/com.gone.Widget/x")))
    }

    @Test func refusesAppsInstalledOrRunningSinceTheScan() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try write(f.url("Caches", "com.gone.Widget/x"))
        try write(f.url("Caches", "com.back.Again/x"))
        try write(f.url("Caches", "com.ls.Found/x"))
        try write(f.url("Caches", "com.now.Running/x"))

        let groups = await f.finder().scan().groups
        #expect(groups.count == 4)

        // Reinstalled as a helper inside another app, found by LaunchServices, or running.
        try makeBundle(f.apps.appending(path: "Other.app/Contents/Helpers/Again.app"), id: "com.back.Again.Helper")
        try FileManager.default.createDirectory(at: f.root.appending(path: "Found.app"), withIntermediateDirectories: true)
        let finder = f.finder(launchServices: ["com.ls.Found": [f.root.appending(path: "Found.app")]], running: ["com.now.Running"])
        let report = finder.remove(groups.flatMap(\.locations), method: .deletePermanently)

        #expect(report.removed.map(\.url) == [f.url("Caches", "com.gone.Widget")])
        #expect(report.failures.count == 3)
        #expect(exists(f.url("Caches", "com.back.Again/x")))
        #expect(exists(f.url("Caches", "com.ls.Found/x")))
        #expect(exists(f.url("Caches", "com.now.Running/x")))
    }

    @Test func refusesSymlinksAndExcludedPaths() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let elsewhere = f.root.appending(path: "Elsewhere")
        try write(elsewhere.appending(path: "important.txt"))
        try FileManager.default.createDirectory(at: f.url("Caches", ""), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.url("Caches", "com.link.App"), withDestinationURL: elsewhere)
        try write(f.url("Logs", "com.kept.App/x"))

        var exclusions = Exclusions()
        exclusions.add(f.url("Logs", "com.kept.App"))
        let report = f.finder(exclusions: exclusions).remove([
            location(f, "Caches", "com.link.App", id: "com.link.App", kind: .caches),
            location(f, "Logs", "com.kept.App", id: "com.kept.App", kind: .logs),
        ], method: .deletePermanently)

        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 2)
        #expect(exists(f.url("Caches", "com.link.App")))
        #expect(exists(elsewhere.appending(path: "important.txt")))
        #expect(exists(f.url("Logs", "com.kept.App/x")))
    }

    @Test func refusesWhenALibraryFolderIsASymlink() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let real = f.root.appending(path: "RealCaches")
        try write(real.appending(path: "com.gone.Widget/x"))
        try FileManager.default.createDirectory(at: f.library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.library.appending(path: "Caches"), withDestinationURL: real)

        let finder = f.finder()
        #expect(await finder.scan().groups.isEmpty)
        let report = finder.remove([location(f, "Caches", "com.gone.Widget", id: "com.gone.Widget", kind: .caches)], method: .deletePermanently)

        #expect(report.removed.isEmpty)
        #expect(exists(real.appending(path: "com.gone.Widget/x")))
    }

    @Test func reportsMissingItems() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.url("Caches", ""), withIntermediateDirectories: true)
        let report = f.finder().remove([location(f, "Caches", "com.gone.Widget", id: "com.gone.Widget", kind: .caches)], method: .deletePermanently)
        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 1)
    }
}
