import Foundation

public struct LocalSnapshot: Identifiable, Sendable, Hashable {
    /// Full name, e.g. `com.apple.TimeMachine.2026-11-07-101010.local`.
    public let name: String
    /// The date token `tmutil deletelocalsnapshots` expects, e.g. `2026-11-07-101010`.
    public let dateToken: String
    public let date: Date?

    public var id: String { name }
}

/// Removes Time Machine local snapshots on the startup volume.
public struct TimeMachineTool: MaintenanceTool {
    public let id = "time-machine"
    public let name = "Time Machine Snapshots"
    public let summary = "Local snapshots Time Machine keeps on this Mac between backups."
    public let safety = SafetyLevel.review
    public let options: [ToolOption] = []

    let volume: String

    public init(volume: String = "/") {
        self.volume = volume
    }

    public func snapshots() async throws -> [LocalSnapshot] {
        let result = try await Shell.run("tmutil", ["listlocalsnapshots", volume], timeout: 60)
        guard result.succeeded else { throw ShellError.failed(command: "tmutil listlocalsnapshots", message: result.failureMessage) }
        return Self.parseSnapshots(result.output)
    }

    public func status() async -> ToolStatus {
        guard Shell.find("tmutil") != nil else { return .notInstalled }
        do {
            let snapshots = try await snapshots()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let entries = snapshots.map { snapshot in
                ToolEntry(title: snapshot.date.map(formatter.string(from:)) ?? snapshot.dateToken, detail: snapshot.name)
            }
            return ToolStatus(
                availability: .ready,
                entries: entries,
                note: "macOS doesn't report snapshot sizes. They count as purgeable space and are removed automatically when space runs low."
            )
        } catch {
            return ToolStatus(availability: .unavailable(error.localizedDescription))
        }
    }

    public func clean(options: Set<String>, allowAdministrator: Bool) async throws -> ToolCleanResult {
        try await delete(arguments: ["deletelocalsnapshots", volume], allowAdministrator: allowAdministrator)
    }

    public func delete(_ snapshot: LocalSnapshot, allowAdministrator: Bool) async throws -> ToolCleanResult {
        try await delete(arguments: ["deletelocalsnapshots", snapshot.dateToken], allowAdministrator: allowAdministrator)
    }

    private func delete(arguments: [String], allowAdministrator: Bool) async throws -> ToolCleanResult {
        var result = try await Shell.run("tmutil", arguments, timeout: 600)
        if !result.succeeded && allowAdministrator {
            result = try await Shell.runAsAdministrator(
                "tmutil", arguments, prompt: "Reclaim needs your password to delete Time Machine snapshots."
            )
        }
        guard result.succeeded else {
            throw ShellError.failed(command: "tmutil deletelocalsnapshots", message: result.failureMessage)
        }
        return ToolCleanResult(freed: nil, log: result.output)
    }

    public static func parseSnapshots(_ output: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard let match = name.firstMatch(of: /(\d{4}-\d{2}-\d{2}-\d{6})/) else { return nil }
            let token = String(match.1)
            return LocalSnapshot(name: name, dateToken: token, date: formatter.date(from: token))
        }
    }
}
