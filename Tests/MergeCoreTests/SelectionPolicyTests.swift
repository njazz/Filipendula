import XCTest
@testable import MergeCore

/// Which changes may be ticked, which start ticked, and what "commit" is allowed to create.
final class SelectionPolicyTests: XCTestCase {
    private func make(_ status: MergeStatus, kind: MatchKind = .uniqueName, conflict: Bool = false,
                      issue: String? = nil, similarity: Double? = 0.9, oldLines: Int = 10,
                      name: String = "f.txt") -> PlannedChange {
        var c = PlannedChange(source: URL(fileURLWithPath: "/src/\(name)"), targetRelPath: name, matchKind: kind, candidates: [],
                              classification: Classification(status: status, added: 1, removed: status == .additions ? 0 : 1,
                                                             oldLineCount: oldLines),
                              conflict: conflict, issue: issue)
        c.similarity = similarity
        return c
    }

    func testDefaultColorsMatchTheDocumentedBehaviour() {
        let p = SelectionPolicy()
        XCTAssertTrue(p.defaultChecked(make(.additions)))
        XCTAssertTrue(p.defaultChecked(make(.modified)))
        XCTAssertTrue(p.defaultChecked(make(.binary)))
        XCTAssertFalse(p.defaultChecked(make(.deletionsOnly)))
        XCTAssertFalse(p.defaultChecked(make(.heavyLoss)))
        XCTAssertFalse(p.defaultChecked(make(.identical)))
    }

    func testNewFilesStartUncheckedButCanBeTicked() {
        let new = make(.new, kind: .none, similarity: nil)
        let off = SelectionPolicy(checkNewFilesByDefault: false)
        XCTAssertTrue(off.isCommittable(new), "ticking is always possible: that is the per-file opt-in")
        XCTAssertFalse(off.defaultChecked(new))
        XCTAssertFalse(off.includedInSelectAll(new), "'select all' must not sneak new files in")

        let on = SelectionPolicy(checkNewFilesByDefault: true)
        XCTAssertTrue(on.defaultChecked(new))
        XCTAssertTrue(on.includedInSelectAll(new))
    }

    func testIdenticalAndBrokenChangesCanNeverBeCommitted() {
        let p = SelectionPolicy(checkNewFilesByDefault: true)
        XCTAssertFalse(p.isCommittable(make(.identical)))
        XCTAssertFalse(p.isCommittable(make(.additions, issue: "Cannot read source file")))
        XCTAssertFalse(p.includedInSelectAll(make(.identical)))
        XCTAssertFalse(p.defaultChecked(make(.additions, issue: "broken")))
    }

    func testConflictsAreNeverCheckedAutomatically() {
        let p = SelectionPolicy(checkNewFilesByDefault: true)
        XCTAssertFalse(p.defaultChecked(make(.additions, conflict: true)))
        XCTAssertFalse(p.includedInSelectAll(make(.additions, conflict: true)))
        XCTAssertTrue(p.isCommittable(make(.additions, conflict: true)), "the user may still tick one of them")
    }

    func testAmbiguousAndWeakMatchesNeedAConfirmationFirst() {
        let p = SelectionPolicy()
        XCTAssertFalse(p.defaultChecked(make(.additions, kind: .ambiguous)))
        XCTAssertFalse(p.defaultChecked(make(.modified, similarity: 0.05)), "barely any lines in common")
        XCTAssertTrue(p.defaultChecked(make(.modified, similarity: 0.5)))
        // The user picked the target by hand, so the warning no longer applies.
        XCTAssertTrue(p.defaultChecked(make(.additions, kind: .manual, similarity: 0.0)))
        // Small files are exempt from the similarity judgement.
        XCTAssertTrue(p.defaultChecked(make(.modified, similarity: 0.0, oldLines: 2)))
    }

    func testPrepareForCommitMarksOnlyNewFilesAsWanted() {
        let p = SelectionPolicy()
        let ticked = [make(.additions, name: "a.txt"), make(.new, kind: .none, similarity: nil, name: "n.txt"),
                      make(.modified, name: "m.txt")]
        let prepared = p.prepareForCommit(ticked)
        XCTAssertEqual(prepared.map(\.addNew), [false, true, false])
        XCTAssertEqual(prepared.map(\.targetRelPath), ["a.txt", "n.txt", "m.txt"])
    }

    func testPrepareForCommitDropsWhatCannotBeCommitted() {
        let p = SelectionPolicy()
        let prepared = p.prepareForCommit([make(.identical, name: "same.txt"),
                                           make(.additions, issue: "x", name: "bad.txt"),
                                           make(.additions, name: "ok.txt")])
        XCTAssertEqual(prepared.map(\.targetRelPath), ["ok.txt"])
    }

    func testPrepareForCommitDoesNotTouchTheOriginals() {
        let original = make(.new, kind: .none, similarity: nil)
        _ = SelectionPolicy().prepareForCommit([original])
        XCTAssertFalse(original.addNew)
    }

    func testLowSimilarityRules() {
        XCTAssertTrue(make(.heavyLoss, similarity: 0.1).isLowSimilarity)
        XCTAssertFalse(make(.heavyLoss, similarity: Similarity.lowMatch).isLowSimilarity, "the threshold itself is fine")
        XCTAssertFalse(make(.identical, similarity: 0).isLowSimilarity)
        XCTAssertFalse(make(.new, kind: .none, similarity: 0).isLowSimilarity)
        XCTAssertFalse(make(.heavyLoss, similarity: nil).isLowSimilarity)
        XCTAssertFalse(make(.heavyLoss, kind: .manual, similarity: 0).isLowSimilarity)
        XCTAssertTrue(make(.heavyLoss, kind: .ambiguous, similarity: 0).needsConfirmation)
    }
}
