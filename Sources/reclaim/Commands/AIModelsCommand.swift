import Foundation
import ReclaimCore

/// Lines added to `reclaim help`.
let modelsUsage = """
  reclaim models                     List local AI models (Ollama, LM Studio, Hugging Face, GPT4All, PyTorch)
      --remove <name>...             Remove models: to the Trash, or with `ollama rm` for Ollama if installed
      -n, --dry-run / -y, --yes
"""

/// Options of this command that take a value (e.g. `--days 30`).
/// `--remove` is a flag; the model names are the positional arguments, so several can be given.
let modelsOptionsWithValues: Set<String> = []

func runModels(_ args: Arguments) async throws {
    let names = args.positionals + [args.value("remove")].compactMap { $0 }
    let removing = args.has("remove") || args.value("remove") != nil
    if removing && names.isEmpty { throw UsageError("specify the models to remove, e.g. `reclaim models --remove llama3:8b`") }
    if !removing && !names.isEmpty { throw UsageError("to remove models, use `reclaim models --remove <name>...`") }

    status("Looking for AI models…")
    let models = AIModelScanner().scan()
    clearStatus()

    if removing {
        try await removeModels(named: names, from: models, args)
    } else {
        listModels(models)
    }
}

private func modelDetail(_ model: AIModel) -> String {
    var details = [String]()
    if model.kind == .dataset { details.append("dataset") }
    if model.sharedSize > 0 { details.append("\(ByteSize.format(model.sharedSize)) shared with other models") }
    return details.isEmpty ? "" : Style.dim("  (\(details.joined(separator: ", ")))")
}

private func listModels(_ models: [AIModel]) {
    guard !models.isEmpty else {
        print("No local AI models found.")
        print(Style.dim("Reclaim looks for Ollama, LM Studio, Hugging Face, GPT4All and PyTorch Hub models."))
        return
    }

    for (index, source) in AIModelSource.allCases.enumerated() {
        let members = models.filter { $0.source == source }
        guard !members.isEmpty else { continue }
        if index > 0, models.contains(where: { $0.source < source }) { print() }
        let total = AIModel.diskUsage(of: members)
        print("\(Style.bold(source.name))  \(Style.dim("\(members.count) \(members.count == 1 ? "model" : "models")")) \(Style.bold(ByteSize.format(total)))")
        for model in members {
            print("  \(sizeColumn(model.size))  \(Style.dim(pad(formatDate(model.lastUsed), 14)))  \(model.name)\(modelDetail(model))")
        }
    }

    let total = AIModel.diskUsage(of: models)
    print(String(repeating: "─", count: 50))
    print("\(pad("\(models.count) models", 38))\(Style.bold(sizeColumn(total)))")
    print(Style.dim("Dates show when each model was last used. Remove one with `reclaim models --remove <name>`."))
}

private func removeModels(named names: [String], from models: [AIModel], _ args: Arguments) async throws {
    var chosen = [AIModel]()
    for name in names {
        let path = URL(filePath: (name as NSString).expandingTildeInPath).normalizedPath
        let matches = models.filter {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame || $0.url.normalizedPath == path
        }
        guard !matches.isEmpty else {
            throw UsageError("no model named '\(name)'. Run `reclaim models` to see them.")
        }
        guard matches.count == 1 else {
            throw UsageError("several models are named '\(name)'. Pass the path instead:\n"
                + matches.map { "  \($0.source.name): \($0.url.abbreviatedPath)" }.joined(separator: "\n"))
        }
        if !chosen.contains(matches[0]) { chosen.append(matches[0]) }
    }

    let remover = AIModelRemover()
    let dryRun = args.has("dry-run", "n")
    print(Style.bold(dryRun ? "Would remove:" : "About to remove:"))
    for model in chosen {
        let how = model.source == .ollama && remover.usesOllamaCLI ? Style.red("ollama rm") : "trash"
        print("  \(sizeColumn(model.reclaimableSize))  \(pad(model.source.name, 14)) \(model.name)  \(Style.dim(how))")
    }
    let total = chosen.reduce(Int64(0)) { $0 + $1.reclaimableSize }
    print("  \(Style.bold(sizeColumn(total)))  total")
    if remover.usesOllamaCLI, chosen.contains(where: { $0.source == .ollama }) {
        print(Style.yellow("\nOllama models are removed with `ollama rm` and can't be put back."))
    }
    if chosen.contains(where: { $0.sharedSize > 0 }) {
        print(Style.dim("Files shared with other Ollama models are kept."))
    }

    if !dryRun && !args.has("yes", "y") {
        print()
        guard confirm("Proceed?") else {
            print("Cancelled.")
            return
        }
    }

    status("Removing…")
    let report = await remover.remove(chosen, dryRun: dryRun)
    clearStatus()
    if !report.trashed.isEmpty {
        let title = report.removed.count == 1 ? "Removed \(report.removed[0].name)" : "Removed \(report.removed.count) AI models"
        TrashLedger.shared.record(title: title, records: report.trashed)
    }

    for failure in report.failures {
        print(Style.yellow("  Couldn't remove \(failure.model.name): \(failure.message)"))
    }
    for warning in report.warnings { print(Style.yellow("  \(warning)")) }

    if dryRun {
        print(Style.green("\n✓ Would free \(ByteSize.format(report.removed.reduce(0) { $0 + $1.reclaimableSize }))"))
        return
    }
    if report.deletedBytes > 0 { print(Style.green("\n✓ Removed \(ByteSize.format(report.deletedBytes)) with `ollama rm`")) }
    if report.trashedBytes > 0 {
        print(Style.green("\n✓ Moved \(ByteSize.format(report.trashedBytes)) to the Trash"))
        print(Style.dim("Run `reclaim undo` to put it back, or empty the Trash to free the space."))
    }
    if report.removed.isEmpty { exit(1) }
}
