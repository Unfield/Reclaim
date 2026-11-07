import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let modelsUsage = """
  reclaim models                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let modelsOptionsWithValues: Set<String> = []

func runModels(_ args: Arguments) async throws {
    throw UsageError("`reclaim models` isn't implemented yet")
}
