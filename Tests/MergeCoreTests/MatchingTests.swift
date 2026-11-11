import XCTest
@testable import MergeCore

/// Same-named files are compared by content *and* by folder, so the update lands on the copy that really is its
/// predecessor, not just on the first file with the same name.
final class MatchingTests: TempProjectTestCase {

    // MARK: Scoring building blocks

    func testFolderScoreCountsMatchingFoldersFromTheInside() {
        let src = ["Users", "me", "Downloads", "src", "lib"]
        XCTAssertEqual(Similarity.folderScore(sourceDirs: src, candidatePath: "src/lib/a.txt"), 1, accuracy: 1e-9)
        XCTAssertEqual(Similarity.folderScore(sourceDirs: src, candidatePath: "app/src/lib/a.txt"), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(Similarity.folderScore(sourceDirs: src, candidatePath: "other/lib/a.txt"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Similarity.folderScore(sourceDirs: src, candidatePath: "src/other/a.txt"), 0, accuracy: 1e-9)
    }

    func testFolderScoreEdgeCases() {
        // A project-root file has no folder to match.
        XCTAssertEqual(Similarity.folderScore(sourceDirs: ["lib"], candidatePath: "a.txt"), 0)
        // No source folders at all.
        XCTAssertEqual(Similarity.folderScore(sourceDirs: [], candidatePath: "lib/a.txt"), 0)
        // Case-insensitive, like the default macOS file system.
        XCTAssertEqual(Similarity.folderScore(sourceDirs: ["LIB"], candidatePath: "lib/a.txt"), 1)
        // Source shorter than the candidate's folder chain.
        XCTAssertEqual(Similarity.folderScore(sourceDirs: ["lib"], candidatePath: "a/b/lib/x.txt"), 1.0 / 3.0, accuracy: 1e-9)
        // Only the tail counts: a matching outer folder behind a mismatch scores nothing.
        XCTAssertEqual(Similarity.folderScore(sourceDirs: ["a", "x"], candidatePath: "a/b/f.txt"), 0)
    }

    func testContentSimilarity() {
        func d(_ s: String) -> Data { Data(s.utf8) }
        XCTAssertEqual(Similarity.score(d("a\nb\n"), d("a\nb\n")), 1)
        XCTAssertEqual(Similarity.score(d("a\nb\n"), d("c\nd\n")), 0)
        XCTAssertEqual(Similarity.score(d(""), d("")), 1)
        XCTAssertEqual(Similarity.score(d("1\n2\n3\n4\n"), d("1\n2\n5\n6\n")), 1.0 / 3.0, accuracy: 1e-9)
        // Line endings and trailing whitespace do not matter.
        XCTAssertEqual(Similarity.score(d("a\nb\n"), d("a  \r\nb\r\n")), 1)
        // Order does not matter, only which lines exist.
        XCTAssertEqual(Similarity.score(d("a\nb\n"), d("b\na\n")), 1)
    }

    func testBinaryFilesAreEitherIdenticalOrUnrelated() {
        let a = Data([0, 1, 2]), b = Data([0, 1, 3])
        XCTAssertEqual(Similarity.score(a, a), 1)
        XCTAssertEqual(Similarity.score(a, b), 0)
        XCTAssertEqual(Similarity.score(a, Data("text\n".utf8)), 0)
    }

    func testCombinedScoreWeighsContentOverFolder() {
        XCTAssertEqual(Similarity.combined(content: 1, folder: 0), 0.75, accuracy: 1e-9)
        XCTAssertEqual(Similarity.combined(content: 0, folder: 1), 0.25, accuracy: 1e-9)
        XCTAssertGreaterThan(Similarity.combined(content: 0.5, folder: 0), Similarity.combined(content: 0.1, folder: 1))
    }

    // MARK: Several files share the name

    func testIdenticalCopiesAreToldApartByTheirFolder() throws {
        let body = numbered("shared", 6)
        try inProject("x/util.txt", body)
        try inProject("y/util.txt", body)
        let source = try inInbox("y/util.txt", body + "extra\n")

        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.matchKind, .ambiguous)
        XCTAssertEqual(c.targetRelPath, "y/util.txt")
        XCTAssertEqual(c.candidates, ["y/util.txt", "x/util.txt"])
        XCTAssertEqual(c.candidateScores.first?.folderMatch, 1)
        XCTAssertEqual(c.candidateScores.last?.folderMatch, 0)
        XCTAssertTrue(c.needsConfirmation)
    }

    func testClearlyBetterContentBeatsAMatchingFolder() throws {
        let base = numbered("line", 10)
        try inProject("lib/util.txt", numbered("unrelated", 10))        // right folder, wrong file
        try inProject("other/util.txt", base)                          // wrong folder, the real predecessor
        let source = try inInbox("lib/util.txt", base + "new 1\nnew 2\n")

        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.targetRelPath, "other/util.txt")
        XCTAssertEqual(try XCTUnwrap(c.similarity), 10.0 / 12.0, accuracy: 1e-9)
    }

