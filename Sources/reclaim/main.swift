import AppKit
import Foundation
import ReclaimCore

let usage = """
\(Style.bold("reclaim")) — find and clean up disk space on macOS

\(Style.bold("USAGE"))
  reclaim status                     Show usage for all mounted disks
  reclaim list                       List cleanup categories and tools
  reclaim scan [id...]               Measure reclaimable space (everything by default)
      --details                      Show the largest items in each category
  reclaim clean <id...>              Clean categories and/or tools (homebrew, docker, time-machine)
      --all-safe                     Clean everything marked Safe
      --delete                       Delete files permanently instead of moving to Trash
      --admin                        Allow asking for an administrator password if needed
      --<option>, --no-<option>      Turn tool options on/off, e.g. --all-images, --volumes
      -n, --dry-run                  Show what would be removed without removing it
      -y, --yes                      Don't ask for confirmation
  reclaim apps                       List apps you haven't used recently
      --days <n>                     Unused for at least n days (default: 90)
      --all                          List all apps, largest first
  reclaim uninstall <app>            Move an app and its support files to the Trash
      --keep-data                    Only remove the app, not its support files
      -n, --dry-run / -y, --yes
  reclaim memory                     Show memory usage, pressure and the heaviest apps
      --limit <n>                    Number of apps to list (default: 10)
      --purge                        Clear file caches with `purge` (needs sudo or --admin)
  reclaim explore [path]             Show what's using space in a folder (default: home)
      --limit <n>                    Maximum number of results (default: 25)
  reclaim large [path]               Find the largest files (default: home folder; may be a disk, e.g. /Volumes/X)
      --min <size>                   Minimum size, e.g. 500MB, 2GB (default: 100MB)
      --limit <n>                    Maximum number of results (default: 25)
      --hidden                       Include hidden files and folders

\(Style.bold("MORE TOOLS"))
\(projectsUsage)
\(leftoversUsage)
\(duplicatesUsage)
\(modelsUsage)
\(icloudUsage)
\(cpuUsage)
\(loginItemsUsage)
\(historyUsage)
  reclaim undo                       Put back the last items Reclaim moved to the Trash
      --list                         Show what can be put back
  reclaim exclude [path]             Never clean this path (no path: list exclusions)
      --remove                       Remove the path from the exclusion list

  reclaim --version                  Print the version

Tip: grant your terminal Full Disk Access (System Settings → Privacy & Security)
for complete results.

\(ReclaimInfo.repositoryURL.absoluteString)
"""

// MARK: - status / list

func runStatus() throws {
    let volumes = VolumeInfo.mounted()
    guard !volumes.isEmpty else { throw UsageError("couldn't read any disks") }
    for (index, volume) in volumes.enumerated() {
        if index > 0 { print() }
        let kind: String
        switch volume.kind {
        case .startup: kind = "startup disk"
        case .internalDisk: kind = "internal"
        case .external: kind = "external"
        case .network: kind = "network"
        case .diskImage: kind = "disk image"
        }
        let details = [kind, volume.format, volume.isReadOnly ? "read-only" : nil].compactMap { $0 }.joined(separator: ", ")
        print(Style.bold(volume.name) + Style.dim("  \(volume.url.normalizedPath) (\(details))"))
        print("  \(progressBar(fraction: volume.usedFraction))  \(Int(volume.usedFraction * 100))% used")
        print("  Used       \(ByteSize.format(volume.usedCapacity))")
        let purgeable = volume.purgeableCapacity > 0 ? Style.dim(" (includes \(ByteSize.format(volume.purgeableCapacity)) purgeable)") : ""
        print("  Available  \(ByteSize.format(volume.availableForImportantUsage))\(purgeable)")
        print("  Capacity   \(ByteSize.format(volume.totalCapacity))")
    }
}

