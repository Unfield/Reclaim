import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let cpuUsage = """
  reclaim cpu                        Show CPU use, temperature and the busiest apps
      --limit <n>                    Number of apps to list (default: 10)
"""

/// Options of this command that take a value (e.g. `--days 30`).
let cpuOptionsWithValues: Set<String> = []

func runCpu(_ args: Arguments) async throws {
    let limit = try parseLimit(args, default: 10)
    status("Measuring CPU use…")
    let report = await CPUMonitor.sample()
    clearStatus()

    let info = CPUMonitor.info()
    print(Style.bold("CPU") + Style.dim("  \(info.summary)"))
    if let load = report.load {
        print("  \(progressBar(fraction: load.total))  \(percent(load.total * 100)) in use")
        print("  User          \(pad(percent(load.user * 100), 6, alignRight: true))  \(Style.dim("apps"))")
        print("  System        \(pad(percent(load.system * 100), 6, alignRight: true))  \(Style.dim("macOS itself"))")
        print("  Idle          \(pad(percent(load.idle * 100), 6, alignRight: true))")
    }

    let thermal = CPUMonitor.thermalLevel
    let thermalLabel: String
    switch thermal {
    case .nominal: thermalLabel = Style.green(thermal.label)
    case .fair: thermalLabel = Style.yellow(thermal.label)
    case .serious, .critical: thermalLabel = Style.red(thermal.label)
    }
    print("  Temperature   \(thermalLabel)  \(Style.dim(thermal.explanation))")
    if CPUMonitor.isLowPowerModeEnabled {
        print("  Low Power Mode is on  \(Style.dim("(your Mac trades some speed for battery life)"))")
    }

    let groups = report.groups.prefix(limit)
    guard !groups.isEmpty else { return }
    print(Style.bold("\nUsing the most CPU") + Style.dim("  (100% = one core)"))
    for group in groups {
        let count = group.processCount > 1 ? Style.dim(" (\(group.processCount) processes)") : ""
        let power = report.hasEnergyData ? "  " + pad(Style.dim(formatPower(group.power ?? 0)), 8, alignRight: true) : ""
        print("  \(pad(percent(group.cpu), 7, alignRight: true))\(power)  \(group.name)\(count)")
    }
    print(Style.dim("\nApps sitting near 0% are idle and cost nothing. Quit apps that stay high while you aren't using them."))
}

private func percent(_ value: Double) -> String { CPUMonitor.formatPercent(value) }
private func formatPower(_ watts: Double) -> String { CPUMonitor.formatPower(watts) }
