import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let duplicatesUsage = """
  reclaim duplicates                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let duplicatesOptionsWithValues: Set<String> = []

func runDuplicates(_ args: Arguments) async throws {
    throw UsageError("`reclaim duplicates` isn't implemented yet")
}
