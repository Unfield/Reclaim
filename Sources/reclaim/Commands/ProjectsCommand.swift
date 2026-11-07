import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let projectsUsage = """
  reclaim projects [path...]         Find dependency and build folders in code projects
                                     (node_modules, target, .build, .venv…; default: ~/Developer, ~/Code, …)
      --days <n>                     Projects untouched for at least n days (default: 30)
      --all                          Include active projects too
      --clean                        Move the listed folders to the Trash
      -n, --dry-run / -y, --yes
"""

/// Options of this command that take a value (e.g. `--days 30`).
let projectsOptionsWithValues: Set<String> = ["days"]

func runProjects(_ args: Arguments) async throws {
    var days = 30
    if let value = args.value("days") {
        guard let parsed = Int(value), parsed >= 0 else { throw UsageError("invalid number of days '\(value)'") }
        days = parsed
    }
    let includeActive = args.has("all")
    let clean = args.has("clean")
    let dryRun = args.has("dry-run", "n")

    let roots: [URL]
    if args.positionals.isEmpty {
        roots = ProjectJunkFinder.commonRoots()
        guard !roots.isEmpty else {
            throw UsageError("no code folders found in the usual places. Pass one, e.g. `reclaim projects ~/work`.")
        }
    } else {
        roots = try args.positionals.map { argument in
            let url = expandPath(argument)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
                throw UsageError("'\(argument)' isn't a folder")
            }
            return url
        }
    }
    let rootList = roots.map(\.abbreviatedPath).joined(separator: ", ")

    status("Looking for projects in \(rootList)…")
    var found = [ProjectJunk]()
    for await junk in ProjectJunkFinder().results(in: roots) {
        found.append(junk)
        status("Looking for projects… \(found.count) folders found")
    }

    let listed = includeActive ? found : found.filter { $0.isInactive(days: days) }
    guard !listed.isEmpty else {
        clearStatus()
        if found.isEmpty {
            print("No dependency or build folders found in \(rootList).")
        } else {
            print("No projects untouched for \(days)+ days. 🎉")
            let belong = found.count == 1 ? "1 folder belongs" : "\(found.count) folders belong"
            print(Style.dim("\(belong) to active projects. Use --all to list them."))
        }
        return
    }

    let measured = await measureProjectJunk(listed)
    clearStatus()
    printProjectJunk(measured, days: days, showsActivity: includeActive)

    let total = measured.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    let projectCount = Set(measured.map(\.project.normalizedPath)).count
    let summary = "\(measured.count) \(measured.count == 1 ? "folder" : "folders") in \(projectCount) \(projectCount == 1 ? "project" : "projects")"
    print(Style.bold("\n\(summary): \(ByteSize.format(total))"))

    guard clean else {
        print(Style.dim("Move them to the Trash by running this again with --clean."))
        return
    }
    let activeCount = measured.filter { !$0.isInactive(days: days) }.count
    if activeCount > 0 {
        print(Style.yellow("Includes \(activeCount) \(activeCount == 1 ? "folder" : "folders") from projects changed in the last \(days) days."))
    }
    if dryRun {
        print(Style.green("✓ Would move \(ByteSize.format(total)) to the Trash"))
        return
    }
    if !args.has("yes", "y") {
        print()
        guard confirm("Move these \(measured.count) folders to the Trash?") else {
            print("Cancelled.")
            return
        }
    }

    let result = ProjectJunkCleaner(roots: roots).moveToTrash(measured)
    TrashLedger.shared.record(title: result.undoTitle, records: result.trashed)
    if !result.failures.isEmpty {
        print(Style.yellow("\n\(result.failures.count) folders couldn't be removed:"))
        for failure in result.failures.prefix(10) { print(Style.dim("  \(failure.message)")) }
        if result.failures.count > 10 { print(Style.dim("  … and \(result.failures.count - 10) more")) }
    }
    guard !result.removed.isEmpty else { exit(1) }
    print(Style.green("\n✓ Moved \(ByteSize.format(result.bytesFreed)) to the Trash"))
    print(Style.dim("Changed your mind? `reclaim undo` puts them back."))
}

/// Measures every folder, a few at a time, keeping the input order.
private func measureProjectJunk(_ items: [ProjectJunk]) async -> [ProjectJunk] {
    var sizes = [URL: Int64]()
    await withTaskGroup(of: (URL, Int64).self) { group in
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let url = items[next].url
            group.addTask { (url, DirectorySizer().size(of: url).bytes) }
            next += 1
        }
        for _ in 0..<4 { addNext() }
        for await (url, bytes) in group {
            sizes[url] = bytes
            status("Measuring… \(sizes.count) of \(items.count)")
            addNext()
        }
    }
    return items.map { item in
        var item = item
        item.size = sizes[item.url]
        return item
    }
}

/// Grouped by project, biggest projects first.
private func printProjectJunk(_ items: [ProjectJunk], days: Int, showsActivity: Bool) {
    let groups = Dictionary(grouping: items, by: \.project.normalizedPath).values
        .map { $0.sorted { $0.sortSize > $1.sortSize } }
        .sorted { lhs, rhs in
            lhs.reduce(Int64(0)) { $0 + ($1.size ?? 0) } > rhs.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        }
    let nameWidth = min(16, max(8, items.map(\.name.count).max() ?? 0)) + 2
    let kindWidth = (items.map(\.kind.name.count).max() ?? 0) + 2

    for (index, group) in groups.enumerated() {
        guard let first = group.first else { continue }
        if index > 0 { print() }
        let activity = first.lastActive.map { "changed \($0.formatted(.relative(presentation: .named)))" } ?? "last change unknown"
        let marker = showsActivity && !first.isInactive(days: days) ? Style.yellow("  active") : ""
        print(Style.bold(first.projectName) + Style.dim("  \(first.project.abbreviatedPath) · \(activity)") + marker)
        for junk in group {
            print("  \(sizeColumn(junk.size))  \(pad(junk.name, nameWidth))\(pad(junk.kind.name, kindWidth))\(pad(Style.safety(junk.kind.safety), 8))\(Style.dim(junk.rebuildHint))")
        }
    }
}
