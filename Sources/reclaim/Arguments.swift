import Foundation

/// Minimal argument parser: positional values plus `--flag` and `--option value` / `--option=value`.
struct Arguments {
    private(set) var positionals: [String] = []
    private var flags: Set<String> = []
    private var options: [String: String] = [:]

    init(_ raw: [String], optionsWithValues: Set<String>) throws {
        var iterator = raw.makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if optionsWithValues.contains(body) {
                    guard let value = iterator.next() else { throw UsageError("--\(body) needs a value") }
                    options[body] = value
                } else {
                    flags.insert(body)
                }
            } else if arg.hasPrefix("-"), arg.count > 1 {
                // Short flags like -y or -n, possibly combined (-yn).
                for ch in arg.dropFirst() { flags.insert(String(ch)) }
            } else {
                positionals.append(arg)
            }
        }
    }

    func has(_ names: String...) -> Bool { names.contains { flags.contains($0) } }
    func value(_ name: String) -> String? { options[name] }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
