import XCTest
@testable import MergeCore

final class OperationsEdgeTests: TempProjectTestCase {

    private func make(_ rel: String, source: URL, status: MergeStatus = .additions, addNew: Bool = false) -> PlannedChange {
        var c = PlannedChange(source: source, targetRelPath: rel, matchKind: .manual, candidates: [],
                              classification: Classification(status: status, added: 1, removed: 0, oldLineCount: 1),
                              conflict: false, issue: nil)
        c.addNew = addNew
        return c
    }

    // MARK: Refusals

    func testNothingToApplyWhenEverythingIsIdentical() throws {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\n")
        XCTAssertThrowsError(try Operations(project: project).apply(plan(source))) { error in
            guard case MergeError.nothingToApply = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertTrue(Operations(project: project).journal.load().isEmpty)
    }

    func testDuplicateTargetsAreRefusedBeforeAnythingIsWritten() throws {
        try inProject("a.txt", "a\n")
        let one = try inInbox("1.txt", "a\nb\n")
        let two = try inInbox("2.txt", "a\nc\n")
        let changes = [make("a.txt", source: one), make("A.TXT", source: two)]
        XCTAssertThrowsError(try Operations(project: project).apply(changes)) { error in
            guard case MergeError.duplicateTarget = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(read("a.txt"), "a\n")
    }

    func testUnsafeTargetPathsAreRefused() throws {
        let source = try inInbox("x.txt", "x\n")
        for rel in ["../x.txt", "/tmp/x.txt", ".git/config", ".merge_backup/x"] {
            XCTAssertThrowsError(try Operations(project: project).apply([make(rel, source: source, status: .new, addNew: true)]), rel) { error in
                guard case MergeError.invalidPath = error else { return XCTFail("wrong error for \(rel): \(error)") }
            }
        }
        XCTAssertTrue(Operations(project: project).journal.load().isEmpty)
    }

    func testAFolderIsNeverOverwritten() throws {
        try inProject("sub/file.txt", "x\n")
        let source = try inInbox("sub", "x\n")
        XCTAssertThrowsError(try Operations(project: project).apply([make("sub", source: source)])) { error in
            guard case MergeError.invalidPath = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(read("sub/file.txt"), "x\n")
    }

    func testASymlinkedFolderCannotLeadOutOfTheProject() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: outside)
        let source = try inInbox("f.txt", "x\n")
        XCTAssertThrowsError(try Operations(project: project).apply([make("escape/f.txt", source: source, status: .new, addNew: true)])) { error in
            guard case MergeError.invalidPath = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("f.txt").path))
    }

    func testAPlanThatGotBetterIsStillApplied() throws {
        try inProject("a.txt", "a\nb\n")
        let source = try inInbox("a.txt", "a\nc\n")
        let planned = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(planned.status, .heavyLoss)
        // The project file changes so that the update only adds lines now.
        try inProject("a.txt", "a\n")
        let entry = try Operations(project: project).apply([planned])
        XCTAssertEqual(entry.ops.first?.status, .additions, "the commit records the status it was applied with")
        XCTAssertEqual(read("a.txt"), "a\nc\n")
    }

    // MARK: What a commit records

    func testJournalRecordsHashesAndCounts() throws {
        try inProject("a.txt", "a\nb\n")
        let source = try inInbox("a.txt", "a\nb\nc\n")
        let entry = try Operations(project: project).apply(plan(source))
        let op = try XCTUnwrap(entry.ops.first)
        XCTAssertEqual(op.op, .replace)
        XCTAssertEqual(op.shaBefore, Hashing.sha256(data: Data("a\nb\n".utf8)))
        XCTAssertEqual(op.shaAfter, Hashing.sha256(data: Data("a\nb\nc\n".utf8)))
        XCTAssertEqual(op.status, .additions)
        XCTAssertEqual(op.added, 1)
        XCTAssertEqual(op.removed, 0)
        XCTAssertEqual(entry.state, .committed)
    }

