import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let loginItemsUsage = """
  reclaim login-items                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let loginItemsOptionsWithValues: Set<String> = []

func runLoginItems(_ args: Arguments) async throws {
    throw UsageError("`reclaim login-items` isn't implemented yet")
}
