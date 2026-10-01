import Foundation

public enum OpKind: String, Codable, Sendable { case replace, create }

public enum BatchState: String, Codable, Sendable {
    case pending          // written before touching anything; stays this way if we crash mid-batch
    case committed
    case rolledBack       // a failed/interrupted batch that was reverted
    case undone
    case partiallyUndone
}

public struct JournalOp: Codable, Sendable, Identifiable, Equatable {
    public var op: OpKind
    public var path: String
    public var backup: String?       // project-relative path of the backup (replace only)
    public var shaBefore: String?    // hash of the original (replace only)
    public var shaAfter: String      // hash of the content we wrote
    public var status: MergeStatus
    public var added: Int
    public var removed: Int
    public var undone: Bool?

    public var id: String { path }
}

public struct JournalEntry: Codable, Sendable, Identifiable, Equatable {
    public var batch: String
    public var state: BatchState
    public var time: Date
    public var ops: [JournalOp]
    public var notes: [String]
    /// Backups were deleted by a prune; the batch can no longer be undone.
    public var pruned: Bool?

    public var id: String { batch }
}

/// Append-only JSONL. Every line is a full snapshot of one batch; the last line per batch wins.
/// A crash mid-write can only damage the final line, which is skipped on load.
public final class Journal {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("log.jsonl") }

    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        encoder = e
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        decoder = d
    }

    public func append(_ entry: JournalEntry) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var line = try encoder.encode(entry)
        line.append(0x0A)

        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            // If a previous crash left a partial line, start on a fresh line.
            try handle.seek(toOffset: size - 1)
            let last = try handle.read(upToCount: 1) ?? Data()
            if last.first != 0x0A {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Batches in order of first appearance, each in its latest state.
    public func load() -> [JournalEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var order: [String] = []
        var latest: [String: JournalEntry] = [:]
        for chunk in data.split(separator: 0x0A) {
            guard let entry = try? decoder.decode(JournalEntry.self, from: Data(chunk)) else { continue }
            if latest[entry.batch] == nil { order.append(entry.batch) }
            latest[entry.batch] = entry
        }
        return order.compactMap { latest[$0] }
    }

    public func pending() -> [JournalEntry] {
        load().filter { $0.state == .pending }
    }

    /// Exact id or unique prefix.
    public func resolve(_ idOrPrefix: String) throws -> JournalEntry {
        let all = load()
        if let exact = all.first(where: { $0.batch == idOrPrefix }) { return exact }
        let matches = all.filter { $0.batch.hasPrefix(idOrPrefix) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw MergeError.noSuchBatch(idOrPrefix)
        default: throw MergeError.ambiguousBatch(idOrPrefix)
        }
    }
}