    func testBinaryFilesAreReplacedByteForByteAndBackedUp() throws {
        let before = Data([0, 1, 2, 3]), after = Data([0, 9, 9])
        try before.write(to: project.appendingPathComponent("b.bin"))
        try after.write(to: inbox.appendingPathComponent("b.bin"))
        let ops = Operations(project: project)
        let entry = try ops.apply(plan(inbox.appendingPathComponent("b.bin")))
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("b.bin")), after)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(try XCTUnwrap(entry.ops[0].backup))), before)
        _ = try ops.undo(batch: entry.batch)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("b.bin")), before)
    }

    func testFilePermissionsSurviveAReplace() throws {
        let live = try inProject("run.sh", "echo a\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: live.path)
        let source = try inInbox("run.sh", "echo a\necho b\n")
        _ = try Operations(project: project).apply(plan(source))
        let perms = try FileManager.default.attributesOfItem(atPath: live.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o755)
    }

    func testNoTemporaryFilesAreLeftBehind() throws {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        _ = try Operations(project: project).apply(plan(source))
        let leftovers = ProjectScanner.regularFiles(in: project).filter { $0.rel.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testTwoBatchesInTheSameSecondGetDistinctIds() throws {
        try inProject("a.txt", "a\n")
        let ops = Operations(project: project)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try ops.apply(plan(try inInbox("a.txt", "a\nb\n")), now: when)
        let second = try ops.apply(plan(try inInbox("a.txt", "a\nb\nc\n")), now: when)
        XCTAssertNotEqual(first.batch, second.batch)
        XCTAssertTrue(second.batch.hasPrefix(first.batch))
    }

    // MARK: Looking batches up and undoing them

    func testUnknownAndAmbiguousBatchIds() throws {
        try inProject("a.txt", "a\n")
        let ops = Operations(project: project)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try ops.apply(plan(try inInbox("a.txt", "a\nb\n")), now: when)
        _ = try ops.apply(plan(try inInbox("a.txt", "a\nb\nc\n")), now: when)

        XCTAssertThrowsError(try ops.undo(batch: "nope")) { error in
            guard case MergeError.noSuchBatch = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertThrowsError(try ops.undo(batch: String(first.batch.prefix(4)))) { error in
            guard case MergeError.ambiguousBatch = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(try ops.journal.resolve(first.batch).batch, first.batch, "an exact id always wins over a prefix")
    }

    func testUndoneBatchesCannotBeUndoneTwice() throws {
        try inProject("a.txt", "a\n")
        let ops = Operations(project: project)
        let entry = try ops.apply(plan(try inInbox("a.txt", "a\nb\n")))
        _ = try ops.undo(batch: entry.batch)
        XCTAssertThrowsError(try ops.undo(batch: entry.batch)) { error in
            guard case MergeError.notUndoable = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testLatestUndoableSkipsUndoneBatches() throws {
        try inProject("a.txt", "a\n")
        let ops = Operations(project: project)
        XCTAssertNil(ops.latestUndoable())
        let first = try ops.apply(plan(try inInbox("a.txt", "a\nb\n")))
        let second = try ops.apply(plan(try inInbox("a.txt", "a\nb\nc\n")))
        XCTAssertEqual(ops.latestUndoable()?.batch, second.batch)
        _ = try ops.undo(batch: second.batch)
        XCTAssertEqual(ops.latestUndoable()?.batch, first.batch)
    }

    func testUndoingAFileThatIsAlreadyBackToItsOriginal() throws {
        let live = try inProject("a.txt", "a\n")
        let ops = Operations(project: project)
        let entry = try ops.apply(plan(try inInbox("a.txt", "a\nb\n")))
        try "a\n".write(to: live, atomically: true, encoding: .utf8)         // restored by hand
        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.results.first?.outcome, .alreadyOriginal)
        XCTAssertEqual(report.finalState, .undone)
    }

    func testEditedCreatedFileNeedsForceToBeDeleted() throws {
        let source = try inInbox("n.txt", "new\n")
        var c = try XCTUnwrap(plan(source).first)
        c.addNew = true
        let ops = Operations(project: project)
        let entry = try ops.apply([c])
        try inProject("n.txt", "edited later\n")

        let first = try ops.undo(batch: entry.batch)
        XCTAssertEqual(first.results.first?.outcome, .skippedModified)
        XCTAssertTrue(exists("n.txt"))
        let second = try ops.undo(batch: entry.batch, force: true)
        XCTAssertEqual(second.results.first?.outcome, .deleted)
        XCTAssertFalse(exists("n.txt"))
    }

    func testUndoOfACreatedFileThatIsAlreadyGone() throws {
        let source = try inInbox("n.txt", "new\n")
        var c = try XCTUnwrap(plan(source).first)
        c.addNew = true
        let ops = Operations(project: project)
        let entry = try ops.apply([c])
        try FileManager.default.removeItem(at: project.appendingPathComponent("n.txt"))
        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.results.first?.outcome, .alreadyOriginal)
        XCTAssertEqual(report.finalState, .undone)
    }

    func testMixedBatchUndoRestoresReplacedAndDeletesCreated() throws {
        try inProject("a.txt", "a\n")
        let a = try inInbox("a.txt", "a\nb\n")
        let n = try inInbox("n.txt", "new\n")
        var changes = plan(a, n)
        changes[1].addNew = true
        let ops = Operations(project: project)
        let entry = try ops.apply(changes)
        XCTAssertEqual(Set(entry.ops.map(\.op)), [.replace, .create])
        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.finalState, .undone)
        XCTAssertEqual(read("a.txt"), "a\n")
        XCTAssertFalse(exists("n.txt"))
    }

    // MARK: Trash

    private func committed() throws -> (Operations, [PlannedChange], JournalEntry, URL) {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        let changes = plan(source)
        let ops = Operations(project: project)
        return (ops, changes, try ops.apply(changes), source)
    }

    func testTrashFailureKeepsTheSourceAndSaysWhy() throws {
        let (ops, changes, entry, _) = try committed()
        let outcomes = ops.trashSources(of: changes, entry: entry) { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Trash is full"])
        }
        XCTAssertEqual(outcomes.first?.trashed, false)
        XCTAssertEqual(outcomes.first?.reason, "Trash is full")
        let notes = ops.journal.load().first?.notes ?? []
        XCTAssertFalse(notes.contains { $0.hasPrefix("Source moved to Trash") })
    }

    func testMissingSourceIsKept() throws {
        let (ops, changes, entry, source) = try committed()
        try FileManager.default.removeItem(at: source)
        var calls = 0
        let outcomes = ops.trashSources(of: changes, entry: entry) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(outcomes.first?.reason, "it no longer exists")
    }

    func testSourcesInsideTheBackupFolderAreNeverTrashed() throws {
        let (ops, changes, entry, _) = try committed()
        let backup = project.appendingPathComponent(try XCTUnwrap(entry.ops[0].backup))
        let original = changes[0]
        let c = PlannedChange(source: backup, targetRelPath: original.targetRelPath, matchKind: original.matchKind,
                              candidates: [], classification: original.classification, conflict: false, issue: nil)
        var calls = 0
        let outcomes = ops.trashSources(of: [c], entry: entry) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(outcomes.first?.reason, "it is inside the backup folder")
    }

    func testTheSameSourceIsTrashedOnce() throws {
        let (ops, changes, entry, _) = try committed()
        var calls = 0
        let outcomes = ops.trashSources(of: changes + changes, entry: entry) { _ in calls += 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testChangesThatWereNotCommittedAreNotTrashed() throws {
        let (ops, _, entry, _) = try committed()
        let stranger = try inInbox("other.txt", "x\n")
        var calls = 0
        let outcomes = ops.trashSources(of: [make("other.txt", source: stranger)], entry: entry) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }
}

final class JournalTests: TempProjectTestCase {
    private func entry(_ id: String, _ state: BatchState = .committed) -> JournalEntry {
        JournalEntry(batch: id, state: state, time: Date(timeIntervalSince1970: 1_700_000_000), ops: [], notes: [])
    }

    private var journal: Journal { Journal(directory: project.appendingPathComponent(".merge_backup")) }

    func testEmptyJournal() {
        XCTAssertTrue(journal.load().isEmpty)
        XCTAssertTrue(journal.pending().isEmpty)
    }

    func testLatestSnapshotWinsAndOrderIsFirstAppearance() throws {
        let j = journal
        try j.append(entry("b1", .pending))
        try j.append(entry("b2"))
        try j.append(entry("b1", .committed))
        let all = j.load()
        XCTAssertEqual(all.map(\.batch), ["b1", "b2"])
        XCTAssertEqual(all.map(\.state), [.committed, .committed])
        XCTAssertTrue(j.pending().isEmpty)
    }

    func testGarbageLinesAreSkipped() throws {
        let j = journal
        try j.append(entry("b1"))
        let h = try FileHandle(forWritingTo: j.fileURL)
        try h.seekToEnd()
        try h.write(contentsOf: Data("not json at all\n{\"batch\":\n".utf8))
        try h.close()
        try j.append(entry("b2"))
        XCTAssertEqual(j.load().map(\.batch), ["b1", "b2"])
    }

    func testAppendAfterATruncatedLineStartsAFreshLine() throws {
        let j = journal
        try j.append(entry("b1"))
        let h = try FileHandle(forWritingTo: j.fileURL)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"batch\":\"cut".utf8))      // no newline: a crash mid-write
        try h.close()
        try j.append(entry("b2"))
        XCTAssertEqual(j.load().map(\.batch), ["b1", "b2"])
    }

    func testResolveByExactIdAndPrefix() throws {
        let j = journal
        try j.append(entry("20270101-100000"))
        try j.append(entry("20270101-100000-2"))
        try j.append(entry("20270202-090000"))
        XCTAssertEqual(try j.resolve("20270101-100000").batch, "20270101-100000")
        XCTAssertEqual(try j.resolve("2027020").batch, "20270202-090000")
        XCTAssertThrowsError(try j.resolve("2027")) { error in
            guard case MergeError.ambiguousBatch = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertThrowsError(try j.resolve("1999")) { error in
            guard case MergeError.noSuchBatch = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testPendingBatchesAreListed() throws {
        let j = journal
        try j.append(entry("b1", .pending))
        try j.append(entry("b2", .committed))
        XCTAssertEqual(j.pending().map(\.batch), ["b1"])
    }

    func testEntriesRoundTripIncludingOps() throws {
        let j = journal
        var e = entry("b1")
        e.ops = [JournalOp(op: .replace, path: "Dir/File.swift", backup: ".merge_backup/b1/Dir/File.swift",
                           shaBefore: "aa", shaAfter: "bb", status: .modified, added: 3, removed: 1, undone: nil),
                 JournalOp(op: .create, path: "n.txt", backup: nil, shaBefore: nil, shaAfter: "cc",
                           status: .new, added: 2, removed: 0, undone: true)]
        e.notes = ["Not in project, not added: x.txt"]
        e.pruned = true
        try j.append(e)
        XCTAssertEqual(j.load().first, e, "mixed-case paths must survive the snake_case key strategy")
    }
}
