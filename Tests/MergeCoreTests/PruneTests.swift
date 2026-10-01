import XCTest
@testable import MergeCore

final class PruneTests: XCTestCase {
    var root: URL!
    var project: URL!
    var inbox: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("filipendula-\(UUID().uuidString)")
        project = root.appendingPathComponent("proj")
        inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ s: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    func testPruneRemovesOnlyOldBatchesAndBlocksUndo() throws {
        try write("a\n", project.appendingPathComponent("a.txt"))
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        let ops = Operations(project: project)
        let old = Date().addingTimeInterval(-100 * 86_400)
        let oldEntry = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]), now: old)

        try write("a\nb\nc\n", inbox.appendingPathComponent("a.txt"))
        let recent = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]))

        XCTAssertEqual(ops.pruneCandidates(olderThanDays: 30).map(\.batch), [oldEntry.batch])
        let report = try ops.prune(olderThanDays: 30)
        XCTAssertEqual(report.batches, [oldEntry.batch])
        XCTAssertGreaterThan(report.bytesFreed, 0)

        let backupDir = ops.backupRoot.appendingPathComponent(oldEntry.batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir.path))
        XCTAssertThrowsError(try ops.undo(batch: oldEntry.batch))
        XCTAssertEqual(ops.latestUndoable()?.batch, recent.batch)
        XCTAssertEqual(ops.journal.load().first?.pruned, true)
        XCTAssertNoThrow(try ops.undo(batch: recent.batch))
    }

    func testPendingBatchesAreNeverPruned() throws {
        try write("a\n", project.appendingPathComponent("a.txt"))
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        let ops = Operations(project: project)
        let entry = try ops.apply(Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")]),
                                  now: Date().addingTimeInterval(-100 * 86_400))
        var pending = entry
        pending.state = .pending
        try ops.journal.append(pending)
        XCTAssertTrue(ops.pruneCandidates(olderThanDays: 30).isEmpty)
    }

    func testGitignoreIsAddedOnce() throws {
        XCTAssertTrue(try Operations.addToGitignore(project: project))
        XCTAssertFalse(try Operations.addToGitignore(project: project))
        let text = try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(text, ".merge_backup/\n")
    }

    func testGitignoreKeepsExistingContent() throws {
        try write("node_modules", project.appendingPathComponent(".gitignore"))   // no trailing newline
        XCTAssertTrue(try Operations.addToGitignore(project: project))
        let text = try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(text, "node_modules\n.merge_backup/\n")
    }
}
