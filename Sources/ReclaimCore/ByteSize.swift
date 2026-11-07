import Foundation

public enum ByteSize {
    /// Formats a byte count the way Finder does (decimal units).
    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Parses human-friendly sizes such as `500MB`, `1.5g`, `200k` or plain byte counts.
    /// Uses decimal units to match Finder and `format(_:)`, unless `binary` is set
    /// (Homebrew, for example, reports `MB` but means MiB).
    public static func parse(_ text: String, binary: Bool = false) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        let unitPart = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(numberPart), value >= 0 else { return nil }

        let exponent: Double
        switch unitPart {
        case "", "b": exponent = 0
        case "k", "kb": exponent = 1
        case "m", "mb": exponent = 2
        case "g", "gb": exponent = 3
        case "t", "tb": exponent = 4
        default: return nil
        }
        let multiplier = pow(binary ? 1024 : 1000, exponent)
        return Int64((value * multiplier).rounded())
    }
}
