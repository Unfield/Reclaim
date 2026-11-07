import Foundation
import ReclaimCore

enum Style {
    static let enabled = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }

    static func safety(_ level: SafetyLevel) -> String {
        switch level {
        case .safe: green(level.label)
        case .review: yellow(level.label)
        case .caution: red(level.label)
        }
    }

    private static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
}

/// Pads based on visible characters, ignoring ANSI escape codes.
func pad(_ text: String, _ width: Int, alignRight: Bool = false) -> String {
    let visible = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count
    let padding = String(repeating: " ", count: max(0, width - visible))
    return alignRight ? padding + text : text + padding
}

func progressBar(fraction: Double, width: Int = 30) -> String {
    let filled = Int((fraction * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
    if fraction > 0.9 { return Style.red(bar) }
    if fraction > 0.75 { return Style.yellow(bar) }
    return Style.green(bar)
}

func confirm(_ prompt: String) -> Bool {
    print("\(prompt) [y/N] ", terminator: "")
    guard let answer = readLine()?.lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

func status(_ message: String) {
    if Style.enabled { FileHandle.standardError.write(Data("\r\u{1B}[2K\(message)".utf8)) }
}

func clearStatus() {
    if Style.enabled { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
}

func sizeColumn(_ bytes: Int64?, width: Int = 10) -> String {
    pad(bytes.map(ByteSize.format) ?? "—", width, alignRight: true)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((Style.red("error: ") + message + "\n").utf8))
}
