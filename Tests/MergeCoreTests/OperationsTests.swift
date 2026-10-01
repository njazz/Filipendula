import XCTest
@testable import MergeCore

final class OperationsTests: XCTestCase {
    var root: URL!
    var project: URL!
    var inbox: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filipendula-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj")
        inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ s: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: - Planning

    func testUniqueNameMatchAndClassification() throws {
        try write("a\nb\n", project.appendingPathComponent("src/a.txt"))
        try write("a\nb\nc\n", inbox.appendingPathComponent("a.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].targetRelPath, "src/a.txt")
        XCTAssertEqual(plan[0].matchKind, .uniqueName)
        XCTAssertEqual(plan[0].status, .additions)
    }

    func testAmbiguousNameRanksBySimilarity() throws {
        try write("one\ntwo\nthree\n", project.appendingPathComponent("x/util.txt"))
        try write("alpha\nbeta\ngamma\n", project.appendingPathComponent("y/util.txt"))
        try write("alpha\nbeta\ngamma\ndelta\n", inbox.appendingPathComponent("util.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("util.txt")])
        XCTAssertEqual(plan[0].matchKind, .ambiguous)
        XCTAssertEqual(plan[0].candidates.count, 2)
        XCTAssertEqual(plan[0].targetRelPath, "y/util.txt")
    }

    func testDroppedFolderMirrorsProjectStructure() throws {
        try write("a\n", project.appendingPathComponent("src/a.txt"))
        try write("a\n", project.appendingPathComponent("lib/a.txt"))   // same name elsewhere
        try write("a\nb\n", inbox.appendingPathComponent("drop/lib/a.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("drop")])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].targetRelPath, "lib/a.txt")
        XCTAssertEqual(plan[0].matchKind, .path)
    }

    func testNewFileDefaultsToProjectRoot() throws {
        try write("hello\n", inbox.appendingPathComponent("fresh.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("fresh.txt")])
        XCTAssertEqual(plan[0].status, .new)
        XCTAssertEqual(plan[0].targetRelPath, "fresh.txt")
    }

    func testPathRulesRejectTraversalAndProtectedDirs() {
        XCTAssertThrowsError(try PathRules.validate("../evil.txt"))
        XCTAssertThrowsError(try PathRules.validate("/etc/passwd"))
        XCTAssertThrowsError(try PathRules.validate(".git/config"))
        XCTAssertThrowsError(try PathRules.validate(".merge_backup/x"))
        XCTAssertEqual(try PathRules.validate("a//b/c.txt"), "a/b/c.txt")
    }

    // MARK: - Apply / undo

    func testApplyThenUndoRestoresOriginal() throws {
        let live = project.appendingPathComponent("src/a.txt")
        try write("a\nb\n", live)
        try write("a\nb\nc\n", inbox.appendingPathComponent("a.txt"))

        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")])
        let ops = Operations(project: project)
        let entry = try ops.apply(plan)

        XCTAssertEqual(entry.state, .committed)
        XCTAssertEqual(read(live), "a\nb\nc\n")
        let backup = project.appendingPathComponent(entry.ops[0].backup!)
        XCTAssertEqual(read(backup), "a\nb\n")

        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.finalState, .undone)
        XCTAssertEqual(read(live), "a\nb\n")
        XCTAssertEqual(ops.journal.load().first?.state, .undone)
    }

    func testCreateIsUndoneByDeleting() throws {
        try write("hi\n", inbox.appendingPathComponent("new.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("new.txt")])
        let ops = Operations(project: project)
        let entry = try ops.apply(plan, allowNew: true)
        let live = project.appendingPathComponent("new.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))

        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.results.first?.outcome, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testCorruptBackupIsSkippedAndLiveFileUntouched() throws {
        let live = project.appendingPathComponent("a.txt")
        try write("a\nb\n", live)
        try write("a\nb\nc\n", inbox.appendingPathComponent("a.txt"))
        let ops = Operations(project: project)
        let entry = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]))

        // corrupt the backup
        try write("garbage", project.appendingPathComponent(entry.ops[0].backup!))

        let report = try ops.undo(batch: entry.batch, force: true)   // even force must not use a bad backup
        XCTAssertEqual(report.results.first?.outcome, .skippedCorruptBackup)
        XCTAssertEqual(report.finalState, .partiallyUndone)
        XCTAssertEqual(read(live), "a\nb\nc\n")
    }

    func testPerFileUndoOneBadBackupDoesNotBlockTheRest() throws {
        try write("1\n", project.appendingPathComponent("one.txt"))
        try write("2\n", project.appendingPathComponent("two.txt"))
        try write("1\nx\n", inbox.appendingPathComponent("one.txt"))
        try write("2\ny\n", inbox.appendingPathComponent("two.txt"))
        let ops = Operations(project: project)
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("one.txt"),
                                                            inbox.appendingPathComponent("two.txt")])
        let entry = try ops.apply(plan)
        let oneOp = entry.ops.first { $0.path == "one.txt" }!
        try write("garbage", project.appendingPathComponent(oneOp.backup!))

        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.finalState, .partiallyUndone)
        XCTAssertEqual(read(project.appendingPathComponent("two.txt")), "2\n")
        XCTAssertEqual(read(project.appendingPathComponent("one.txt")), "1\nx\n")
    }

    func testEditedAfterCommitNeedsForce() throws {
        let live = project.appendingPathComponent("a.txt")
        try write("a\n", live)
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        let ops = Operations(project: project)
        let entry = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]))

        try write("my own later edit\n", live)

        let first = try ops.undo(batch: entry.batch)
        XCTAssertEqual(first.results.first?.outcome, .skippedModified)
        XCTAssertEqual(read(live), "my own later edit\n")
        XCTAssertEqual(first.finalState, .partiallyUndone)

        let second = try ops.undo(batch: entry.batch, force: true)
        XCTAssertEqual(second.finalState, .undone)
        XCTAssertEqual(read(live), "a\n")
    }

    func testStalePlanIsRefused() throws {
        let live = project.appendingPathComponent("a.txt")
        try write("a\nb\n", live)
        try write("a\nb\nc\n", inbox.appendingPathComponent("a.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")])
        XCTAssertEqual(plan[0].status, .additions)

        // project file gains unrelated lines after planning => new content now *removes* them
        try write("a\nb\nextra\nlines\n", live)
        XCTAssertThrowsError(try Operations(project: project).apply(plan))
        XCTAssertEqual(read(live), "a\nb\nextra\nlines\n")
    }

    func testPendingBatchCanBeRolledBack() throws {
        let live = project.appendingPathComponent("a.txt")
        try write("a\n", live)
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        let ops = Operations(project: project)
        let entry = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]))

        // simulate a crash: journal says pending although the write happened
        var crashed = entry
        crashed.state = .pending
        try ops.journal.append(crashed)
        XCTAssertEqual(ops.journal.pending().count, 1)

        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.finalState, .rolledBack)
        XCTAssertEqual(read(live), "a\n")
    }

    func testJournalToleratesTruncatedLastLine() throws {
        let ops = Operations(project: project)
        try write("a\n", project.appendingPathComponent("a.txt"))
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        _ = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]))

        let handle = try FileHandle(forWritingTo: ops.journal.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"batch\":\"broken".utf8))
        try handle.close()

        XCTAssertEqual(ops.journal.load().count, 1)
    }
}