    func testCandidateScoresListEveryCopyBestFirst() throws {
        let base = numbered("line", 10)
        try inProject("a/f.txt", numbered("zzz", 10))
        try inProject("b/f.txt", base)
        try inProject("c/f.txt", numbered("line", 5) + numbered("other", 5))
        let source = try inInbox("f.txt", base)

        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.candidates, ["b/f.txt", "c/f.txt", "a/f.txt"])
        XCTAssertEqual(c.candidateScores.map(\.path), c.candidates)
        XCTAssertEqual(c.candidateScores[0].similarity, 1, accuracy: 1e-9)
        XCTAssertEqual(c.candidateScores[2].similarity, 0, accuracy: 1e-9)
        XCTAssertEqual(c.status, .identical)
    }

    func testAmbiguousNoteDistinguishesCloseFromClearCalls() throws {
        let body = numbered("same", 8)
        try inProject("p/f.txt", body)
        try inProject("q/f.txt", body)
        let close = try inInbox("f.txt", body + "x\n")
        XCTAssertTrue(try XCTUnwrap(plan(close).first?.note).contains("about equally"))

        try FileManager.default.removeItem(at: project.appendingPathComponent("q/f.txt"))
        try inProject("q/f.txt", numbered("other", 8))
        let clear = try XCTUnwrap(plan(close).first)
        XCTAssertTrue(try XCTUnwrap(clear.note).contains("Best fit"))
        XCTAssertEqual(clear.targetRelPath, "p/f.txt")
    }

    // MARK: The dropped folder's structure points at the wrong file

    func testStructureMatchIsReplacedByAClearlyBetterSameNamedFile() throws {
        let base = numbered("line", 10)
        try inProject("lib/a.txt", numbered("unrelated", 10))
        try inProject("core/a.txt", base)
        try inInbox("drop/lib/a.txt", base + "added\n")

        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("drop")).first)
        XCTAssertEqual(c.targetRelPath, "core/a.txt")
        XCTAssertEqual(c.matchKind, .ambiguous, "a suggestion, so it has to be confirmed")
        XCTAssertTrue(c.needsConfirmation)
        XCTAssertEqual(c.candidates.first, "core/a.txt")
        XCTAssertEqual(Set(c.candidates), ["core/a.txt", "lib/a.txt"])
        let note = try XCTUnwrap(c.note)
        XCTAssertTrue(note.contains("lib/a.txt") && note.contains("core/a.txt"), note)
        XCTAssertEqual(c.status, .additions)
    }

    func testStructureMatchStaysWhenItsContentFits() throws {
        let base = numbered("line", 10)
        try inProject("lib/a.txt", base)
        try inProject("core/a.txt", numbered("unrelated", 10))
        try inInbox("drop/lib/a.txt", base + "added\n")

        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("drop")).first)
        XCTAssertEqual(c.targetRelPath, "lib/a.txt")
        XCTAssertEqual(c.matchKind, .path)
        XCTAssertNil(c.note)
        XCTAssertFalse(c.needsConfirmation)
        // The other copy is still offered in the picker, with the chosen target first.
        XCTAssertEqual(c.candidates, ["lib/a.txt", "core/a.txt"])
    }

    func testStructureMatchStaysWhenNoOtherCopyFitsBetter() throws {
        try inProject("lib/a.txt", numbered("unrelated", 10))
        try inProject("core/a.txt", numbered("different", 10))
        try inInbox("drop/lib/a.txt", numbered("fresh", 10))

        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("drop")).first)
        XCTAssertEqual(c.targetRelPath, "lib/a.txt")
        XCTAssertEqual(c.matchKind, .path)
        XCTAssertTrue(c.isLowSimilarity, "nothing fits, so the weak match is flagged instead")
        XCTAssertTrue(c.needsConfirmation)
    }

    func testStructureMatchStaysWhenTheAlternativeIsOnlySlightlyBetter() throws {
        let src = numbered("s", 10)
        // 7 shared lines (7/13 ≈ 0.54) at the structural target, 8 (8/12 ≈ 0.67) at the other copy: gap < 0.25.
        try inProject("lib/a.txt", numbered("s", 7) + numbered("p", 3))
        try inProject("core/a.txt", numbered("s", 8) + numbered("o", 2))
        try inInbox("drop/lib/a.txt", src)

        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("drop")).first)
        XCTAssertEqual(c.targetRelPath, "lib/a.txt")
        XCTAssertEqual(c.matchKind, .path)
    }

    func testStructureMatchWithoutAnyOtherCopyHasNoCandidates() throws {
        try inProject("lib/a.txt", "a\n")
        try inInbox("drop/lib/a.txt", "a\nb\n")
        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("drop")).first)
        XCTAssertEqual(c.matchKind, .path)
        XCTAssertTrue(c.candidates.isEmpty)
        XCTAssertTrue(c.candidateScores.isEmpty)
    }

    func testDroppedFolderNamedLikeAProjectFolderUsesPrefixMode() throws {
        try inProject("lib/a.txt", "a\n")
        try inInbox("lib/a.txt", "a\nb\n")          // dropping the folder "lib" itself
        let c = try XCTUnwrap(plan(inbox.appendingPathComponent("lib")).first)
        XCTAssertEqual(c.matchKind, .path)
        XCTAssertEqual(c.targetRelPath, "lib/a.txt")
    }

    // MARK: One same-named file: is it really the same file?

    func testUniqueNameWithFewSharedLinesIsFlagged() throws {
        try inProject("src/config.txt", numbered("old", 10))
        let source = try inInbox("config.txt", numbered("new", 10))

        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.matchKind, .uniqueName)
        XCTAssertEqual(c.targetRelPath, "src/config.txt")
        XCTAssertEqual(try XCTUnwrap(c.similarity), 0, accuracy: 1e-9)
        XCTAssertTrue(c.isLowSimilarity)
        XCTAssertTrue(c.needsConfirmation)
        XCTAssertFalse(c.isAmbiguous)
    }

    func testUniqueNameThatFitsIsNotFlagged() throws {
        try inProject("src/config.txt", numbered("line", 10))
        let source = try inInbox("config.txt", numbered("line", 10) + "more\n")
        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(try XCTUnwrap(c.similarity), 10.0 / 11.0, accuracy: 1e-9)
        XCTAssertFalse(c.isLowSimilarity)
        XCTAssertFalse(c.needsConfirmation)
    }

    func testSmallFilesAreNeverFlaggedAsLowSimilarity() throws {
        try inProject("version.txt", "version=1\n")
        let source = try inInbox("version.txt", "version=2\n")
        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(try XCTUnwrap(c.similarity), 0, accuracy: 1e-9)
        XCTAssertFalse(c.isLowSimilarity, "too few lines for a score to mean anything")
    }

    func testSimilarityThresholdBoundary() throws {
        // 3 shared of 10+10 lines: 3/17 ≈ 0.18 → flagged. 6 shared: 6/14 ≈ 0.43 → fine.
        try inProject("f.txt", numbered("s", 10))
        let weak = try inInbox("w/f.txt", numbered("s", 3) + numbered("n", 7))
        XCTAssertTrue(try XCTUnwrap(plan(weak).first).isLowSimilarity)
        let fine = try inInbox("g/f.txt", numbered("s", 6) + numbered("n", 4))
        XCTAssertFalse(try XCTUnwrap(plan(fine).first).isLowSimilarity)
    }

    func testIdenticalAndNewFilesAreNeverLowSimilarity() throws {
        try inProject("same.txt", numbered("line", 10))
        let same = try inInbox("same.txt", numbered("line", 10))
        let fresh = try inInbox("fresh.txt", numbered("line", 10))
        let result = plan(same, fresh)
        XCTAssertFalse(try change(result, named: "same.txt").isLowSimilarity)
        XCTAssertFalse(try change(result, named: "fresh.txt").isLowSimilarity)
        XCTAssertNil(try change(result, named: "fresh.txt").similarity)
    }

    // MARK: Picking a target by hand

    func testRetargetRecomputesSimilarityAndForgetsTheWarning() throws {
        try inProject("a/f.txt", numbered("x", 10))
        try inProject("b/f.txt", numbered("y", 10))
        let source = try inInbox("f.txt", numbered("y", 10) + "z\n")
        let planner = Planner(project: project)
        let original = try XCTUnwrap(planner.plan(sources: [source]).first)
        XCTAssertEqual(original.targetRelPath, "b/f.txt")

        let toWrong = planner.retarget(original, to: "a/f.txt")
        XCTAssertEqual(toWrong.matchKind, .manual)
        XCTAssertEqual(try XCTUnwrap(toWrong.similarity), 0, accuracy: 1e-9)
        XCTAssertNil(toWrong.note)
        XCTAssertFalse(toWrong.isLowSimilarity, "the user chose this target on purpose")
        XCTAssertFalse(toWrong.needsConfirmation)
        XCTAssertEqual(toWrong.candidates, original.candidates, "the picker keeps its list")

        let back = planner.retarget(toWrong, to: "b/f.txt")
        XCTAssertEqual(back.status, .additions)
        XCTAssertEqual(try XCTUnwrap(back.similarity), 10.0 / 11.0, accuracy: 1e-9)
    }

    func testRetargetToANewPathMakesItANewFile() throws {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        let planner = Planner(project: project)
        let c = try XCTUnwrap(planner.plan(sources: [source]).first)
        let moved = planner.retarget(c, to: "docs/a.txt")
        XCTAssertEqual(moved.status, .new)
        XCTAssertNil(moved.similarity)
        XCTAssertNil(moved.issue)
        XCTAssertNil(moved.targetModified)
    }

    func testRetargetRejectsUnsafePaths() throws {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        let planner = Planner(project: project)
        let c = try XCTUnwrap(planner.plan(sources: [source]).first)
        for bad in ["../x.txt", "/etc/passwd", ".git/config", ".merge_backup/x", ""] {
            let r = planner.retarget(c, to: bad)
            XCTAssertEqual(r.issue, "Invalid target path", bad)
            XCTAssertEqual(r.targetRelPath, c.targetRelPath, "the target must not change for \(bad)")
        }
    }

    // MARK: Conflicts

    func testTwoSourcesForTheSameTargetAreFlaggedOnce() throws {
        try inProject("a.txt", "a\n")
        let one = try inInbox("one/a.txt", "a\nb\n")
        let two = try inInbox("two/a.txt", "a\nc\n")
        let result = plan(one, two)
        XCTAssertEqual(result.map(\.conflict), [false, true])
    }

    func testConflictDetectionIgnoresCaseAndIdenticalFiles() throws {
        func make(_ source: String, _ target: String, _ status: MergeStatus) -> PlannedChange {
            PlannedChange(source: URL(fileURLWithPath: source), targetRelPath: target, matchKind: .path, candidates: [],
                          classification: Classification(status: status, added: 1, removed: 0, oldLineCount: 1),
                          conflict: false, issue: nil)
        }
        let a = make("/s/1", "Dir/A.txt", .additions)
        let b = make("/s/2", "dir/a.txt", .additions)
        let same = make("/s/3", "dir/a.txt", .identical)

        XCTAssertEqual(Planner.resolveConflicts([a, b]).map(\.conflict), [false, true])
        XCTAssertEqual(Planner.resolveConflicts([a, same]).map(\.conflict), [false, false], "identical files never collide")

        // Re-running clears stale flags.
        var stale = a
        stale.conflict = true
        XCTAssertEqual(Planner.resolveConflicts([stale]).map(\.conflict), [false])
    }
}
