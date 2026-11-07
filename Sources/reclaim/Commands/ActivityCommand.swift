import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let cpuUsage = """
  reclaim cpu                       (coming soon)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let cpuOptionsWithValues: Set<String> = []

func runCpu(_ args: Arguments) async throws {
    throw UsageError("`reclaim cpu` isn't implemented yet")
}
