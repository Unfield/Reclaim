import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let projectsUsage = """
  reclaim projects                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let projectsOptionsWithValues: Set<String> = []

func runProjects(_ args: Arguments) async throws {
    throw UsageError("`reclaim projects` isn't implemented yet")
}
