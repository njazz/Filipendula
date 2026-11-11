import XCTest
@testable import MergeCore

final class PlannerEdgeTests: TempProjectTestCase {

    // MARK: What gets planned

    func testMissingSourcesAreIgnored() {
        XCTAssertTrue(plan(inbox.appendingPathComponent("ghost.txt")).isEmpty)
    }

    func testTheSameFileDroppedTwiceIsPlannedOnce() throws {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        XCTAssertEqual(plan(source, source).count, 1)
    }

    func testAFileAndItsFolderTogetherAreDeduplicated() throws {
        try inProject("a.txt", "a\n")
        let file = try inInbox("drop/a.txt", "a\nb\n")
        let result = plan(file, inbox.appendingPathComponent("drop"))
        XCTAssertEqual(result.count, 1)
    }

    func testIgnoredFoldersInsideADroppedFolderAreNotPlanned() throws {
        try inProject("a.txt", "a\n")
        try inInbox("drop/a.txt", "a\nb\n")
        try inInbox("drop/node_modules/pkg/x.js", "x\n")
        try inInbox("drop/.git/config", "x\n")
        try inInbox("drop/.DS_Store", "x\n")
        let result = plan(inbox.appendingPathComponent("drop"))
        XCTAssertEqual(result.map { $0.source.lastPathComponent }, ["a.txt"])
    }

    func testSymlinksInsideADroppedFolderAreSkipped() throws {
        try inProject("a.txt", "a\n")
        try inInbox("drop/a.txt", "a\nb\n")
        try FileManager.default.createSymbolicLink(at: inbox.appendingPathComponent("drop/link.txt"),
                                                   withDestinationURL: inbox.appendingPathComponent("drop/a.txt"))
        XCTAssertEqual(plan(inbox.appendingPathComponent("drop")).count, 1)
    }

    func testProjectGivenThroughASymlinkStillProducesRelativePaths() throws {
        try inProject("src/a.txt", "a\n")
        let link = root.appendingPathComponent("link-to-proj")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        let source = try inInbox("a.txt", "a\nb\n")
        let result = Planner(project: link).plan(sources: [source])
        XCTAssertEqual(result.first?.targetRelPath, "src/a.txt")
    }

    // MARK: Folder drops: root layout or sub-folder layout?

