import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let loginItemsUsage = """
  reclaim login-items                List what starts automatically (launch agents and daemons)
      --disable <label>              Turn an item off and stop it now
      --enable <label>               Turn an item back on
      --remove <label>               Move a broken item (program missing) to the Trash
      --admin                        Allow asking for a password (needed for system-wide items)
      -y, --yes                      Don't ask for confirmation
"""

/// Options of this command that take a value (e.g. `--days 30`).
/// Empty on purpose: `--disable <label>` is read as a flag plus a positional label, so these names
/// never clash with flags of other commands (like `exclude --remove`). `--disable=<label>` works too.
let loginItemsOptionsWithValues: Set<String> = []

private enum LoginItemAction {
    case enable, disable, remove

    var verb: String {
        switch self {
        case .enable: "Turn on"
        case .disable: "Turn off"
        case .remove: "Move to the Trash"
        }
    }
}

func runLoginItems(_ args: Arguments) async throws {
    var requested: [(LoginItemAction, String)] = []
    for (action, name) in [(LoginItemAction.disable, "disable"), (.enable, "enable"), (.remove, "remove")] {
        if let label = args.value(name) {
            requested.append((action, label))
        } else if args.has(name) {
            guard let label = args.positionals.first else { throw UsageError("--\(name) needs a label. Run `reclaim login-items` to see them.") }
            requested.append((action, label))
        }
    }
    guard requested.count <= 1 else { throw UsageError("use only one of --disable, --enable and --remove at a time") }

    status("Reading launch agents and daemons…")
    let items = await LaunchItems.scan()
    clearStatus()

    if let (action, label) = requested.first {
        try await perform(action, label: label, items: items, args: args)
    } else {
        printLoginItems(items)
    }
}

private func printLoginItems(_ items: [LaunchItem]) {
    for domain in LaunchItemDomain.allCases {
        let inDomain = items.filter { $0.domain == domain }
        print(Style.bold(domain.title) + Style.dim("  \(domain.directory(home: LaunchItems.Context.current.home).abbreviatedPath)"))
        if inDomain.isEmpty {
            print(Style.dim("  None\n"))
            continue
        }
        for item in inDomain {
            let status: String
            switch item.status {
            case .on: status = Style.green(item.status.label)
            case .off: status = Style.dim(item.status.label)
            case .broken: status = Style.red(item.status.label)
            }
            let name = item.appName.map { "\($0) \(Style.dim("(\(item.label))"))" } ?? item.label
            print("  \(pad(status, 7))\(name)")
            var when = item.schedule.summary(for: item.domain)
            if let detail = item.schedule.detail, item.schedule.keepAlive != .always { when += " · \(detail.lowercased())" }
            if item.isRunning { when += " · running now" }
            print("         \(Style.dim(when))")
            if let problem = item.problem {
                print("         \(Style.red(problem)): \(Style.dim(item.program ?? item.plistURL.abbreviatedPath))")
            } else {
                print("         \(Style.dim(item.command))")
            }
        }
        print("")
    }

    let broken = items.filter(\.isBroken).count
    if broken > 0 {
        print(Style.yellow("\(broken) broken \(broken == 1 ? "item" : "items") can't start because the program is gone. Remove with `reclaim login-items --remove <label>`."))
    }
    print(Style.dim("Apps that open at login are managed in System Settings → General → Login Items & Extensions."))
}

private func perform(_ action: LoginItemAction, label: String, items: [LaunchItem], args: Arguments) async throws {
    guard let item = items.first(where: { $0.label == label }) ?? items.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
        throw UsageError("no login item labelled '\(label)'. Run `reclaim login-items` to see them (Apple's own items can't be changed).")
    }
    if item.domain.requiresAdministrator && geteuid() != 0 && !args.has("admin") {
        throw UsageError("\(item.label) is a \(item.domain == .systemDaemon ? "background daemon" : "system-wide agent"), so changing it needs administrator rights. Run with sudo, or pass --admin.")
    }
    switch action {
    case .enable where item.status == .on:
        print("\(item.displayName) is already on.")
        return
    case .disable where item.status == .off:
        print("\(item.displayName) is already off.")
        return
    case .remove where !item.isBroken:
        throw UsageError("\(item.label) isn't broken, so it isn't removed. Turn it off instead with --disable.")
    case .enable where item.isBroken:
        throw UsageError("\(item.label) can't be turned on because its program is missing.")
    default:
        break
    }

    print(Style.bold("\(action.verb): \(item.displayName)") + (item.appName == nil ? "" : Style.dim("  (\(item.label))")))
    print(Style.dim("  \(item.plistURL.abbreviatedPath)"))
    switch action {
    case .disable: print("  It stops now and won't start automatically until you turn it back on. Its app may stop working fully.")
    case .enable: print("  It starts again automatically, like before.")
    case .remove: print("  Its program is missing, so it can't run anyway. The file goes to the Trash.")
    }

    if !args.has("yes", "y") {
        guard confirm("Proceed?") else {
            print("Cancelled.")
            return
        }
    }

    switch action {
    case .enable, .disable:
        try await LaunchItems.setEnabled(action == .enable, item, allowAdministrator: args.has("admin"))
        print(Style.green("✓ \(item.displayName) is \(action == .enable ? "on" : "off")."))
    case .remove:
        if let record = try await LaunchItems.remove(item, allowAdministrator: args.has("admin")) {
            TrashLedger.shared.record(title: "Removed login item \(item.label)", records: [record])
            print(Style.green("✓ Moved \(item.plistURL.lastPathComponent) to the Trash.") + Style.dim(" Undo with `reclaim undo`."))
        } else {
            print(Style.green("✓ Moved \(item.plistURL.lastPathComponent) to the Trash."))
        }
    }
}
