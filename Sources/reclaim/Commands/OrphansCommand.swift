import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let leftoversUsage = """
  reclaim leftovers                  List data left behind by apps that are no longer installed
      --containers                   Also measure app containers (macOS may ask for permission)
      --clean <bundle-id...>         Move the leftovers of these apps to the Trash
      -n, --dry-run / -y, --yes
"""

/// Options of this command that take a value (e.g. `--days 30`).
/// `--clean` takes one or more IDs as positionals, so it's parsed as a flag.
let leftoversOptionsWithValues: Set<String> = []

func runLeftovers(_ args: Arguments) async throws {
    var ids = args.positionals
    if let value = args.value("clean") { ids.insert(value, at: 0) }
    let cleaning = args.has("clean") || args.value("clean") != nil
    if !cleaning, !ids.isEmpty {
        throw UsageError("unexpected '\(ids[0])'. To remove leftovers, use `reclaim leftovers --clean <bundle-id>`.")
    }
    if cleaning, ids.isEmpty { throw UsageError("--clean needs at least one bundle ID. Run `reclaim leftovers` to see them.") }

    let finder = OrphanFinder()
    status("Looking for leftovers of removed apps…")
    let scan = await finder.scan()
    clearStatus()

    if cleaning {
        try cleanLeftovers(ids: ids, in: scan.groups, finder: finder, args: args)
    } else {
        listLeftovers(scan, measureContainers: args.has("containers"))
    }
}

private func listLeftovers(_ scan: LeftoverScan, measureContainers: Bool) {
    var groups = scan.groups
    if measureContainers {
        status("Measuring app containers…")
        groups = OrphanFinder.sorted(groups.map { OrphanFinder.measured($0) })
        clearStatus()
    }

    for folder in scan.unreadableFolders {
        print(Style.yellow("Couldn't read \(folder.abbreviatedPath). Grant your terminal Full Disk Access for complete results."))
    }
    guard !groups.isEmpty else {
        print("No leftovers from removed apps found. 🎉")
        return
    }

    let idWidth = min(44, max(9, groups.map(\.bundleID.count).max() ?? 0)) + 2
    let nameWidth = min(24, max(4, groups.map(\.name.count).max() ?? 0)) + 2
    print(Style.bold("\(pad("Bundle ID", idWidth))\(pad("Name", nameWidth))\(pad("Size", 10, alignRight: true))  \(pad("Modified", 12))  Locations"))
    for group in groups {
        let size = group.hasUnmeasuredLocations ? pad(ByteSize.format(group.size) + "+", 10, alignRight: true) : sizeColumn(group.size)
        let modified = group.lastModified.map(formatDate) ?? "—"
        print("\(pad(String(group.bundleID.prefix(idWidth - 2)), idWidth))\(pad(String(group.name.prefix(nameWidth - 2)), nameWidth))\(size)  \(pad(modified, 12))  \(group.locations.count)")
    }

    let total = groups.reduce(Int64(0)) { $0 + $1.size }
    print(Style.bold("\n\(groups.count) removed apps left \(ByteSize.format(total)) behind"))
    if groups.contains(where: \.hasUnmeasuredLocations) {
        print(Style.dim("+ App containers aren't measured unless you pass --containers (macOS may ask for permission)."))
    }
    print(Style.dim("Review before removing: leftovers can include settings and documents."))
    print(Style.dim("Remove with `reclaim leftovers --clean <bundle-id>...`."))
}

private func cleanLeftovers(ids: [String], in groups: [LeftoverGroup], finder: OrphanFinder, args: Arguments) throws {
    var chosen = [LeftoverGroup]()
    var unknown = [String]()
    func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
    for id in ids {
        if let match = groups.first(where: { same($0.bundleID, id) }) {
            chosen.removeAll { $0.id == match.id }
            chosen.append(match)
        } else if let parent = groups.first(where: { $0.locations.contains { same($0.bundleID, id) } }) {
            // An extension or helper ID within a group: only its own locations.
            guard !chosen.contains(where: { $0.id == parent.id && $0.locations.count == parent.locations.count }) else { continue }
            var group = chosen.first(where: { $0.id == parent.id }) ?? LeftoverGroup(bundleID: parent.bundleID, name: parent.name, locations: [])
            group.locations += parent.locations.filter { same($0.bundleID, id) && !group.locations.contains($0) }
            chosen.removeAll { $0.id == parent.id }
            chosen.append(group)
        } else {
            unknown.append(id)
        }
    }
    guard unknown.isEmpty else {
        throw UsageError("no leftovers found for \(unknown.joined(separator: ", ")). The app may still be installed, or it left nothing behind. Run `reclaim leftovers` to see them.")
    }

    // Everything here is about to be removed, so measuring containers (and any permission prompt) is expected.
    status("Measuring…")
    chosen = chosen.map { OrphanFinder.measured($0) }
    clearStatus()

    for group in chosen {
        print(Style.bold(group.name) + Style.dim(" · \(group.bundleID)"))
        for location in group.locations {
            print("  \(sizeColumn(location.size))  \(location.url.abbreviatedPath)")
        }
    }
    let total = chosen.reduce(Int64(0)) { $0 + $1.size }
    let count = chosen.reduce(0) { $0 + $1.locations.count }
    print("  \(Style.bold(sizeColumn(total)))  total in \(count) locations")

    if args.has("dry-run", "n") { return }
    if !args.has("yes", "y") {
        print()
        guard confirm("Move these to the Trash?") else {
            print("Cancelled.")
            return
        }
    }

    let report = finder.remove(chosen.flatMap(\.locations), method: .moveToTrash)
    let title = chosen.count == 1 ? "Removed leftovers of \(chosen[0].name)" : "Removed leftovers of \(chosen.count) apps"
    TrashLedger.shared.record(title: title, records: report.trashed)

    for failure in report.failures {
        print(Style.yellow("  Couldn't remove \(failure.item.url.abbreviatedPath): \(failure.message)"))
    }
    guard !report.removed.isEmpty else { exit(1) }
    print(Style.green("\n✓ Moved \(ByteSize.format(report.bytesFreed)) to the Trash"))
    print(Style.dim("Changed your mind? `reclaim undo` puts it back."))
}

