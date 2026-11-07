import Foundation

/// Where Reclaim keeps its own data (shared by the app and the CLI).
public enum ReclaimPaths {
    public static var supportDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Reclaim", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One item Reclaim moved to the Trash, and where it came from.
public struct TrashRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public let original: URL
    public let trashed: URL
    public let size: Int64

    public init(id: UUID = UUID(), original: URL, trashed: URL, size: Int64) {
        self.id = id
        self.original = original
        self.trashed = trashed
        self.size = size
    }

    public var name: String { original.lastPathComponent }
    /// Still in the Trash, so it can be put back.
    public var isRestorable: Bool { FileManager.default.fileExists(atPath: trashed.path(percentEncoded: false)) }
}

/// Everything trashed by one action, e.g. "Cleanup" or "Uninstalled Zed".
public struct TrashBatch: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let title: String
    public var records: [TrashRecord]

    public init(id: UUID = UUID(), date: Date = Date(), title: String, records: [TrashRecord]) {
        self.id = id
        self.date = date
        self.title = title
        self.records = records
    }

    public var totalSize: Int64 { records.reduce(0) { $0 + $1.size } }
    public var restorableRecords: [TrashRecord] { records.filter(\.isRestorable) }
}

public enum Trash {
    /// Moves an item to the Trash and returns a record that lets it be put back later.
    public static func move(_ url: URL, size: Int64) throws -> TrashRecord {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        let trashed = (resulting as URL?) ?? url
        return TrashRecord(original: url, trashed: trashed, size: size)
    }
}

/// A persistent log of what Reclaim moved to the Trash, so it can be undone ("Put Back").
public final class TrashLedger: @unchecked Sendable {
    public static let shared = TrashLedger(file: ReclaimPaths.supportDirectory.appending(path: "trash-history.json"))

    private let file: URL
    private let lock = NSLock()
    private let maxBatches = 50

    public init(file: URL) {
        self.file = file
    }

    /// Records a batch. Empty batches are ignored.
    public func record(title: String, records: [TrashRecord]) {
        guard !records.isEmpty else { return }
        lock.withLock {
            var batches = load()
            batches.insert(TrashBatch(title: title, records: records), at: 0)
            save(Array(batches.prefix(maxBatches)))
        }
    }

    /// Batches that still have at least one item in the Trash, newest first.
    public func batches() -> [TrashBatch] {
        lock.withLock {
            let all = load()
            let live = all.compactMap { batch -> TrashBatch? in
                var batch = batch
                batch.records = batch.restorableRecords
                return batch.records.isEmpty ? nil : batch
            }
            if live.count != all.count || zip(live, all).contains(where: { $0.records.count != $1.records.count }) {
                save(live)
            }
            return live
        }
    }

    public struct PutBackResult: Sendable {
        public var restored: [TrashRecord] = []
        public var failures: [(record: TrashRecord, message: String)] = []
    }

    /// Moves a batch's items from the Trash back to where they were.
    public func putBack(_ batchID: UUID) -> PutBackResult {
        lock.withLock {
            var batches = load()
            guard let index = batches.firstIndex(where: { $0.id == batchID }) else { return PutBackResult() }
            var result = PutBackResult()
            let fileManager = FileManager.default

            for record in batches[index].records where record.isRestorable {
                do {
                    if fileManager.fileExists(atPath: record.original.path(percentEncoded: false)) {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: record.original.path(percentEncoded: false)])
                    }
                    try fileManager.createDirectory(at: record.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: record.trashed, to: record.original)
                    result.restored.append(record)
                } catch {
                    result.failures.append((record, error.localizedDescription))
                }
            }

            let restoredIDs = Set(result.restored.map(\.id))
            batches[index].records.removeAll { restoredIDs.contains($0.id) || !$0.isRestorable }
            if batches[index].records.isEmpty { batches.remove(at: index) }
            save(batches)
            return result
        }
    }

    private func load() -> [TrashBatch] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrashBatch].self, from: data)) ?? []
    }

    private func save(_ batches: [TrashBatch]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(batches) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
