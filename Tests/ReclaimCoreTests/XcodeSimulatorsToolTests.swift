import Foundation
import Testing
@testable import ReclaimCore

@Suite struct XcodeSimulatorsToolTests {
    static let devicesJSON = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-16-4" : [
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/AAAA/data",
            "dataPathSize" : 1203961856,
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/AAAA",
            "udid" : "AAAA",
            "isAvailable" : false,
            "availabilityError" : "runtime profile not found using \\"System\\" match policy",
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-14",
            "state" : "Shutdown",
            "name" : "iPhone 14"
          },
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/BBBB/data",
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/BBBB",
            "udid" : "BBBB",
            "isAvailable" : false,
            "availabilityError" : "runtime profile not found",
            "state" : "Shutdown",
            "name" : "iPad Air (5th generation)"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0" : [
          {
            "lastBootedAt" : "2024-01-10T09:12:44Z",
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/CCCC/data",
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/CCCC",
            "udid" : "CCCC",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
            "state" : "Booted",
            "name" : "iPhone 15"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-2" : [
          {
            "dataPath" : "/Users/me/Library/Developer/CoreSimulator/Devices/DDDD/data",
            "logPath" : "/Users/me/Library/Logs/CoreSimulator/DDDD",
            "udid" : "DDDD",
            "isAvailable" : true,
            "state" : "Shutdown",
            "name" : "iPhone 16 Pro"
          },
          { "name" : "broken entry without udid" }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-10-0" : [

        ]
      }
    }
    """

    static let runtimesJSON = """
    {
      "11111111-AAAA-4000-8000-000000000001" : {
        "build" : "21A328",
        "deletable" : true,
        "identifier" : "11111111-AAAA-4000-8000-000000000001",
        "kind" : "Disk Image",
        "lastUsedAt" : "2024-01-10T09:12:44Z",
        "mountPath" : "/Library/Developer/CoreSimulator/Volumes/iOS_21A328",
        "path" : "/Library/Developer/CoreSimulator/Images/11111111-AAAA-4000-8000-000000000001.dmg",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeBundlePath" : "/Library/Developer/CoreSimulator/Volumes/iOS_21A328/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 17.0.simruntime",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-17-0",
        "signatureState" : "Verified",
        "sizeBytes" : 7011510272,
        "state" : "Ready",
        "version" : "17.0"
      },
      "22222222-BBBB-4000-8000-000000000002" : {
        "build" : "22C150",
        "deletable" : true,
        "identifier" : "22222222-BBBB-4000-8000-000000000002",
        "kind" : "Disk Image",
        "lastUsedAt" : "2025-02-01T10:00:00.123Z",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-2",
        "sizeBytes" : 8500000000,
        "state" : "Ready",
        "version" : "18.2"
      },
      "33333333-CCCC-4000-8000-000000000003" : {
        "build" : "21R355",
        "deletable" : true,
        "identifier" : "33333333-CCCC-4000-8000-000000000003",
        "kind" : "Disk Image",
        "platformIdentifier" : "com.apple.platform.watchsimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-10-0",
        "sizeBytes" : 3500000000,
        "state" : "Ready",
        "version" : "10.0"
      },
      "44444444-DDDD-4000-8000-000000000004" : {
        "build" : "21A5248v",
        "deletable" : false,
        "identifier" : "44444444-DDDD-4000-8000-000000000004",
        "kind" : "Bundled with Xcode",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-16-4",
        "sizeBytes" : 6000000000,
        "state" : "Ready",
        "version" : "16.4"
      },
      "55555555-EEEE-4000-8000-000000000005" : {
        "identifier" : "55555555-EEEE-4000-8000-000000000005",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-15-5",
        "sizeBytes" : 5000000000,
        "state" : "Deleting",
        "deletable" : true,
        "version" : "15.5"
      }
    }
    """

    // MARK: Parsing

    @Test func parsesDevices() throws {
        let devices = try #require(XcodeSimulatorsTool.parseDevices(Self.devicesJSON))
        #expect(devices.map(\.udid) == ["AAAA", "BBBB", "CCCC", "DDDD"])
        let first = devices[0]
        #expect(first.name == "iPhone 14")
        #expect(first.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-16-4")
        #expect(!first.isAvailable)
        #expect(first.availabilityError?.hasPrefix("runtime profile not found") == true)
        #expect(first.dataPath == "/Users/me/Library/Developer/CoreSimulator/Devices/AAAA/data")
        #expect(first.logPath == "/Users/me/Library/Logs/CoreSimulator/AAAA")
        #expect(devices[2].isAvailable && devices[2].state == "Booted")
    }

    @Test func parsesLegacyAndOddDeviceFormats() throws {
        let legacy = """
        xcrun: warning: something noisy
        {"devices": {"iOS 12.1": [
          {"state": "Shutdown", "availability": "(unavailable, runtime profile not found)", "name": "iPhone X", "udid": "OLD1"},
          {"state": "Shutdown", "availability": "(available)", "name": "iPhone XS", "udid": "OLD2"},
          {"state": "Shutdown", "isAvailable": "NO", "name": "iPhone 8", "udid": "OLD3"},
          {"state": "Shutdown", "name": "Mystery", "udid": "OLD4"}
        ]}}
        """
        let devices = try #require(XcodeSimulatorsTool.parseDevices(legacy))
        #expect(devices.map(\.isAvailable) == [false, true, false, true])
        #expect(devices[0].dataPath == nil)

        #expect(XcodeSimulatorsTool.parseDevices("") == nil)
        #expect(XcodeSimulatorsTool.parseDevices("not json") == nil)
        #expect(XcodeSimulatorsTool.parseDevices("{\"runtimes\": []}") == nil)
        #expect(XcodeSimulatorsTool.parseDevices("{\"devices\": {}}") == [])
    }

    @Test func parsesRuntimes() throws {
        let runtimes = try #require(XcodeSimulatorsTool.parseRuntimes(Self.runtimesJSON))
        #expect(runtimes.count == 5)
        let ios17 = try #require(runtimes.first { $0.version == "17.0" })
        #expect(ios17.identifier == "11111111-AAAA-4000-8000-000000000001")
        #expect(ios17.sizeBytes == 7_011_510_272)
        #expect(ios17.isDeletable)
        #expect(ios17.platformIdentifier == "com.apple.platform.iphonesimulator")
        #expect(ios17.lastUsedAt == Date(timeIntervalSince1970: 1_704_877_964))
        #expect(ios17.displayName == "iOS 17.0")
        #expect(runtimes.first { $0.version == "18.2" }?.lastUsedAt != nil) // fractional seconds
        #expect(runtimes.first { $0.version == "16.4" }?.isDeletable == false)

        #expect(XcodeSimulatorsTool.parseRuntimes("Unrecognized subcommand: runtime") == nil)
        #expect(XcodeSimulatorsTool.parseRuntimes("{}") == [])
        // Unknown shapes inside are skipped rather than failing the whole list.
        #expect(XcodeSimulatorsTool.parseRuntimes("{\"x\": 3, \"y\": {\"sizeBytes\": \"12\"}}")?.map(\.sizeBytes) == [12])
    }

    @Test func picksRemovableRuntimes() throws {
        let devices = try #require(XcodeSimulatorsTool.parseDevices(Self.devicesJSON))
        let runtimes = try #require(XcodeSimulatorsTool.parseRuntimes(Self.runtimesJSON))
        let removable = XcodeSimulatorsTool.removableRuntimes(runtimes, devices: devices)
        // watchOS 10.0: no simulators. Not offered: iOS 17.0 and 18.2 (used by simulators),
        // iOS 16.4 (not deletable), iOS 15.5 (already being deleted).
        #expect(removable.map(\.displayName) == ["watchOS 10.0"])
    }

    @Test func helpers() {
        #expect(XcodeSimulatorsTool.compareVersions("17.10", "17.9") == .orderedDescending)
        #expect(XcodeSimulatorsTool.compareVersions("18", "18.0") == .orderedSame)
        #expect(XcodeSimulatorsTool.compareVersions("16.4", "17.0") == .orderedAscending)
        #expect(XcodeSimulatorsTool.platformName(fromRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-0") == "iOS 17.0")
        #expect(XcodeSimulatorsTool.platformName(fromRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-1") == "visionOS 2.1")
        #expect(XcodeSimulatorsTool.platformName(fromRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == "iOS 27.2")
        #expect(XcodeSimulatorsTool.platformName(fromRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-beta") == nil)
        #expect(XcodeSimulatorsTool.platformName(fromRuntimeIdentifier: "iOS 12.1") == nil)
    }

    // MARK: Status and cleaning with a fake simctl

    /// Records commands and answers them from a table, standing in for `xcrun`.
    final class FakeShell: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        private var responses: [String: ShellResult]

        init(_ responses: [String: ShellResult]) {
            self.responses = responses
        }

        var commands: [String] { lock.withLock { calls } }

        func set(_ command: String, _ result: ShellResult) {
            lock.withLock { responses[command] = result }
        }

        func run(_ command: String, _ arguments: [String]) -> ShellResult {
            let line = ([command] + arguments).joined(separator: " ")
            return lock.withLock {
                calls.append(line)
                return responses[line] ?? ShellResult(status: 0, output: "", errorOutput: "")
            }
        }

        func tool(sizes: [String: Int64] = [:]) -> XcodeSimulatorsTool {
            XcodeSimulatorsTool(run: { command, arguments, _ in self.run(command, arguments) }, measure: { sizes[$0] })
        }
    }

    static func ok(_ output: String) -> ShellResult { ShellResult(status: 0, output: output, errorOutput: "") }
    static func failure(_ message: String) -> ShellResult { ShellResult(status: 1, output: "", errorOutput: message) }

    @Test func notInstalledWithoutXcode() async {
        let commandLineToolsOnly = FakeShell([
            "xcode-select -p": Self.ok("/Library/Developer/CommandLineTools\n"),
            "xcrun simctl help": Self.failure("xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH"),
        ])
        #expect(await commandLineToolsOnly.tool().status().availability == .notInstalled)

        // With no developer tools at all, `xcrun` must not run (it would show an install dialog).
        let nothing = FakeShell(["xcode-select -p": Self.failure("xcode-select: error: unable to get active developer directory")])
        #expect(await nothing.tool().status().availability == .notInstalled)
        #expect(nothing.commands == ["xcode-select -p"])
    }

    @Test func statusListsEntries() async {
        let shell = FakeShell([
            "xcrun simctl list devices --json": Self.ok(Self.devicesJSON),
            "xcrun simctl runtime list --json": Self.ok(Self.runtimesJSON),
        ])
        let sizes: [String: Int64] = [
            "/Users/me/Library/Developer/CoreSimulator/Devices/AAAA/data": 1_000,
            "/Users/me/Library/Logs/CoreSimulator/AAAA": 50,
            "/Users/me/Library/Developer/CoreSimulator/Devices/BBBB/data": 2_000,
            "/Users/me/Library/Developer/CoreSimulator/Devices/CCCC/data": 30_000,
            "/Users/me/Library/Developer/CoreSimulator/Devices/DDDD/data": 40_000,
        ]
        let status = await shell.tool(sizes: sizes).status()
        #expect(status.availability == .ready)
        #expect(status.entries.map(\.title) == ["Unavailable simulators", "Unused simulator runtimes", "Simulator data"])
        #expect(status.entries[0].size == 3_050)
        #expect(status.entries[0].detail == "2 devices: iPhone 14 (iOS 16.4), iPad Air (5th generation) (iOS 16.4)")
        #expect(status.entries[0].optionID == nil)
        #expect(status.entries.count == 3)
        #expect(status.entries[1].size == 3_500_000_000) // watchOS 10.0
        #expect(status.entries[1].detail == "watchOS 10.0")
        #expect(status.entries[1].optionID == "runtimes")
        #expect(status.entries[2].size == 70_000)
        #expect(status.entries[2].optionID == "erase-all")
        #expect(status.reclaimable(options: []) == 3_050)

        let tool = XcodeSimulatorsTool()
        #expect(tool.defaultOptions.isEmpty)
        #expect(Set(tool.options.map(\.id)) == ["runtimes", "erase-all"])
    }

    @Test func statusWithoutRuntimeSupport() async {
        let shell = FakeShell([
            "xcrun simctl list devices --json": Self.ok(Self.devicesJSON),
            "xcrun simctl runtime list --json": Self.failure("Unrecognized subcommand: runtime"),
        ])
        let status = await shell.tool().status()
        #expect(status.entries.map(\.title) == ["Unavailable simulators", "Simulator data"])
        #expect(status.entries[0].size == nil) // nothing measurable on disk

        let broken = FakeShell(["xcrun simctl list devices --json": Self.failure("CoreSimulatorService connection became invalid")])
        #expect(await broken.tool().status().availability == .unavailable("`xcrun simctl list devices` failed: CoreSimulatorService connection became invalid"))
    }

    @Test func cleanDeletesUnavailableByDefault() async throws {
        let shell = FakeShell([
            "xcrun simctl list devices --json": Self.ok(Self.devicesJSON),
            "xcrun simctl runtime list --json": Self.ok(Self.runtimesJSON),
        ])
        let result = try await shell.tool().clean(options: [], allowAdministrator: false)
        #expect(shell.commands == ["xcrun simctl list devices --json", "xcrun simctl delete unavailable"])
        #expect(result.freed == 0)
        #expect(result.log.contains("delete unavailable"))
    }

    @Test func cleanWithAllOptions() async throws {
        let shell = FakeShell([
            "xcrun simctl list devices --json": Self.ok(Self.devicesJSON),
            "xcrun simctl runtime list --json": Self.ok(Self.runtimesJSON),
            "xcrun simctl runtime delete 33333333-CCCC-4000-8000-000000000003": Self.failure("Unable to delete runtime"),
        ])
        let result = try await shell.tool().clean(options: ["runtimes", "erase-all"], allowAdministrator: false)
        #expect(shell.commands == [
            "xcrun simctl runtime list --json",
            "xcrun simctl list devices --json",
            "xcrun simctl runtime delete 33333333-CCCC-4000-8000-000000000003",
            "xcrun simctl list devices --json",
            "xcrun simctl delete unavailable",
            "xcrun simctl list devices --json",
            "xcrun simctl shutdown all",
            "xcrun simctl erase all",
        ])
        // A runtime that fails to delete is logged, skipped and not counted.
        #expect(result.freed == 0)
        #expect(result.log.contains("Couldn't delete watchOS 10.0"))
    }

    @Test func cleanFailsWhenDeleteFails() async {
        let shell = FakeShell([
            "xcrun simctl list devices --json": Self.ok(Self.devicesJSON),
            "xcrun simctl delete unavailable": Self.failure("error: CoreSimulator is out of date"),
        ])
        await #expect(throws: ShellError.self) {
            try await shell.tool().clean(options: [], allowAdministrator: false)
        }
    }
}
