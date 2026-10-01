import Foundation

public enum UndoOutcome: String, Codable, Sendable {
    case restored              // original put back from the verified backup
    case deleted               // file created by the batch was removed
    case alreadyOriginal       // nothing to do: file is already in its pre-batch state
    case skippedCorruptBackup  // backup missing or its hash != sha_before. Live file untouched
    case skippedModified       // live file changed since the commit; needs force
    case failed
}

public struct UndoOpResult: Codable, Sendable, Equatable {
    public let path: String
    public let outcome: UndoOutcome
    public let detail: String?
}

public struct UndoReport: Sendable {
    public let batch: String
    public let results: [UndoOpResult]
    public let finalState: BatchState

    public var skippedModified: [UndoOpResult] { results.filter { $0.outcome == .skippedModified } }
    public var skippedCorrupt: [UndoOpResult] { results.filter { $0.outcome == .skippedCorruptBackup } }
    public var failed: [UndoOpResult] { results.filter { $0.outcome == .failed } }
    public var isComplete: Bool { finalState == .undone || finalState == .rolledBack }
}

public struct TrashOutcome: Sendable, Equatable {
    public let source: String
    public let trashed: Bool
    public let reason: String?
}

public struct PruneReport: Sendable {
    public let batches: [String]
    public let bytesFreed: Int64
}

public final class Operations {
    public let project: URL
    public let options: ClassifierOptions
    public let journal: Journal
    public let backupRoot: URL

    private let fm = FileManager.default

    public init(project: URL, options: ClassifierOptions = ClassifierOptions()) {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        self.project = root
        self.options = options
        self.backupRoot = root.appendingPathComponent(".merge_backup", isDirectory: true)
        self.journal = Journal(directory: backupRoot)
    }

    // MARK: - Apply

    private struct Item {
        let rel: String
        let target: URL
        let data: Data
        let existed: Bool
        let shaBefore: String?
        let shaAfter: String
        let fresh: Classification
    }

    /// One batch = one transaction:
    ///  1. validate and re-classify against the files as they are *now* (refuses if anything got worse)
    ///  2. journal a `pending` entry
    ///  3. back up every original and verify the backup hash. Any mismatch aborts before a single write
    ///  4. write atomically, verify each written file, roll back everything on failure
    ///  5. journal `committed`
    ///
    /// Files that have no original in the project are **never created** unless `allowNew` is true. They are
    /// skipped and recorded in the batch notes ("Not in project, not added: …"). The check uses the project as it
    /// is now, so a file whose original vanished after planning is skipped too.
    @discardableResult
    public func apply(_ changes: [PlannedChange], allowNew: Bool = false, now: Date = Date()) throws -> JournalEntry {
        var items: [Item] = []
        var skippedNew: [String] = []
        var seen = Set<String>()

        for c in changes where c.status != .identical && c.issue == nil {
            let rel = try PathRules.validate(c.targetRelPath)
            guard seen.insert(rel.lowercased()).inserted else { throw MergeError.duplicateTarget(rel) }

            let target = project.appendingPathComponent(rel)
            try ensureInsideProject(target)

            var isDir: ObjCBool = false
            let existed = fm.fileExists(atPath: target.path, isDirectory: &isDir)
            if existed && isDir.boolValue { throw MergeError.invalidPath(rel) }
            if !existed && !allowNew {
                skippedNew.append(rel)
                continue
            }

            let data = try Data(contentsOf: c.source)
            let oldData: Data? = try existed ? Data(contentsOf: target) : nil
            let fresh = Classifier.classify(old: oldData, new: data, options: options)
            if fresh.status == .identical { continue }
            if fresh.status.severity > c.status.severity {
                throw MergeError.stale(path: rel, planned: c.status, now: fresh.status)
            }

            items.append(Item(rel: rel, target: target, data: data, existed: existed,
                              shaBefore: oldData.map { Hashing.sha256(data: $0) },
                              shaAfter: Hashing.sha256(data: data), fresh: fresh))
        }
        guard !items.isEmpty else {
            if !skippedNew.isEmpty { throw MergeError.newFilesNotAllowed(skippedNew.count) }
            throw MergeError.nothingToApply
        }

        let batchId = uniqueBatchId(now)
        let batchDir = backupRoot.appendingPathComponent(batchId, isDirectory: true)

        let ops: [JournalOp] = items.map {
            JournalOp(op: $0.existed ? .replace : .create,
                      path: $0.rel,
                      backup: $0.existed ? ".merge_backup/\(batchId)/\($0.rel)" : nil,
                      shaBefore: $0.shaBefore,
                      shaAfter: $0.shaAfter,
                      status: $0.fresh.status,
                      added: $0.fresh.added,
                      removed: $0.fresh.removed,
                      undone: nil)
        }
        var entry = JournalEntry(batch: batchId, state: .pending, time: now, ops: ops,
                                 notes: skippedNew.map { "Not in project, not added: \($0)" })
        try journal.append(entry)

        // Back up and verify, with nothing modified yet.
        do {
            for (item, op) in zip(items, ops) where item.existed {
                guard let rel = op.backup else { continue }
                let dest = project.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item.target, to: dest)
                guard try Hashing.sha256(file: dest) == item.shaBefore else {
                    throw MergeError.backupVerificationFailed(item.rel)
                }
            }
        } catch {
            try? fm.removeItem(at: batchDir)
            entry.state = .rolledBack
            entry.notes.append("Aborted before writing: \(error.localizedDescription)")
            try? journal.append(entry)
            throw error
        }

