import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public var succeeded: Bool { status == 0 }

    /// A short, human-readable reason for a failure.
    public var failureMessage: String {
        let text = errorOutput.isEmpty ? output : errorOutput
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first { $0.lowercased().hasPrefix("error") } ?? lines.first ?? "exit code \(status)"
    }
}

public enum ShellError: Error, LocalizedError, Sendable {
    case commandNotFound(String)
    case timedOut(String)
    case failed(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .commandNotFound(let name): "Couldn't find the `\(name)` command."
        case .timedOut(let command): "`\(command)` took too long and was stopped."
        case .failed(let command, let message): "`\(command)` failed: \(message)"
        }
    }
}

/// Runs external commands such as `brew`, `docker` and `tmutil`.
public enum Shell {
    /// GUI apps don't inherit the user's shell PATH, so always look in the usual places too.
    static let standardPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    static var searchPaths: [String] {
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (inherited + standardPaths).filter { seen.insert($0).inserted }
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Returns the full path of a command, or nil if it isn't installed.
    public static func find(_ command: String) -> String? {
        let fileManager = FileManager.default
        if command.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: command) ? command : nil
        }
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func run(_ command: String, _ arguments: [String] = [], timeout: TimeInterval = 900) async throws -> ShellResult {
        guard let executable = find(command) else { throw ShellError.commandNotFound(command) }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: {
                    try runBlocking(executable, arguments, timeout: timeout)
                }))
            }
        }
    }

    /// Runs a command as root after macOS asks the user for an administrator password.
    public static func runAsAdministrator(_ command: String, _ arguments: [String], prompt: String? = nil) async throws -> ShellResult {
        guard let executable = find(command) else { throw ShellError.commandNotFound(command) }
        let shellCommand = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        var script = "do shell script \"\(appleScriptEscape(shellCommand))\""
        if let prompt { script += " with prompt \"\(appleScriptEscape(prompt))\"" }
        script += " with administrator privileges"
        return try await run("/usr/bin/osascript", ["-e", script])
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var timedOut = false
        var errorData = Data()
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let state = State()
        let pid = process.processIdentifier
        let timer = DispatchWorkItem {
            state.lock.withLock { state.timedOut = true }
            kill(pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Drain both pipes concurrently so a chatty command can't fill one and deadlock.
        let errorHandle = errorPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let data = errorHandle.readDataToEndOfFile()
            state.lock.withLock { state.errorData = data }
            group.leave()
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        timer.cancel()

        let (timedOut, errorData) = state.lock.withLock { (state.timedOut, state.errorData) }
        if timedOut {
            throw ShellError.timedOut(([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " "))
        }
        return ShellResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
    }
}
