import Foundation
import Testing
@testable import ReclaimCore

@Suite struct LoginItemsTests {
    // MARK: Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "reclaim-login-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writePlist(_ dict: [String: Any], named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return url
    }

    private let exampleApp = URL(filePath: "/Applications/Example.app", directoryHint: .isDirectory)
    private var resolver: LaunchItems.AppResolver {
        let app = exampleApp
        return { $0 == "com.example.app" ? app : nil }
    }

    private func item(_ dict: [String: Any], domain: LaunchItemDomain = .userAgent) throws -> LaunchItem? {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writePlist(dict, named: "item.plist", in: directory)
        return LaunchItems.item(at: url, domain: domain, resolver: resolver)
    }

    // MARK: launchctl output

    @Test func parsesPrintDisabled() {
        let output = """
        disabled services = {
        \t\t"com.docker.helper" => enabled
        \t\t"com.apple.Siri.agent" => disabled
        \t\t"homebrew.mxcl.postgresql@16" => enabled
        \t\t"com.example.old" => true
        \t\t"com.example.legacy" => false
        \t\t"org.example.off" => disabled
        \t}
        garbage line
        """
        let parsed = LaunchItems.parseDisabledServices(output)
        #expect(parsed.count == 6)
        #expect(parsed["com.docker.helper"] == false)
        #expect(parsed["com.apple.Siri.agent"] == true)
        #expect(parsed["homebrew.mxcl.postgresql@16"] == false)
        #expect(parsed["com.example.old"] == true)
        #expect(parsed["com.example.legacy"] == false)
        #expect(parsed["org.example.off"] == true)
        #expect(LaunchItems.parseDisabledServices("").isEmpty)
    }

    @Test func parsesServiceList() {
        let output = """
        gui/501 = {
        \ttype = login
        \tsecurity context = {
        \t\tuid unset
        \t}

        \tservices = {
        \t\t   17072      - \tapplication.net.battle.app.48297725.48297786
        \t\t       0      0 \torg.gpgtools.updater
        \t\t     800      - \torg.gpgtools.macgpg2.shutdown-gpg-agent
        \t\t       0     78 \tcom.example.crashy
        \t}

        \tunmanaged processes = {
        \t\t     123      - \tnot.a.service
        \t}
        }
        """
        let services = LaunchItems.parseServiceList(output)
        #expect(services.count == 4)
        #expect(services["org.gpgtools.macgpg2.shutdown-gpg-agent"] == 800)
        #expect(services["org.gpgtools.updater"] == 0)
        #expect(services["com.example.crashy"] == 0)
        #expect(services["not.a.service"] == nil)
    }

    // MARK: Plist parsing

    @Test func programVersusProgramArguments() throws {
        let explicit = try #require(try item([
            "Label": "com.example.explicit", "Program": "/bin/sh", "ProgramArguments": ["sh", "-c", "true"],
        ]))
        #expect(explicit.program == "/bin/sh")
        #expect(explicit.arguments == ["sh", "-c", "true"])
        #expect(explicit.command == "/bin/sh -c true")
        #expect(explicit.programState == .present)
        #expect(!explicit.isBroken)
        #expect(explicit.status == .on)

        let arguments = try #require(try item(["Label": "com.example.args", "ProgramArguments": ["/bin/echo", "hi"]]))
        #expect(arguments.program == "/bin/echo")
        #expect(arguments.command == "/bin/echo hi")
    }

    @Test func missingProgramIsBroken() throws {
        let broken = try #require(try item([
            "Label": "com.example.gone", "ProgramArguments": ["/nonexistent-\(UUID().uuidString)/tool", "--flag"],
        ]))
        #expect(broken.programState == .missing)
        #expect(broken.isBroken)
        #expect(broken.status == .broken)
        #expect(broken.problem == "Program is missing")

        let noProgram = try #require(try item(["Label": "com.example.empty", "RunAtLoad": true]))
        #expect(noProgram.isBroken)
        #expect(noProgram.problem == "Doesn't say what to run")

        // BundleProgram is relative to an app bundle we can't locate: unknown, never broken.
        let bundleProgram = try #require(try item(["Label": "com.example.bundle", "BundleProgram": "Contents/MacOS/helper"]))
        #expect(bundleProgram.programState == .unknown)
        #expect(!bundleProgram.isBroken)
    }

    @Test func uncertainProgramsAreNeverBroken() {
        #expect(LaunchItems.state(ofProgram: "sh") == .present)
        #expect(LaunchItems.state(ofProgram: "no-such-command-\(UUID().uuidString)") == .unknown)
        #expect(LaunchItems.state(ofProgram: "/Volumes/Not Connected \(UUID().uuidString)/tool") == .unknown)
        #expect(LaunchItems.state(ofProgram: "/bin/sh") == .present)
        #expect(LaunchItems.state(ofProgram: "/nonexistent-\(UUID().uuidString)") == .missing)
    }

    @Test func keepAliveBoolAndDictionary() throws {
        let always = try #require(try item(["Label": "com.example.a", "Program": "/bin/sh", "KeepAlive": true, "RunAtLoad": true]))
        #expect(always.schedule.keepAlive == .always)
        #expect(always.schedule.summary(for: .userAgent) == "Always running")
        #expect(always.schedule.detail == "Keeps itself running")

        let never = try #require(try item(["Label": "com.example.b", "Program": "/bin/sh", "KeepAlive": false, "RunAtLoad": true]))
        #expect(never.schedule.keepAlive == .never)
        #expect(never.schedule.summary(for: .userAgent) == "At login")
        #expect(never.schedule.detail == nil)

        let conditional = try #require(try item([
            "Label": "com.example.c", "Program": "/bin/sh", "KeepAlive": ["SuccessfulExit": false], "RunAtLoad": true,
        ]))
        #expect(conditional.schedule.keepAlive == .conditional)
        #expect(conditional.schedule.summary(for: .systemDaemon) == "At startup")
        #expect(conditional.schedule.detail == "Restarts itself when needed")
    }

    @Test func skipsAppleUnreadableAndUnlabelledFiles() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePlist(["Label": "com.example.keep", "Program": "/bin/sh"], named: "keep.plist", in: directory)
        try writePlist(["Label": "com.apple.Siri.agent", "Program": "/bin/sh"], named: "apple.plist", in: directory)
        try writePlist(["Label": "COM.APPLE.shouty", "Program": "/bin/sh"], named: "apple2.plist", in: directory)
        try writePlist(["Program": "/bin/sh"], named: "nolabel.plist", in: directory)
        try writePlist(["Label": "com.example.text", "Program": "/bin/sh"], named: "notes.txt", in: directory)
        try Data("not a plist".utf8).write(to: directory.appending(path: "garbage.plist"))

        let items = LaunchItems.items(in: directory, domain: .userAgent, resolver: resolver)
        #expect(items.map(\.label) == ["com.example.keep"])
        #expect(items.first?.domain == .userAgent)
        #expect(LaunchItems.items(in: directory.appending(path: "missing"), domain: .userAgent).isEmpty)
    }

    @Test func legacyDisabledKey() throws {
        let off = try #require(try item(["Label": "com.example.off", "Program": "/bin/sh", "Disabled": true]))
        #expect(off.isDisabled)
        #expect(off.status == .off)
    }

    @Test func resolvesOwningApp() throws {
        // From the program path, even when the app is gone.
        let fromPath = try #require(try item([
            "Label": "com.gone.helper", "Program": "/Applications/Gone App \(UUID().uuidString).app/Contents/MacOS/helper",
        ]))
        #expect(fromPath.appName?.hasPrefix("Gone App") == true)
        #expect(fromPath.appURL == nil)
        #expect(fromPath.isBroken)

        // From AssociatedBundleIdentifiers (a string or an array).
        let associated = try #require(try item([
            "Label": "com.vendor.helper", "Program": "/bin/sh", "AssociatedBundleIdentifiers": "com.example.app",
        ]))
        #expect(associated.appURL == exampleApp)
        #expect(associated.appName == "Example")
        #expect(associated.displayName == "Example")
        #expect(associated.associatedBundleIdentifiers == ["com.example.app"])

        let list = try #require(try item([
            "Label": "com.vendor.helper2", "Program": "/bin/sh", "AssociatedBundleIdentifiers": ["com.other", "com.example.app"],
        ]))
        #expect(list.appName == "Example")

        // From a label that starts with the app's bundle ID.
        let byLabel = try #require(try item(["Label": "com.example.app.startuphelper", "Program": "/bin/sh"]))
        #expect(byLabel.appName == "Example")

        // A bare vendor prefix never matches.
        let vendorOnly = LaunchItems.owningApp(program: "/bin/sh", bundleIDs: [], label: "com.example", resolver: { _ in URL(filePath: "/Applications/Wrong.app") })
        #expect(vendorOnly.url == nil)

        let unknown = try #require(try item(["Label": "org.nobody.thing", "Program": "/bin/sh"]))
        #expect(unknown.appName == nil)
        #expect(unknown.displayName == "org.nobody.thing")
    }

    // MARK: Schedules

    @Test func describesIntervals() {
        #expect(LaunchSchedule.describe(interval: 30) == "Every 30 seconds")
        #expect(LaunchSchedule.describe(interval: 60) == "Every minute")
        #expect(LaunchSchedule.describe(interval: 300) == "Every 5 minutes")
        #expect(LaunchSchedule.describe(interval: 90) == "Every 2 minutes")
        #expect(LaunchSchedule.describe(interval: 3_600) == "Every hour")
        #expect(LaunchSchedule.describe(interval: 10_800) == "Every 3 hours")
        #expect(LaunchSchedule.describe(interval: 86_400) == "Once a day")
        #expect(LaunchSchedule.describe(interval: 604_800) == "Every 7 days")
    }

    @Test func describesSchedules() throws {
        #expect(LaunchSchedule(runAtLoad: true, interval: 1_800).summary(for: .userAgent) == "At login, then every 30 minutes")
        #expect(LaunchSchedule(interval: 3_600).summary(for: .systemDaemon) == "Every hour")
        #expect(LaunchSchedule(runAtLoad: true).summary(for: .systemAgent) == "At login")
        #expect(LaunchSchedule(runAtLoad: true).summary(for: .systemDaemon) == "At startup")
        #expect(LaunchSchedule(startsOnDemand: true).summary(for: .userAgent) == "When needed")
        #expect(LaunchSchedule().summary(for: .userAgent) == "When needed")
        #expect(LaunchSchedule(runAtLoad: true, keepAlive: .always, interval: 60).summary(for: .userAgent) == "Always running")

        typealias Entry = LaunchSchedule.CalendarEntry
        #expect(LaunchSchedule(calendar: [Entry(minute: 15, hour: 3)]).summary(for: .userAgent) == "Daily at 03:15")
        #expect(LaunchSchedule(calendar: [Entry(hour: 9, weekday: 1)]).summary(for: .userAgent) == "Every Monday at 09:00")
        #expect(LaunchSchedule(calendar: [Entry(weekday: 0)]).summary(for: .userAgent) == "Every Sunday")
        #expect(LaunchSchedule(calendar: [Entry(minute: 5)]).summary(for: .userAgent) == "Hourly at :05")
        #expect(LaunchSchedule(calendar: [Entry(hour: 2, day: 1)]).summary(for: .userAgent) == "Monthly on day 1 at 02:00")
        #expect(LaunchSchedule(calendar: [Entry(hour: 1), Entry(hour: 13)]).summary(for: .userAgent) == "On a schedule")
        #expect(LaunchSchedule(runAtLoad: true, calendar: [Entry(minute: 0, hour: 4)]).summary(for: .userAgent) == "At login, then daily at 04:00")

        // Parsed from plists: dictionary and array forms.
        let single = try #require(try item(["Label": "com.example.cal", "Program": "/bin/sh", "StartCalendarInterval": ["Hour": 3, "Minute": 15]]))
        #expect(single.schedule.calendar == [Entry(minute: 15, hour: 3)])
        let many = try #require(try item([
            "Label": "com.example.cal2", "Program": "/bin/sh", "StartCalendarInterval": [["Hour": 1], ["Hour": 13]],
        ]))
        #expect(many.schedule.calendar.count == 2)
        let interval = try #require(try item(["Label": "com.example.int", "Program": "/bin/sh", "StartInterval": 600]))
        #expect(interval.schedule.interval == 600)
        #expect(interval.schedule.summary(for: .userAgent) == "Every 10 minutes")
        let watcher = try #require(try item(["Label": "com.example.watch", "Program": "/bin/sh", "WatchPaths": ["/tmp"]]))
        #expect(watcher.schedule.startsOnDemand)
    }

    // MARK: Actions (validation only; nothing is run)

    private func sampleItem(label: String, domain: LaunchItemDomain, home: URL, broken: Bool = false) -> LaunchItem {
        let folder = domain.directory(home: home)
        return LaunchItem(
            label: label, plistURL: folder.appending(path: "\(label).plist"), domain: domain,
            program: "/bin/sh", arguments: [], schedule: LaunchSchedule(runAtLoad: true),
            associatedBundleIdentifiers: [], appURL: nil, appName: nil,
            programState: broken ? .missing : .present, isDisabled: false
        )
    }

    @Test func buildsLaunchctlCommands() {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let agent = sampleItem(label: "com.example.agent", domain: .userAgent, home: home)
        #expect(LaunchItems.commands(for: agent, enable: false, uid: 501) == [
            ["disable", "gui/501/com.example.agent"], ["bootout", "gui/501/com.example.agent"],
        ])
        #expect(LaunchItems.commands(for: agent, enable: true, uid: 501) == [
            ["enable", "gui/501/com.example.agent"], ["bootstrap", "gui/501", "/Users/test/Library/LaunchAgents/com.example.agent.plist"],
        ])

        let systemAgent = sampleItem(label: "com.example.shared", domain: .systemAgent, home: home)
        #expect(LaunchItems.commands(for: systemAgent, enable: false, uid: 501).first == ["disable", "gui/501/com.example.shared"])

        let daemon = sampleItem(label: "com.example.daemon", domain: .systemDaemon, home: home)
        #expect(LaunchItems.commands(for: daemon, enable: true, uid: 501) == [
            ["enable", "system/com.example.daemon"], ["bootstrap", "system", "/Library/LaunchDaemons/com.example.daemon.plist"],
        ])
        #expect(LaunchItemDomain.userAgent.requiresAdministrator == false)
        #expect(LaunchItemDomain.systemAgent.requiresAdministrator)
        #expect(LaunchItemDomain.systemDaemon.requiresAdministrator)
    }

    @Test func refusesUnsafeItems() async throws {
        let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
        let context = LaunchItems.Context(uid: 501, home: home)

        let fine = sampleItem(label: "homebrew.mxcl.postgresql@16", domain: .userAgent, home: home)
        #expect(throws: Never.self) { try LaunchItems.validate(fine, context: context) }

        let apple = sampleItem(label: "com.apple.Siri.agent", domain: .userAgent, home: home)
        #expect(throws: LaunchItemError.self) { try LaunchItems.validate(apple, context: context) }
        await #expect(throws: LaunchItemError.self) { try await LaunchItems.setEnabled(false, apple, allowAdministrator: false, context: context) }
        await #expect(throws: LaunchItemError.self) { try await LaunchItems.remove(apple, allowAdministrator: false, context: context) }

        let shady = sampleItem(label: "x'; rm -rf ~; '", domain: .userAgent, home: home)
        #expect(throws: LaunchItemError.self) { try LaunchItems.validate(shady, context: context) }

        let elsewhere = LaunchItem(
            label: "com.example.elsewhere", plistURL: URL(filePath: "/tmp/com.example.elsewhere.plist"), domain: .userAgent,
            program: "/bin/sh", arguments: [], schedule: LaunchSchedule(), associatedBundleIdentifiers: [],
            appURL: nil, appName: nil, programState: .present, isDisabled: false
        )
        #expect(throws: LaunchItemError.self) { try LaunchItems.validate(elsewhere, context: context) }

        // Only broken items can be removed, and broken items can't be turned on.
        await #expect(throws: LaunchItemError.self) { try await LaunchItems.remove(fine, allowAdministrator: false, context: context) }
        let broken = sampleItem(label: "com.example.broken", domain: .userAgent, home: home, broken: true)
        await #expect(throws: LaunchItemError.self) { try await LaunchItems.setEnabled(true, broken, allowAdministrator: false, context: context) }
    }

    @Test func scanNeverListsAppleItems() async throws {
        // Read-only: lists /Library items plus an empty fake home, and asks launchctl for state.
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let items = await LaunchItems.scan(context: LaunchItems.Context(uid: getuid(), home: home), resolver: { _ in nil })
        #expect(items.allSatisfy { !$0.label.lowercased().hasPrefix("com.apple.") })
        #expect(items.allSatisfy { $0.domain != .userAgent })
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.domain <= $1.domain })
    }
}
