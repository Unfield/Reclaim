import Foundation

/// A switch that changes what a tool cleans, e.g. Docker's "remove all unused images".
public struct ToolOption: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let detail: String
    public let isEnabledByDefault: Bool
    public let safety: SafetyLevel

    public init(id: String, title: String, detail: String, isEnabledByDefault: Bool, safety: SafetyLevel) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isEnabledByDefault = isEnabledByDefault
        self.safety = safety
    }
}

/// One line in a tool's breakdown, such as "Build cache: 20 GB".
public struct ToolEntry: Identifiable, Sendable, Hashable {
    public let title: String
    public let detail: String?
    public let size: Int64?
    /// When set, this entry is only cleaned if the option is enabled.
    public let optionID: String?

    public init(title: String, detail: String? = nil, size: Int64? = nil, optionID: String? = nil) {
        self.title = title
        self.detail = detail
        self.size = size
        self.optionID = optionID
    }

    public var id: String { title + (detail ?? "") }
}

public struct ToolStatus: Sendable {
    public enum Availability: Sendable, Equatable {
        case notInstalled
        /// Installed but can't be used right now (e.g. the Docker daemon isn't running).
        case unavailable(String)
        case ready
    }

    public let availability: Availability
    public let entries: [ToolEntry]
    public let note: String?

    public init(availability: Availability, entries: [ToolEntry] = [], note: String? = nil) {
        self.availability = availability
        self.entries = entries
        self.note = note
    }

    public static let notInstalled = ToolStatus(availability: .notInstalled)

    public var isReady: Bool { availability == .ready }

    /// Known reclaimable bytes with the given options enabled, or nil if no entry reports a size.
    public func reclaimable(options: Set<String>) -> Int64? {
        let sizes = entries
            .filter { $0.optionID.map(options.contains) ?? true }
            .compactMap(\.size)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

public struct ToolCleanResult: Sendable {
    /// Bytes freed, if the tool reports it.
    public let freed: Int64?
    public let log: String

    public init(freed: Int64?, log: String) {
        self.freed = freed
        self.log = log
    }
}

/// A cleanup that is performed by an external tool (Homebrew, Docker, tmutil) rather than by deleting files directly.
public protocol MaintenanceTool: Sendable {
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    var safety: SafetyLevel { get }
    var options: [ToolOption] { get }

    func status() async -> ToolStatus
    /// - Parameter allowAdministrator: Whether the tool may ask for an administrator password if needed.
    func clean(options: Set<String>, allowAdministrator: Bool) async throws -> ToolCleanResult
}

extension MaintenanceTool {
    public var defaultOptions: Set<String> {
        Set(options.filter(\.isEnabledByDefault).map(\.id))
    }
}

public enum ToolCatalog {
    public static func all() -> [any MaintenanceTool] {
        [HomebrewTool(), DockerTool(), XcodeSimulatorsTool(), TimeMachineTool()]
    }

    public static func tool(withID id: String) -> (any MaintenanceTool)? {
        all().first { $0.id == id }
    }
}