func runList() {
    let categories = CategoryCatalog.allIncludingVolumes()
    let tools = ToolCatalog.all()
    let idWidth = max(categories.map(\.id.count).max() ?? 0, tools.map(\.id.count).max() ?? 0)
    let indent = String(repeating: " ", count: idWidth + 11)

    for group in CategoryGroup.allCases {
        let members = categories.filter { $0.group == group }
        guard !members.isEmpty else { continue }
        print(Style.bold(group.rawValue))
        for category in members {
            print("  \(pad(Style.cyan(category.id), idWidth + 2))\(pad(Style.safety(category.safety), 9))\(category.name)")
            print("  \(indent)\(Style.dim(category.summary))")
        }
        print()
    }

    print(Style.bold("Tools"))
    for tool in tools {
        print("  \(pad(Style.cyan(tool.id), idWidth + 2))\(pad(Style.safety(tool.safety), 9))\(tool.name)")
        print("  \(indent)\(Style.dim(tool.summary))")
        for option in tool.options {
            let flag = option.isEnabledByDefault ? "--no-\(option.id)" : "--\(option.id)"
            let state = option.isEnabledByDefault ? "on" : "off"
            print("  \(indent)\(Style.dim("\(flag)  \(option.title) (default \(state))"))")
        }
    }
}

// MARK: - Selection

struct Selection {
    var categories: [CleanupCategory] = []
    var tools: [any MaintenanceTool] = []
}

func resolve(_ ids: [String]) throws -> Selection {
    let categories = CategoryCatalog.allIncludingVolumes()
    let tools = ToolCatalog.all()
    if ids.isEmpty { return Selection(categories: categories, tools: tools) }

    var selection = Selection()
    for id in ids {
        if let category = categories.first(where: { $0.id == id }) {
            selection.categories.append(category)
        } else if let tool = tools.first(where: { $0.id == id }) {
            selection.tools.append(tool)
        } else {
            throw UsageError("unknown category or tool '\(id)'. Run `reclaim list` to see them.")
        }
    }
    return selection
}

func toolOptions(for tool: any MaintenanceTool, _ args: Arguments) -> Set<String> {
    var options = tool.defaultOptions
    for option in tool.options {
        if args.has(option.id) { options.insert(option.id) }
        if args.has("no-\(option.id)") { options.remove(option.id) }
    }
    return options
}

func scanCategories(_ categories: [CleanupCategory]) async -> [CategoryScan] {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var done = 0
    }
    let counter = Counter()
    let total = categories.count
    let results = await Scanner().scan(categories) { _ in
        let done = counter.lock.withLock {
            counter.done += 1
            return counter.done
        }
        status("Scanning… \(done)/\(total)")
    }
    clearStatus()
    return results
}

