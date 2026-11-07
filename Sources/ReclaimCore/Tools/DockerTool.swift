import Foundation

/// Prunes unused Docker data via the `docker` CLI. Works with Docker Desktop, OrbStack, Colima, etc.
public struct DockerTool: MaintenanceTool {
    public let id = "docker"
    public let name = "Docker"
    public let summary = String(localized: "Stopped containers, unused images, build cache and volumes.")
    public let safety = SafetyLevel.review
    public let options = [
        ToolOption(
            id: "build-cache",
            title: String(localized: "Build cache"),
            detail: String(localized: "Layers cached by `docker build`. Rebuilt on the next build."),
            isEnabledByDefault: true,
            safety: .safe
        ),
        ToolOption(
            id: "all-images",
            title: String(localized: "All unused images"),
            detail: String(localized: "Images not used by any container, not just dangling ones. They'll be pulled again when needed."),
            isEnabledByDefault: false,
            safety: .review
        ),
        ToolOption(
            id: "volumes",
            title: String(localized: "Unused volumes"),
            detail: String(localized: "Volumes not attached to any container. These can contain databases and other data."),
            isEnabledByDefault: false,
            safety: .caution
        ),
    ]

    public init() {}

    public func status() async -> ToolStatus {
        guard Shell.find("docker") != nil else { return .notInstalled }
        do {
            let result = try await Shell.run("docker", ["system", "df", "--format", "{{json .}}"], timeout: 60)
            guard result.succeeded else {
                let message = result.errorOutput.contains("Cannot connect")
                    ? String(localized: "Docker isn't running. Start it to measure and clean.")
                    : result.failureMessage
                return ToolStatus(availability: .unavailable(message))
            }
            return ToolStatus(
                availability: .ready,
                entries: Self.parseSystemDF(result.output),
                note: String(localized: "Docker Desktop's disk image shrinks gradually after pruning.")
            )
        } catch {
            return ToolStatus(availability: .unavailable(error.localizedDescription))
        }
    }

    public func clean(options: Set<String>, allowAdministrator: Bool) async throws -> ToolCleanResult {
        var log = ""
        var freed: Int64 = 0

        func run(_ arguments: [String]) async throws {
            let result = try await Shell.run("docker", arguments)
            log += result.output
            guard result.succeeded else {
                throw ShellError.failed(command: "docker " + arguments.prefix(2).joined(separator: " "), message: result.failureMessage)
            }
            freed += Self.parseReclaimed(result.output) ?? 0
        }

        var prune = ["system", "prune", "--force"]
        if options.contains("all-images") { prune.append("--all") }
        if options.contains("volumes") { prune.append("--volumes") }
        try await run(prune)

        if options.contains("build-cache") {
            try await run(["builder", "prune", "--all", "--force"])
        }
        return ToolCleanResult(freed: freed, log: log)
    }

    // MARK: Parsing

    private struct DFRow: Decodable {
        let type: String
        let totalCount: String
        let active: String
        let reclaimable: String

        enum CodingKeys: String, CodingKey {
            case type = "Type", totalCount = "TotalCount", active = "Active", reclaimable = "Reclaimable"
        }
    }

    /// Parses `docker system df --format '{{json .}}'`, one JSON object per line.
    static func parseSystemDF(_ output: String) -> [ToolEntry] {
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let row = try? decoder.decode(DFRow.self, from: Data(line.utf8)) else { return nil }
            // "1.2GB (50%)" -> "1.2GB"
            let sizeText = row.reclaimable.split(separator: " ").first.map(String.init) ?? ""
            let size = ByteSize.parse(sizeText) ?? 0
            let unused = (Int(row.totalCount) ?? 0) - (Int(row.active) ?? 0)

            switch row.type {
            case "Images":
                return ToolEntry(title: String(localized: "Unused images"), detail: String(localized: "\(max(0, unused)) of \(row.totalCount)"), size: size, optionID: "all-images")
            case "Containers":
                return ToolEntry(title: String(localized: "Stopped containers"), detail: String(localized: "\(max(0, unused)) of \(row.totalCount)"), size: size)
            case "Local Volumes":
                return ToolEntry(title: String(localized: "Unused volumes"), detail: String(localized: "\(max(0, unused)) of \(row.totalCount)"), size: size, optionID: "volumes")
            case "Build Cache":
                return ToolEntry(title: String(localized: "Build cache"), detail: String(localized: "\(row.totalCount) entries"), size: size, optionID: "build-cache")
            default:
                return ToolEntry(title: row.type, size: size)
            }
        }
    }

    /// Parses `Total reclaimed space: 1.2GB`.
    static func parseReclaimed(_ output: String) -> Int64? {
        guard let match = output.firstMatch(of: /Total reclaimed space:\s*([0-9.]+\s*[kKMGT]?B)/) else { return nil }
        return ByteSize.parse(String(match.1))
    }
}
