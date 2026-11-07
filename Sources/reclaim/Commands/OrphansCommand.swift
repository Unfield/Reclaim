import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let leftoversUsage = """
  reclaim leftovers                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let leftoversOptionsWithValues: Set<String> = []

func runLeftovers(_ args: Arguments) async throws {
    throw UsageError("`reclaim leftovers` isn't implemented yet")
}
