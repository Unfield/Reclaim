import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let icloudUsage = """
  reclaim icloud                     Downloaded iCloud Drive files you haven't opened lately
      --days <n>                     Not opened for at least n days (default: \(ICloudDrive.defaultIdleDays))
      --evict                        Remove the downloads (files stay in iCloud and download again when opened)
      -n, --dry-run / -y, --yes
"""

/// Options of this command that take a value (e.g. `--days 30`).
let icloudOptionsWithValues: Set<String> = ["days"]

func runIcloud(_ args: Arguments) async throws {
    var days = ICloudDrive.defaultIdleDays
    if let value = args.value("days") {
        guard let parsed = Int(value), parsed > 0 else { throw UsageError("invalid number of days '\(value)'") }
        days = parsed
    }
    let drive = ICloudDrive()
    guard drive.availability == .available else {
        print("iCloud Drive isn't set up on this Mac.")
        print(Style.dim("Sign in to iCloud and turn on iCloud Drive in System Settings to use this."))
        return
    }

    status("Looking for downloaded iCloud files…")
    let scan = drive.scan()
    clearStatus()

    let groups = scan.groups(unusedFor: days)
    let items = groups.flatMap(\.items)
    guard !items.isEmpty else {
        print("No downloaded iCloud files unopened for \(days)+ days.")
        if scan.downloadedSize > 0 {
            print(Style.dim("\(ByteSize.format(scan.downloadedSize)) of iCloud files are downloaded on this Mac, all opened recently."))
        }
        return
    }

    let showAll = args.has("evict")
    for (index, group) in groups.enumerated() {
        if index > 0 { print() }
        print("\(Style.bold(group.folder.name))  \(Style.dim(fileCount(group.items.count))) \(Style.bold(ByteSize.format(group.totalSize)))")
        let shown = showAll ? group.items : Array(group.items.prefix(10))
        for item in shown {
            let path = item.subfolderPath.isEmpty ? item.name : "\(item.subfolderPath)/\(item.name)"
            print("  \(sizeColumn(item.size))  \(Style.dim(pad(formatDate(item.lastUsed), 14)))  \(path)")
        }
        if shown.count < group.items.count { print(Style.dim("  … and \(group.items.count - shown.count) more")) }
    }

    let total = items.reduce(Int64(0)) { $0 + $1.size }
    print(String(repeating: "─", count: 50))
    print("\(pad("\(fileCount(items.count)) not opened in \(days)+ days", 38))\(Style.bold(sizeColumn(total)))")
    print(Style.dim("Removing a download keeps the file in iCloud Drive; it downloads again when you open it."))
    if scan.inaccessibleCount > 0 {
        print(Style.yellow("\(scan.inaccessibleCount) folders couldn't be read."))
    }

    guard args.has("evict") else {
        print(Style.dim("\nRun `reclaim icloud --evict\(days == ICloudDrive.defaultIdleDays ? "" : " --days \(days)")` to remove these downloads."))
        return
    }

    let dryRun = args.has("dry-run", "n")
    if !dryRun && !args.has("yes", "y") {
        print()
        guard confirm("Remove the downloads of \(fileCount(items.count))? Nothing is deleted from iCloud.") else {
            print("Cancelled.")
            return
        }
    }

    status("Removing downloads…")
    let report = drive.evict(items, unusedFor: days, dryRun: dryRun)
    clearStatus()
    if !report.failures.isEmpty {
        print(Style.yellow("\n\(fileCount(report.failures.count)) skipped:"))
        for failure in report.failures.prefix(10) { print(Style.dim("  \(failure.message)")) }
        if report.failures.count > 10 { print(Style.dim("  … and \(report.failures.count - 10) more")) }
    }
    if dryRun {
        print(Style.green("\n✓ Would free \(ByteSize.format(report.bytesFreed)) on this Mac"))
    } else {
        print(Style.green("\n✓ Freed \(ByteSize.format(report.bytesFreed)) on this Mac. The files are still in iCloud Drive."))
    }
}

private func fileCount(_ count: Int) -> String {
    count == 1 ? "1 file" : "\(count) files"
}