    func testWhenBothLayoutsMatchEquallyTheFolderIsASubfolder() throws {
        try inProject("a.txt", "x\n")
        try inProject("lib/a.txt", "y\n")
        try inInbox("lib/a.txt", "y\nz\n")
        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("lib")).first)
        XCTAssertEqual(c.targetRelPath, "lib/a.txt")
        XCTAssertEqual(c.matchKind, .path)
    }

    func testTheLayoutWithMoreMatchesWins() throws {
        try inProject("a.txt", "decoy\n")               // matches "a.txt" if the folder mirrors the project root
        try inProject("lib/a.txt", "a\n")
        try inProject("lib/b.txt", "b\n")              // but two files match if the folder is the sub-folder "lib"
        try inInbox("lib/a.txt", "a\nx\n")
        try inInbox("lib/b.txt", "b\nx\n")
        let result = plan(inbox.appendingPathComponent("lib"))
        XCTAssertEqual(Set(result.map(\.targetRelPath)), ["lib/a.txt", "lib/b.txt"])
        XCTAssertTrue(result.allSatisfy { $0.matchKind == .path })
    }

    func testFilesAtTheTopOfAFolderThatMirrorsTheRoot() throws {
        try inProject("readme.txt", "r\n")
        try inProject("lib/a.txt", "a\n")
        try inInbox("drop/readme.txt", "r\nmore\n")
        try inInbox("drop/lib/a.txt", "a\nmore\n")
        let result = plan(inbox.appendingPathComponent("drop"))
        XCTAssertEqual(Set(result.map(\.targetRelPath)), ["readme.txt", "lib/a.txt"])
        XCTAssertTrue(result.allSatisfy { $0.matchKind == .path })
    }

    // MARK: Classification through the planner

    func testBinaryFiles() throws {
        try Data([0, 1, 2]).write(to: project.appendingPathComponent("blob.bin"))
        try Data([0, 1, 3]).write(to: inbox.appendingPathComponent("blob.bin"))
        try Data([0, 1, 2]).write(to: inbox.appendingPathComponent("same.bin"))
        try Data([0, 1, 2]).write(to: project.appendingPathComponent("same.bin"))
        let result = plan(inbox.appendingPathComponent("blob.bin"), inbox.appendingPathComponent("same.bin"))
        XCTAssertEqual(result.map(\.status), [.binary, .identical])
    }

    func testStrictWhitespaceOptionReachesThePlanner() throws {
        try inProject("a.txt", "a\nb\n")
        let source = try inInbox("a.txt", "a  \nb\n")
        XCTAssertEqual(plan(source).first?.status, .identical)
        XCTAssertNotEqual(plan(source, options: ClassifierOptions(ignoreTrailingWhitespace: false)).first?.status, .identical)
    }

    func testLossThresholdOptionReachesThePlanner() throws {
        try inProject("a.txt", numbered("l", 10))
        let source = try inInbox("a.txt", numbered("l", 8) + "x\n")      // 2 removed (20 %), 1 added
        XCTAssertEqual(plan(source).first?.status, .modified)
        XCTAssertEqual(plan(source, options: ClassifierOptions(lossThreshold: 0.1)).first?.status, .heavyLoss)
    }

    func testEmptySourceOverAFileIsOnlyDeletions() throws {
        try inProject("a.txt", "a\nb\n")
        let source = try inInbox("a.txt", "")
        XCTAssertEqual(plan(source).first?.status, .deletionsOnly)
    }

    func testUnreadableSourceIsReportedNotApplied() throws {
        try XCTSkipIf(getuid() == 0, "permissions are not enforced for root")
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }

        let c = try XCTUnwrap(plan(source).first)
        XCTAssertNotNil(c.issue)
        XCTAssertThrowsError(try Operations(project: project).apply([c]))
    }

    // MARK: Dates

    func testTargetDateIsFilledOnlyForExistingTargets() throws {
        try inProject("a.txt", "a\n")
        let a = try inInbox("a.txt", "a\nb\n")
        let n = try inInbox("n.txt", "new\n")
        let result = plan(a, n)
        XCTAssertNotNil(result[0].targetModified)
        XCTAssertNotNil(result[0].sourceModified)
        XCTAssertNil(result[1].targetModified)
        XCTAssertNotNil(result[1].sourceModified)
    }

    func testTargetDateIsThatOfTheChosenCandidate() throws {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let a = try inProject("a/f.txt", numbered("x", 6))
        try inProject("b/f.txt", numbered("y", 6))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path)
        let source = try inInbox("f.txt", numbered("x", 6) + "z\n")
        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.targetRelPath, "a/f.txt")
        XCTAssertEqual(try XCTUnwrap(c.targetModified).timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(c.dateRelation, .sourceNewer)
    }

    // MARK: JSON (the CLI's `plan --json`)

    func testPlansEncodeToJSONWithTheNewFields() throws {
        let body = numbered("line", 6)
        try inProject("x/Util.txt", body)
        try inProject("y/Util.txt", body)
        let ambiguous = try inInbox("y/Util.txt", body + "more\n")
        let fresh = try inInbox("Fresh.txt", "new\n")
        let changes = plan(ambiguous, fresh)

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(changes), as: UTF8.self)
        for key in ["candidate_scores", "folder_match", "suggestions", "add_new", "similarity", "target_rel_path"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing \(key)")
        }
        XCTAssertTrue(json.contains("y/Util.txt"), "paths are values and must not be rewritten")
        XCTAssertTrue(json.contains("projectRoot"), "enum values are not key-converted")
    }
}
