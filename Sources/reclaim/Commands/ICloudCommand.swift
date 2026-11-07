import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let icloudUsage = """
  reclaim icloud                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let icloudOptionsWithValues: Set<String> = []

func runIcloud(_ args: Arguments) async throws {
    throw UsageError("`reclaim icloud` isn't implemented yet")
}
