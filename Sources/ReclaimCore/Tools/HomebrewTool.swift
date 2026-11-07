import Foundation

/// Cleans Homebrew's download cache and old formula/cask versions via `brew cleanup`.
public struct HomebrewTool: MaintenanceTool {
    public let id = "homebrew"
    public let name = "Homebrew"
    public let summary = String(localized: "Downloaded bottles and casks, plus old versions of installed packages.")
    public let safety = SafetyLevel.safe
    public let options = [
        ToolOption(
            id: "autoremove",
            title: String(localized: "Remove unneeded dependencies"),
            detail: String(localized: "Uninstalls formulae that were only installed as dependencies and are no longer needed."),
            isEnabledByDefault: false,
            safety: .review
        ),
    ]

    static let cleanupArguments = ["cleanup", "-s", "--prune=all"]

    public init() {}

    public func status() async -> ToolStatus {
        guard Shell.find("brew") != nil else { return .notInstalled }
        do {
            let cleanup = try await Shell.run("brew", Self.cleanupArguments + ["--dry-run"], timeout: 300)
            guard cleanup.succeeded else {
                return ToolStatus(availability: .unavailable(cleanup.failureMessage))
            }
            var entries = Self.parseCleanupDryRun(cleanup.output, cachePath: await Self.cachePath())

            if let autoremove = try? await Shell.run("brew", ["autoremove", "--dry-run"], timeout: 300), autoremove.succeeded {
                let formulae = Self.parseAutoremoveDryRun(autoremove.output)
                if !formulae.isEmpty {
                    entries.append(ToolEntry(
                        title: String(localized: "Unneeded dependencies"),
                        detail: formulae.joined(separator: ", "),
                        optionID: "autoremove"
                    ))
                }
            }
            return ToolStatus(availability: .ready, entries: entries)
        } catch {
            return ToolStatus(availability: .unavailable(error.localizedDescription))
        }
    }

    public func clean(options: Set<String>, allowAdministrator: Bool) async throws -> ToolCleanResult {
        var log = ""
        if options.contains("autoremove") {
            let result = try await Shell.run("brew", ["autoremove"])
            log += result.output
            guard result.succeeded else { throw ShellError.failed(command: "brew autoremove", message: result.failureMessage) }
        }
        let result = try await Shell.run("brew", Self.cleanupArguments)
        log += result.output
        guard result.succeeded else { throw ShellError.failed(command: "brew cleanup", message: result.failureMessage) }
        return ToolCleanResult(freed: Self.parseFreedSpace(result.output), log: log)
    }

    static func cachePath() async -> String? {
        guard let result = try? await Shell.run("brew", ["--cache"], timeout: 60), result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Parsing

    /// Groups `brew cleanup --dry-run` output into download cache, old versions and everything else.
    static func parseCleanupDryRun(_ output: String, cachePath: String?) -> [ToolEntry] {
        var cache: (count: Int, bytes: Int64) = (0, 0)
        var versions: (count: Int, bytes: Int64) = (0, 0)
        var other: (count: Int, bytes: Int64) = (0, 0)

        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("Would remove: "), let (path, size) = parseRemovalLine(String(line)) else { continue }
            if let cachePath, path.hasPrefix(cachePath) {
                cache.count += 1; cache.bytes += size
            } else if path.contains("/Cellar/") || path.contains("/Caskroom/") {
                versions.count += 1; versions.bytes += size
            } else {
                other.count += 1; other.bytes += size
            }
        }

        var entries = [ToolEntry]()
        if cache.count > 0 {
            entries.append(ToolEntry(title: String(localized: "Download cache"), detail: String(localized: "\(cache.count) files"), size: cache.bytes))
        }
        if versions.count > 0 {
            entries.append(ToolEntry(title: String(localized: "Old versions"), detail: String(localized: "\(versions.count) packages"), size: versions.bytes))
        }
        if other.count > 0 {
            entries.append(ToolEntry(title: String(localized: "Other files"), detail: String(localized: "\(other.count) items"), size: other.bytes))
        }
        return entries
    }

    /// Parses `Would remove: /path (12 files, 34.6MB)` or `Would remove: /path (34.6MB)`.
    static func parseRemovalLine(_ line: String) -> (path: String, bytes: Int64)? {
        let body = line.dropFirst("Would remove: ".count)
        guard body.hasSuffix(")"), let open = body.lastIndex(of: "(") else { return nil }
        let path = body[..<open].trimmingCharacters(in: .whitespaces)
        let inside = body[body.index(after: open)..<body.index(before: body.endIndex)]
        let sizeText = inside.split(separator: ",").last.map(String.init) ?? ""
        guard let bytes = ByteSize.parse(sizeText, binary: true) else { return nil }
        return (path, bytes)
    }

    /// Parses `==> This operation has freed approximately 1.2GB of disk space.`
    static func parseFreedSpace(_ output: String) -> Int64? {
        let pattern = /approximately\s+([0-9.]+\s*[KMGT]?B)/
        guard let match = output.firstMatch(of: pattern) else { return 0 }
        return ByteSize.parse(String(match.1), binary: true)
    }

    /// `brew autoremove --dry-run` prints a header followed by one formula per line.
    static func parseAutoremoveDryRun(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
    }
}