func toolStatuses(_ tools: [any MaintenanceTool]) async -> [(tool: any MaintenanceTool, status: ToolStatus)] {
    guard !tools.isEmpty else { return [] }
    status("Checking \(tools.map(\.name).joined(separator: ", "))…")
    let statuses = await withTaskGroup(of: (Int, ToolStatus).self) { group in
        for (index, tool) in tools.enumerated() {
            group.addTask { (index, await tool.status()) }
        }
        var results = [(Int, ToolStatus)]()
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
    clearStatus()
    return Array(zip(tools, statuses)).map { (tool: $0.0, status: $0.1) }
}

// MARK: - scan

func runScan(_ args: Arguments) async throws {
    let selection = try resolve(args.positionals)
    async let categoryResultsTask = scanCategories(selection.categories)
    async let toolResultsTask = toolStatuses(selection.tools)
    let categoryResults = await categoryResultsTask
    let toolResults = await toolResultsTask
    let showDetails = args.has("details")

    let nameWidth = 26
    var grandTotal: Int64 = 0
    var safeTotal: Int64 = 0
    var inaccessible = 0

    for scan in categoryResults where scan.isPresent {
        grandTotal += scan.totalSize
        if scan.category.safety == .safe { safeTotal += scan.totalSize }
        inaccessible += scan.inaccessibleCount

        print("\(pad(scan.category.name, nameWidth))\(Style.bold(sizeColumn(scan.totalSize)))  \(pad(Style.safety(scan.category.safety), 8))  \(Style.dim(scan.category.id))")
        if showDetails {
            for item in scan.items.prefix(5) {
                print(Style.dim("    \(sizeColumn(item.size))  \(item.url.abbreviatedPath)"))
            }
            if scan.items.count > 5 { print(Style.dim("    … and \(scan.items.count - 5) more")) }
        }
    }

    if !toolResults.isEmpty {
        if !categoryResults.isEmpty { print() }
        for (tool, toolStatus) in toolResults {
            switch toolStatus.availability {
            case .notInstalled:
                continue
            case .unavailable(let reason):
                print("\(pad(tool.name, nameWidth))\(sizeColumn(nil))  \(pad(Style.safety(tool.safety), 8))  \(Style.dim(tool.id))")
                print(Style.yellow("    \(reason)"))
            case .ready:
                let size = toolStatus.reclaimable(options: tool.defaultOptions)
                grandTotal += size ?? 0
                if tool.safety == .safe { safeTotal += size ?? 0 }
                let label = size == nil ? pad("\(toolStatus.entries.count) items", 10, alignRight: true) : sizeColumn(size)
                print("\(pad(tool.name, nameWidth))\(Style.bold(label))  \(pad(Style.safety(tool.safety), 8))  \(Style.dim(tool.id))")
                if showDetails {
                    for entry in toolStatus.entries {
                        let optional = entry.optionID.map { tool.defaultOptions.contains($0) ? "" : " (--\($0))" } ?? ""
                        let detail = entry.detail.map { " – \($0)" } ?? ""
                        print(Style.dim("    \(sizeColumn(entry.size))  \(entry.title)\(detail)\(optional)"))
                    }
                    if let note = toolStatus.note { print(Style.dim("    \(note)")) }
                }
            }
        }
    }

    print(String(repeating: "─", count: nameWidth + 30))
    print("\(pad("Total reclaimable", nameWidth))\(Style.bold(sizeColumn(grandTotal)))")
    print("\(pad("  of which Safe", nameWidth))\(Style.green(sizeColumn(safeTotal)))")
    if inaccessible > 0 {
        print(Style.yellow("\n\(inaccessible) items couldn't be read. Grant Full Disk Access to your terminal for complete results."))
    }
    if safeTotal > 0 {
        print(Style.dim("\nRun `reclaim clean --all-safe` to clean everything marked Safe."))
    }
}

// MARK: - clean

func runClean(_ args: Arguments) async throws {
    var selection: Selection
    if args.has("all-safe") {
        selection = Selection(
            categories: CategoryCatalog.allIncludingVolumes().filter { $0.safety == .safe },
            tools: ToolCatalog.all().filter { $0.safety == .safe }
        )
    } else if args.positionals.isEmpty {
        throw UsageError("specify what to clean, or use --all-safe. Run `reclaim list` to see the options.")
    } else {
        selection = try resolve(args.positionals)
    }

    let dryRun = args.has("dry-run", "n")
    let method: CleanupMethod = args.has("delete") ? .deletePermanently : .moveToTrash
    async let scansTask = scanCategories(selection.categories)
    async let toolsTask = toolStatuses(selection.tools)
    let scans = await scansTask.filter { !$0.items.isEmpty }
    let tools = await toolsTask.filter { tool, status in
        if case .unavailable(let reason) = status.availability {
            print(Style.yellow("Skipping \(tool.name): \(reason)"))
        }
        return status.isReady && !status.entries.isEmpty
    }

    guard !scans.isEmpty || !tools.isEmpty else {
        print("Nothing to clean.")
        return
    }

    print(Style.bold(dryRun ? "Would clean:" : "About to clean:"))
    var total: Int64 = 0
    for scan in scans {
        total += scan.totalSize
        let how = scan.category.deletesPermanently || method == .deletePermanently ? Style.red("delete") : "trash"
        print("  \(sizeColumn(scan.totalSize))  \(pad(scan.category.name, 26)) \(pad(Style.safety(scan.category.safety), 8))  \(how)")
    }
    for (tool, toolStatus) in tools {
        let options = toolOptions(for: tool, args)
        let size = toolStatus.reclaimable(options: options)
        total += size ?? 0
        let enabled = tool.options.filter { options.contains($0.id) }.map(\.title)
        let detail = enabled.isEmpty ? "" : Style.dim(" (\(enabled.joined(separator: ", ")))")
        print("  \(sizeColumn(size))  \(pad(tool.name, 26)) \(pad(Style.safety(tool.safety), 8))  \(Style.cyan(tool.id))\(detail)")
    }
    print("  \(Style.bold(sizeColumn(total)))  total")

    let risky = scans.map(\.category).filter { $0.safety == .caution }.map(\.name)
        + tools.flatMap { tool, _ in tool.options.filter { toolOptions(for: tool, args).contains($0.id) && $0.safety == .caution }.map { "\(tool.name) \($0.title.lowercased())" } }
    if !risky.isEmpty {
        print(Style.red("\nWarning: \(risky.joined(separator: ", ")) may contain data you care about."))
    }

    if !dryRun && !args.has("yes", "y") {
        print()
        guard confirm("Proceed?") else {
            print("Cancelled.")
            return
        }
    }

    let cleaner = Cleaner()
    var freed: Int64 = 0
    var failures = [String]()
    for scan in scans {
        let report = cleaner.clean(scan.items, in: scan.category, method: method, dryRun: dryRun)
        freed += report.bytesFreed
        failures += report.failures.map { "\($0.item.url.abbreviatedPath): \($0.message)" }
    }
    for (tool, toolStatus) in tools {
        let options = toolOptions(for: tool, args)
        if dryRun {
            freed += toolStatus.reclaimable(options: options) ?? 0
            continue
        }
        status("Running \(tool.name) cleanup…")
        do {
            let result = try await tool.clean(options: options, allowAdministrator: args.has("admin"))
            clearStatus()
            freed += result.freed ?? 0
            print("  \(Style.green("✓")) \(tool.name)\(result.freed.map { ": \(ByteSize.format($0))" } ?? "")")
        } catch {
            clearStatus()
            failures.append("\(tool.name): \(error.localizedDescription)")
        }
    }

    if !failures.isEmpty {
        print(Style.yellow("\n\(failures.count) items couldn't be removed:"))
        for failure in failures.prefix(10) { print(Style.dim("  \(failure)")) }
        if failures.count > 10 { print(Style.dim("  … and \(failures.count - 10) more")) }
    }

    let verb = dryRun ? "Would free" : "Reclaimed"
    print(Style.green("\n✓ \(verb) \(ByteSize.format(freed))"))
    if !dryRun && method == .moveToTrash && !scans.isEmpty {
        print(Style.dim("Files were moved to the Trash. Empty it (or run `reclaim clean trash`) to free that space."))
    }
}

// MARK: - apps / uninstall

func formatDate(_ date: Date?) -> String {
    guard let date else { return "never" }
    return date.formatted(date: .abbreviated, time: .omitted)
}

func runApps(_ args: Arguments) async throws {
    var days = 90
    if let value = args.value("days") {
        guard let parsed = Int(value), parsed >= 0 else { throw UsageError("invalid number of days '\(value)'") }
        days = parsed
    }
    status("Measuring apps…")
    let allApps = await AppInventory().scan()
    clearStatus()

    let apps = args.has("all") ? allApps : allApps.filter { $0.isUnused(days: days) }
    guard !apps.isEmpty else {
        print("No apps unused for \(days)+ days. 🎉")
        return
    }

    let nameWidth = min(32, max(12, apps.map(\.name.count).max() ?? 0)) + 2
    print(Style.bold("\(pad("App", nameWidth))\(pad("Size", 10, alignRight: true))  Last used"))
    for app in apps {
        let lastUsed = app.lastUsed.map(formatDate) ?? Style.dim("never (added \(formatDate(app.dateAdded)))")
        print("\(pad(String(app.name.prefix(nameWidth - 2)), nameWidth))\(sizeColumn(app.size))  \(lastUsed)")
    }
    let total = apps.reduce(Int64(0)) { $0 + $1.size }
    let label = args.has("all") ? "\(apps.count) apps" : "\(apps.count) apps unused for \(days)+ days"
    print(Style.bold("\n\(label): \(ByteSize.format(total))"))
    print(Style.dim("Remove one with `reclaim uninstall \"<name>\"`."))
}

func runUninstall(_ args: Arguments) async throws {
    guard let query = args.positionals.first else { throw UsageError("specify an app name or path") }
    let inventory = AppInventory()

    status("Looking for \(query)…")
    let app: InstalledApp
    if query.hasSuffix(".app"), FileManager.default.fileExists(atPath: (query as NSString).expandingTildeInPath) {
        let url = URL(filePath: (query as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        guard let found = await inventory.scan().first(where: { $0.url.normalizedPath == url.normalizedPath }) else {
            clearStatus()
            throw UsageError("\(url.abbreviatedPath) isn't in an Applications folder, or is part of macOS.")
        }
        app = found
    } else {
        let matches = await inventory.scan().filter { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
        guard let found = matches.first else {
            clearStatus()
            throw UsageError("no app named '\(query)' found. Run `reclaim apps --all` to see installed apps.")
        }
        guard matches.count == 1 else {
            clearStatus()
            throw UsageError("several apps are named '\(query)'. Pass the full path instead:\n" + matches.map { "  \($0.url.abbreviatedPath)" }.joined(separator: "\n"))
        }
        app = found
    }
    clearStatus()

    if NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").contains(where: { !$0.isTerminated }) {
        throw UsageError("\(app.name) is running. Quit it first.")
    }

    let leftovers = args.has("keep-data") ? [] : inventory.leftovers(for: app)
    print(Style.bold("\(app.name)") + Style.dim(" \(app.version ?? "") · \(app.bundleID ?? "")"))
    print("  \(sizeColumn(app.size))  \(app.url.abbreviatedPath)")
    for item in leftovers {
        print("  \(sizeColumn(item.size))  \(item.url.abbreviatedPath)")
    }
    let total = app.size + leftovers.reduce(0) { $0 + $1.size }
    print("  \(Style.bold(sizeColumn(total)))  total")

    if args.has("dry-run", "n") { return }
    if !args.has("yes", "y") {
        print()
        guard confirm("Move these to the Trash?") else {
            print("Cancelled.")
            return
        }
    }

    let uninstaller = AppUninstaller(inventory: inventory)
    let report = uninstaller.uninstall(app, leftovers: leftovers, method: .moveToTrash)
    for failure in report.failures {
        print(Style.yellow("  Couldn't remove \(failure.item.url.abbreviatedPath): \(failure.message)"))
    }
    if report.removed.isEmpty {
        print(Style.dim("If the app is owned by another user, try removing it in Finder or with the Reclaim app."))
        exit(1)
    }
    print(Style.green("\n✓ Moved \(ByteSize.format(report.bytesFreed)) to the Trash"))
}

// MARK: - memory

func runMemory(_ args: Arguments) async throws {
    guard let stats = MemoryMonitor.stats() else { throw UsageError("couldn't read memory statistics") }

    let pressure: String
    switch stats.pressure {
    case .normal: pressure = Style.green(stats.pressure.label)
    case .warning: pressure = Style.yellow(stats.pressure.label)
    case .critical: pressure = Style.red(stats.pressure.label)
    }
    print(Style.bold("Memory") + Style.dim("  \(ByteSize.formatMemory(stats.total)) installed"))
    print("  \(progressBar(fraction: stats.usedFraction))  \(ByteSize.formatMemory(stats.used)) used")
    print("  Pressure      \(pressure)  \(Style.dim(stats.pressure.explanation))")
    print("  App memory    \(pad(ByteSize.formatMemory(stats.appMemory), 10, alignRight: true))")
    print("  Wired         \(pad(ByteSize.formatMemory(stats.wired), 10, alignRight: true))")
    print("  Compressed    \(pad(ByteSize.formatMemory(stats.compressed), 10, alignRight: true))")
    print("  Cached files  \(pad(ByteSize.formatMemory(stats.cachedFiles), 10, alignRight: true))  \(Style.dim("(given back automatically when apps need it)"))")
    print("  Swap used     \(pad(ByteSize.formatMemory(stats.swapUsed), 10, alignRight: true))")

    let limit = try parseLimit(args, default: 10)
    let groups = MemoryMonitor.processGroups().prefix(limit)
    if !groups.isEmpty {
        print(Style.bold("\nHeaviest apps"))
        for group in groups {
            let count = group.processCount > 1 ? Style.dim(" (\(group.processCount) processes)") : ""
            print("  \(pad(ByteSize.formatMemory(group.memory), 10, alignRight: true))  \(group.name)\(count)")
        }
    }

    if args.has("purge") {
        status("Clearing file caches…")
        let freed = try await MemoryMonitor.purge(allowAdministrator: args.has("admin"))
        clearStatus()
        print(Style.green("\n✓ Cleared caches. \(ByteSize.formatMemory(freed)) more memory is available right now."))
        print(Style.dim("macOS refills these caches as you work; that's normal and makes your Mac faster."))
    } else if stats.pressure > .normal {
        print(Style.yellow("\nQuitting apps you aren't using is the most effective way to free memory."))
    }
}

// MARK: - explore / large

func expandPath(_ argument: String?) -> URL {
    argument.map { URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
        ?? FileManager.default.homeDirectoryForCurrentUser
}

func parseLimit(_ args: Arguments, default value: Int) throws -> Int {
    guard let text = args.value("limit") else { return value }
    guard let parsed = Int(text), parsed > 0 else { throw UsageError("invalid limit '\(text)'") }
    return parsed
}

func runExplore(_ args: Arguments) async throws {
    let folder = expandPath(args.positionals.first)
    let limit = try parseLimit(args, default: 25)
    status("Measuring \(folder.abbreviatedPath)…")
    let entries = try await FolderExplorer.measuredContents(of: folder)
    clearStatus()

    let total = entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    print(Style.bold("\(folder.abbreviatedPath)  \(ByteSize.format(total))"))
    for entry in entries.prefix(limit) {
        let fraction = total > 0 ? Double(entry.size ?? 0) / Double(total) : 0
        let name = entry.isFolder ? Style.cyan(entry.name + "/") : entry.name
        print("\(sizeColumn(entry.size))  \(progressBar(fraction: fraction, width: 12).replacingOccurrences(of: "░", with: " "))  \(name)")
    }
    if entries.count > limit { print(Style.dim("… and \(entries.count - limit) more")) }
    let inaccessible = entries.reduce(0) { $0 + $1.inaccessibleCount }
    if inaccessible > 0 { print(Style.yellow("\n\(inaccessible) items couldn't be read.")) }
}

func runLarge(_ args: Arguments) throws {
    let root = expandPath(args.positionals.first)
    var options = LargeFileFinder.Options(limit: try parseLimit(args, default: 25))
    if let min = args.value("min") {
        guard let parsed = ByteSize.parse(min) else { throw UsageError("invalid size '\(min)'") }
        options.minimumSize = parsed
    }
    options.includeHidden = args.has("hidden")

    status("Searching \(root.abbreviatedPath) for files ≥ \(ByteSize.format(options.minimumSize))…")
    let files = LargeFileFinder().find(in: root, options: options)
    clearStatus()

    guard !files.isEmpty else {
        print("No files ≥ \(ByteSize.format(options.minimumSize)) found in \(root.abbreviatedPath).")
        return
    }
    for file in files {
        print("\(Style.bold(sizeColumn(file.size)))  \(Style.dim(pad(formatDate(file.modified), 14)))  \(file.url.abbreviatedPath)")
    }
}

// MARK: - undo / exclude

func runUndo(_ args: Arguments) async throws {
    let batches = TrashLedger.shared.batches()
    guard let latest = batches.first else {
        print("Nothing to put back.")
        return
    }
    if args.has("list") {
        for batch in batches {
            print("\(Style.bold(batch.title))  \(Style.dim("\(batch.date.formatted(date: .abbreviated, time: .shortened)) · \(batch.records.count) items · \(ByteSize.format(batch.totalSize))"))")
        }
        return
    }
    print("Put back \(Style.bold(latest.title)) (\(latest.records.count) items, \(ByteSize.format(latest.totalSize)))?")
    if !args.has("yes", "y") {
        guard confirm("Proceed?") else {
            print("Cancelled.")
            return
        }
    }
    let result = TrashLedger.shared.putBack(latest.id)
    for failure in result.failures {
        print(Style.yellow("  Couldn't put back \(failure.record.name): \(failure.message)"))
    }
    print(Style.green("✓ Put back \(result.restored.count) items"))
}

func runExclude(_ args: Arguments) throws {
    var exclusions = Exclusions.load()
    guard let path = args.positionals.first else {
        if exclusions.paths.isEmpty {
            print("No exclusions. Add one with `reclaim exclude <path>`.")
        } else {
            exclusions.paths.forEach { print($0) }
        }
        return
    }
    let url = URL(filePath: (path as NSString).expandingTildeInPath)
    if args.has("remove") {
        exclusions.remove(url.normalizedPath)
        print("Removed \(url.abbreviatedPath) from exclusions.")
    } else {
        exclusions.add(url)
        print("Reclaim will never clean \(url.abbreviatedPath).")
    }
    try exclusions.save()
}

// MARK: - Entry point

let rawArguments = Array(CommandLine.arguments.dropFirst())
let command = rawArguments.first ?? "help"

do {
    let optionsWithValues = Set(["min", "limit", "days"])
        .union(projectsOptionsWithValues).union(leftoversOptionsWithValues).union(duplicatesOptionsWithValues)
        .union(modelsOptionsWithValues).union(icloudOptionsWithValues).union(cpuOptionsWithValues)
        .union(loginItemsOptionsWithValues).union(historyOptionsWithValues)
    let args = try Arguments(Array(rawArguments.dropFirst()), optionsWithValues: optionsWithValues)
    switch command {
    case "status": try runStatus()
    case "list": runList()
    case "scan": try await runScan(args)
    case "clean": try await runClean(args)
    case "apps": try await runApps(args)
    case "uninstall": try await runUninstall(args)
    case "explore": try await runExplore(args)
    case "memory", "ram": try await runMemory(args)
    case "projects": try await runProjects(args)
    case "leftovers": try await runLeftovers(args)
    case "duplicates", "dupes": try await runDuplicates(args)
    case "models": try await runModels(args)
    case "icloud": try await runIcloud(args)
    case "cpu": try await runCpu(args)
    case "login-items": try await runLoginItems(args)
    case "history": try await runHistory(args)
    case "undo": try await runUndo(args)
    case "exclude": try runExclude(args)
    case "large": try runLarge(args)
    case "help", "-h", "--help": print(usage)
    case "version", "--version", "-v": print("reclaim \(ReclaimInfo.version)")
    default: throw UsageError("unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    clearStatus()
    printError("\(error)")
    exit(1)
}
