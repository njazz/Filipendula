import XCTest
@testable import MergeCore

final class NewFileAndTrashTests: XCTestCase {
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
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: New files are not added unless allowed

    func testOnlyNewFilesAreRefusedAndNothingIsWritten() throws {
        try write("x\n", inbox.appendingPathComponent("fresh.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("fresh.txt")])
        XCTAssertEqual(plan[0].status, .new)

        let ops = Operations(project: project)
        XCTAssertThrowsError(try ops.apply(plan)) { error in
            guard case MergeError.newFilesNotAllowed(let n) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(n, 1)
        }
        XCTAssertFalse(exists(project.appendingPathComponent("fresh.txt")))
        XCTAssertTrue(ops.journal.load().isEmpty)
    }

    func testMixedBatchSkipsNewFilesAndSaysSo() throws {
        try write("a\n", project.appendingPathComponent("a.txt"))
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        try write("x\n", inbox.appendingPathComponent("fresh.txt"))

        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt"),
                                                            inbox.appendingPathComponent("fresh.txt")])
        let entry = try Operations(project: project).apply(plan)

        XCTAssertEqual(entry.ops.map { $0.path }, ["a.txt"])
        XCTAssertFalse(exists(project.appendingPathComponent("fresh.txt")))
        XCTAssertTrue(entry.notes.contains { $0.hasPrefix("Not in project, not added:") && $0.hasSuffix("fresh.txt") })
    }

    func testNewFilesAreCreatedWhenAllowed() throws {
        try write("x\n", inbox.appendingPathComponent("fresh.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("fresh.txt")])
        _ = try Operations(project: project).apply(plan, allowNew: true)
        XCTAssertTrue(exists(project.appendingPathComponent("fresh.txt")))
    }

    func testOriginalDeletedAfterPlanningIsNotRecreated() throws {
        let live = project.appendingPathComponent("a.txt")
        try write("a\n", live)
        try write("a\nb\n", inbox.appendingPathComponent("a.txt"))
        let plan = Planner(project: project).plan(sources: [inbox.appendingPathComponent("a.txt")])
        XCTAssertEqual(plan[0].status, .additions)

        try FileManager.default.removeItem(at: live)
        XCTAssertThrowsError(try Operations(project: project).apply(plan))
        XCTAssertFalse(exists(live))
    }

    // MARK: Trash

    private func committed(_ sourceText: String = "a\nb\n") throws -> (Operations, [PlannedChange], JournalEntry, URL) {
        try write("a\n", project.appendingPathComponent("a.txt"))
        let source = inbox.appendingPathComponent("a.txt")
        try write(sourceText, source)
        let plan = Planner(project: project).plan(sources: [source])
        let ops = Operations(project: project)
        let entry = try ops.apply(plan)
        return (ops, plan, entry, source)
    }

    func testMergedSourceIsTrashedAndNoted() throws {
        let (ops, plan, entry, source) = try committed()
        var trashed: [String] = []
        let outcomes = ops.trashSources(of: plan, entry: entry) { trashed.append($0.lastPathComponent) }

        XCTAssertEqual(trashed, ["a.txt"])
        XCTAssertEqual(outcomes.map { $0.trashed }, [true])
        XCTAssertTrue(ops.journal.load().first!.notes.contains { $0.hasPrefix("Source moved to Trash:") })
        XCTAssertTrue(exists(source))   // the fake trash closure didn't really move it
    }

    func testSourceChangedAfterCommitIsKept() throws {
        let (ops, plan, entry, source) = try committed()
        try write("edited after commit\n", source)
        var trashed = 0
        let outcomes = ops.trashSources(of: plan, entry: entry) { _ in trashed += 1 }
        XCTAssertEqual(trashed, 0)
        XCTAssertEqual(outcomes.first?.trashed, false)
        XCTAssertEqual(outcomes.first?.reason, "it changed after the commit")
    }

    func testProjectFileItselfIsNeverTrashed() throws {
        // Dropping the project's own file onto the project: after a commit the "source" is the target.
        let live = project.appendingPathComponent("a.txt")
        try write("a\n", live)
        let (ops, plan, entry, _) = try committed()
        var fake = plan[0]
        fake = PlannedChange(source: live, targetRelPath: fake.targetRelPath, matchKind: fake.matchKind,
                             candidates: [], classification: fake.classification, conflict: false, issue: nil)
        var trashed = 0
        let outcomes = ops.trashSources(of: [fake], entry: entry) { _ in trashed += 1 }
        XCTAssertEqual(trashed, 0)
        XCTAssertEqual(outcomes.first?.reason, "it is the project file itself")
    }

    func testVersionLooksLikeSemver() {
        let parts = FilipendulaInfo.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
