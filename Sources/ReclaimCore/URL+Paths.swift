import Foundation

extension URL {
    /// Standardized file-system path without a trailing slash, suitable for comparisons.
    public var normalizedPath: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Path with the home directory replaced by `~`, for display.
    public var abbreviatedPath: String {
        (normalizedPath as NSString).abbreviatingWithTildeInPath
    }
}
