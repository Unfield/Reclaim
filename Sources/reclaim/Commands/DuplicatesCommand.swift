import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let duplicatesUsage = """
  reclaim duplicates [path...]       Find identical files (default: Downloads, Documents, Desktop)
      --min <size>                   Minimum file size, e.g. 100KB, 10MB (default: 1MB)
      --keep <rule>                  Copy to keep: oldest, newest or shortest (path) (default: oldest)
      --limit <n>                    Maximum number of groups to list
      --clean                        Move all but the kept copy of each file to the Trash
      -n, --dry-run / -y, --yes
"""

/// Options of this command that take a value (e.g. `--days 30`).
let duplicatesOptionsWithValues: Set<String> = ["min", "keep", "limit"]

func runDuplicates(_ args: Arguments) async throws {
    let roots = args.positionals.isEmpty ? DuplicateFinder.defaultRoots() : args.positionals.map(expandPath)
    guard !roots.isEmpty else { throw UsageError("no folders to search. Pass one or more paths.") }
    for root in roots {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageError("\(root.abbreviatedPath) isn't a folder")
        }
        if DuplicateFinder.isProtected(root) {
            throw UsageError("\(root.abbreviatedPath) is a system or app data location, which Reclaim doesn't search for duplicates")
        }
    }

    var options = DuplicateFinder.Options()
    if let min = args.value("min") {
        guard let parsed = ByteSize.parse(min), parsed > 0 else { throw UsageError("invalid size '\(min)'") }
        options.minimumSize = parsed
    }
    let rule: DuplicateKeepRule
    switch args.value("keep")?.lowercased() {
    case nil, "oldest": rule = .oldest
    case "newest": rule = .newest
    case "shortest", "shortest-path": rule = .shortestPath
    case let other?: throw UsageError("invalid --keep '\(other)'. Use oldest, newest or shortest.")
    }
    let limit = try parseLimit(args, default: .max)

    let searched = roots.map(\.abbreviatedPath).joined(separator: ", ")
    status("Searching \(searched) for duplicates ≥ \(ByteSize.format(options.minimumSize))…")
    let result = try DuplicateFinder(options: options).find(in: roots) { progress in
        status(describe(progress))
    }
    clearStatus()

    guard !result.groups.isEmpty else {
        print("No duplicates ≥ \(ByteSize.format(options.minimumSize)) in \(searched) (\(result.filesExamined) files checked).")
        printUnreadable(result.unreadableCount)
        return
    }

    let selection = DuplicateSelection(groups: result.groups, keeping: rule)
    for group in result.groups.prefix(limit) {
        print("\(Style.bold(sizeColumn(group.wastedSpace)))  \(group.files.count) copies of \(ByteSize.format(group.size))")
        let keeper = group.keeper(for: rule)
        for file in group.files {
            let mark = file.url == keeper?.url ? Style.green("keep") : Style.dim("dupe")
            let clone = group.sharesStorage(file) ? Style.dim("  (clone)") : ""
            print("              \(mark)  \(Style.dim(pad(formatDate(file.modified), 13)))  \(file.url.abbreviatedPath)\(clone)")
        }
    }
    if result.groups.count > limit { print(Style.dim("… and \(result.groups.count - limit) more groups")) }

    let count = selection.count(in: result.groups)
    let savings = selection.estimatedSavings(in: result.groups)
    let files = result.groups.count == 1 ? "1 file has" : "\(result.groups.count) files have"
    print(Style.bold("\n\(files) identical copies, using \(ByteSize.format(result.wastedSpace)) extra"))
    if savings < result.wastedSpace {
        print(Style.dim("Some copies are APFS clones that share storage, so removing them frees only about \(ByteSize.format(savings))."))
    }
    printUnreadable(result.unreadableCount)

    guard args.has("clean") else {
        print(Style.dim("Keeping the \(rule.title.lowercased()) copy, `--clean` would move \(count) files to the Trash."))
        return
    }

    let dryRun = args.has("dry-run", "n")
    if !dryRun && !args.has("yes", "y") {
        print()
        guard confirm("Move \(count) duplicates to the Trash, keeping the \(rule.title.lowercased()) copy of each?") else {
            print("Cancelled.")
            return
        }
    }

    let removal = DuplicateRemover().remove(selection.urls, from: result.groups, dryRun: dryRun)
    if !removal.skipped.isEmpty {
        print(Style.yellow("\n\(removal.skipped.count) files were skipped:"))
        for skip in removal.skipped.prefix(10) {
            print(Style.dim("  \(skip.file.url.abbreviatedPath): \(skip.reason.localizedDescription)"))
        }
        if removal.skipped.count > 10 { print(Style.dim("  … and \(removal.skipped.count - 10) more")) }
    }

    if dryRun {
        print(Style.green("\n✓ Would move \(removal.removed.count) duplicates (\(ByteSize.format(removal.bytesRemoved))) to the Trash"))
        return
    }
    TrashLedger.shared.record(title: duplicatesTitle(removal.trashed.count), records: removal.trashed)
    print(Style.green("\n✓ Moved \(removal.removed.count) duplicates (\(ByteSize.format(removal.bytesRemoved))) to the Trash"))
    if !removal.trashed.isEmpty {
        print(Style.dim("Run `reclaim undo` to put them back. Empty the Trash to free the space."))
    }
}

private func duplicatesTitle(_ count: Int) -> String {
    count == 1 ? "Removed 1 duplicate" : "Removed \(count) duplicates"
}

private func describe(_ progress: DuplicateScanProgress) -> String {
    switch progress.phase {
    case .searching:
        "Looking at files… \(progress.filesExamined)"
    case .comparing:
        "Comparing files with the same size… \(progress.filesDone) of \(progress.filesTotal)"
    case .verifying:
        "Checking contents… \(ByteSize.format(progress.bytesHashed)) of \(ByteSize.format(progress.bytesToHash))"
    }
}

private func printUnreadable(_ count: Int) {
    if count > 0 { print(Style.yellow("\(count) items couldn't be read. Grant your terminal Full Disk Access for complete results.")) }
}
