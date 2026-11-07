import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let historyUsage = """
  reclaim history                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let historyOptionsWithValues: Set<String> = []

func runHistory(_ args: Arguments) async throws {
    throw UsageError("`reclaim history` isn't implemented yet")
}