        // Write, verify, and roll back on failure.
        do {
            for item in items {
                try Self.atomicWrite(item.data, to: item.target, attributesFrom: item.existed ? item.target : nil)
                guard try Hashing.sha256(file: item.target) == item.shaAfter else {
                    throw MergeError.writeVerificationFailed(item.rel)
                }
            }
        } catch {
            let (revertedOps, _) = performRevert(entry, force: true)
            entry.ops = revertedOps
            entry.state = revertedOps.allSatisfy { $0.undone == true } ? .rolledBack : .partiallyUndone
            entry.notes.append("Write failed, rolled back: \(error.localizedDescription)")
            try? journal.append(entry)
            throw error
        }

        entry.state = .committed
        try journal.append(entry)
        return entry
    }

    // MARK: - Trash dropped sources

    /// Moves the dropped source files of a committed batch to the Trash (recoverable, never a hard delete).
    /// A source is only trashed if it still has exactly the content that was written to the project
    /// (hash == `sha_after`), is not the project file itself, and is not inside `.merge_backup`.
    /// Everything else is kept and reported. The journal batch gets a note per trashed file.
    @discardableResult
    public func trashSources(
        of changes: [PlannedChange],
        entry: JournalEntry,
        using trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [TrashOutcome] {
        var outcomes: [TrashOutcome] = []
        var seen = Set<String>()

        for c in changes {
            guard let rel = try? PathRules.validate(c.targetRelPath),
                  let op = entry.ops.first(where: { $0.path == rel }) else { continue }
            let src = c.source.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(src.path).inserted else { continue }
            let target = project.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()

            func keep(_ why: String) {
                outcomes.append(TrashOutcome(source: src.path, trashed: false, reason: why))
            }
            if src.path == target.path { keep("it is the project file itself"); continue }
            if src.path.hasPrefix(backupRoot.path + "/") { keep("it is inside the backup folder"); continue }
            guard fm.fileExists(atPath: src.path), let hash = try? Hashing.sha256(file: src) else {
                keep("it no longer exists")
                continue
            }
            if hash != op.shaAfter { keep("it changed after the commit"); continue }
            do {
                try trash(src)
                outcomes.append(TrashOutcome(source: src.path, trashed: true, reason: nil))
            } catch {
                keep(error.localizedDescription)
            }
        }

        let moved = outcomes.filter { $0.trashed }.map { "Source moved to Trash: \($0.source)" }
        if !moved.isEmpty {
            var updated = entry
            updated.notes += moved
            try? journal.append(updated)
        }
        return outcomes
    }

    // MARK: - Undo

    /// Restores each file from its verified backup (or deletes files the batch created).
    /// - Corrupt/missing backup: that file is skipped and reported, never restored from bad data.
    /// - Live file edited since the commit: skipped unless `force`.
    /// Undo is per file, so one bad backup never blocks the rest. Re-running only retries what's left.
    /// A `pending` batch (crash recovery) is rolled back the same way.
    public func undo(batch idOrPrefix: String, force: Bool = false) throws -> UndoReport {
        var entry = try journal.resolve(idOrPrefix)
        if entry.pruned == true { throw MergeError.backupsPruned(entry.batch) }
        guard entry.state == .committed || entry.state == .partiallyUndone || entry.state == .pending else {
            throw MergeError.notUndoable(batch: entry.batch, state: entry.state)
        }
        let wasPending = entry.state == .pending
        let (ops, results) = performRevert(entry, force: force)
        entry.ops = ops

        if ops.allSatisfy({ $0.undone == true }) {
            entry.state = wasPending ? .rolledBack : .undone
        } else {
            entry.state = .partiallyUndone
        }
        for r in results where r.outcome == .skippedCorruptBackup || r.outcome == .skippedModified || r.outcome == .failed {
            entry.notes.append("\(r.path): \(r.outcome.rawValue)" + (r.detail.map { " (\($0))" } ?? ""))
        }
        try journal.append(entry)
        return UndoReport(batch: entry.batch, results: results, finalState: entry.state)
    }

    /// Latest batch that can still be undone, if any.
    public func latestUndoable() -> JournalEntry? {
        journal.load().last { ($0.state == .committed || $0.state == .partiallyUndone || $0.state == .pending) && $0.pruned != true }
    }

    // MARK: - Prune

    /// Batches whose backups can be deleted: finished (committed, undone or rolled back), older than the cutoff,
    /// not already pruned. Interrupted and partly-undone batches are never touched.
    public func pruneCandidates(olderThanDays days: Int, now: Date = Date()) -> [JournalEntry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return journal.load().filter {
            $0.time < cutoff && $0.pruned != true
                && ($0.state == .committed || $0.state == .undone || $0.state == .rolledBack)
                && !$0.batch.contains("/") && !$0.batch.contains("..")
        }
    }

    /// Deletes the backup folders of old batches. The journal keeps the history, marked `pruned`; those batches can't be undone anymore.
    @discardableResult
    public func prune(olderThanDays days: Int, now: Date = Date()) throws -> PruneReport {
        var removed: [String] = []
        var freed: Int64 = 0
        for var entry in pruneCandidates(olderThanDays: days, now: now) {
            let dir = backupRoot.appendingPathComponent(entry.batch, isDirectory: true)
            freed += directorySize(dir)
            try? fm.removeItem(at: dir)
            entry.pruned = true
            entry.notes.append("Backups pruned")
            try journal.append(entry)
            removed.append(entry.batch)
        }
        return PruneReport(batches: removed, bytesFreed: freed)
    }

    private func directorySize(_ dir: URL) -> Int64 {
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - .gitignore

    /// Appends `.merge_backup/` to the project's .gitignore if it isn't there yet. Returns true if the file changed.
    @discardableResult
    public static func addToGitignore(project: URL) throws -> Bool {
        let file = project.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let covered = existing.split(whereSeparator: \.isNewline).contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == ".merge_backup" || t == ".merge_backup/" || t == "/.merge_backup" || t == "/.merge_backup/"
        }
        if covered { return false }
        var text = existing
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += ".merge_backup/\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Revert core

    func performRevert(_ entry: JournalEntry, force: Bool) -> ([JournalOp], [UndoOpResult]) {
        var ops = entry.ops
        var results: [UndoOpResult] = []

        for idx in ops.indices.reversed() {
            var op = ops[idx]
            if op.undone == true { continue }
            let target = project.appendingPathComponent(op.path)
            let exists = fm.fileExists(atPath: target.path)
            let current: String? = exists ? (try? Hashing.sha256(file: target)) : nil

            func finish(_ outcome: UndoOutcome, _ detail: String? = nil, done: Bool) {
                if done { op.undone = true }
                ops[idx] = op
                results.append(UndoOpResult(path: op.path, outcome: outcome, detail: detail))
            }

            switch op.op {
            case .create:
                if !exists {
                    finish(.alreadyOriginal, done: true)
                } else if current != op.shaAfter && !force {
                    finish(.skippedModified, "file was edited after the commit", done: false)
                } else {
                    do {
                        try fm.removeItem(at: target)
                        removeEmptyParents(of: target)
                        finish(.deleted, done: true)
                    } catch {
                        finish(.failed, error.localizedDescription, done: false)
                    }
                }

            case .replace:
                if exists, let before = op.shaBefore, current == before {
                    finish(.alreadyOriginal, done: true)
                    continue
                }
                // Backup integrity first: never restore from bad data.
                guard let rel = op.backup, let shaBefore = op.shaBefore else {
                    finish(.skippedCorruptBackup, "no backup recorded", done: false)
                    continue
                }
                let backupURL = project.appendingPathComponent(rel)
                guard let backupData = try? Data(contentsOf: backupURL) else {
                    finish(.skippedCorruptBackup, "backup file missing", done: false)
                    continue
                }
                guard Hashing.sha256(data: backupData) == shaBefore else {
                    finish(.skippedCorruptBackup, "backup hash does not match the journal", done: false)
                    continue
                }
                // Then the live file: has anyone edited it since?
                if exists, current != op.shaAfter, !force {
                    finish(.skippedModified, "file was edited after the commit", done: false)
                    continue
                }
                do {
                    try Self.atomicWrite(backupData, to: target, attributesFrom: exists ? target : nil)
                    guard try Hashing.sha256(file: target) == shaBefore else {
                        finish(.failed, "restored file did not verify", done: false)
                        continue
                    }
                    finish(.restored, done: true)
                } catch {
                    finish(.failed, error.localizedDescription, done: false)
                }
            }
        }
        return (ops, results)
    }

    // MARK: - Helpers

    private func uniqueBatchId(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = f.string(from: date)
        var id = base
        var n = 2
        while fm.fileExists(atPath: backupRoot.appendingPathComponent(id).path)
                || journal.load().contains(where: { $0.batch == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    private func ensureInsideProject(_ target: URL) throws {
        let dir = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        if dir != project.path && !dir.hasPrefix(project.path + "/") {
            throw MergeError.invalidPath(target.path)
        }
    }

    private func removeEmptyParents(of url: URL) {
        var dir = url.deletingLastPathComponent()
        while dir.path.hasPrefix(project.path + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty else { break }
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Temp file in the same directory, copy permissions, then swap in. Readers never see a half-written file.
    static func atomicWrite(_ data: Data, to url: URL, attributesFrom: URL?) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".filipendula-\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if let src = attributesFrom,
           let attrs = try? fm.attributesOfItem(atPath: src.path),
           let perms = attrs[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
