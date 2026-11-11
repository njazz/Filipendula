import XCTest
@testable import MergeCore

/// Files that exist nowhere in the project get a suggested home, worked out from how the source and project folders
/// line up. Adding one is always an explicit, per-file decision.
final class NewFileLocationTests: TempProjectTestCase {

    // MARK: - Suggester on a hand-made index

    private func index(_ paths: [String]) -> ProjectIndex {
        let root = URL(fileURLWithPath: "/p")
        return ProjectIndex(root: root, files: paths.map { ProjectFile(relPath: $0, url: root.appendingPathComponent($0)) })
    }

    private func suggest(_ files: [String], name: String = "n.swift", dirs: [String] = [], mirrored: String? = nil,
                         proven: Bool = true, siblings: [SiblingTarget] = [], limit: Int = 6) -> [LocationSuggestion] {
        LocationSuggester(index: index(files))
            .suggest(fileName: name, sourceDirs: dirs, mirrored: mirrored, mirroredIsProven: proven,
                     siblings: siblings, limit: limit)
    }

    func testIndexListsFoldersAndTheirParents() {
        let idx = index(["a/b/c.txt", "d.txt", "a/e.txt"])
        XCTAssertEqual(idx.directories, ["a", "a/b"])
        XCTAssertTrue(index([]).directories.isEmpty)
    }

    func testProjectRootIsAlwaysAnOption() {
        let list = suggest([])
        XCTAssertEqual(list, [LocationSuggestion(relPath: "n.swift", reason: .projectRoot, detail: nil)])
        XCTAssertEqual(LocationSuggester.preferred(list)?.relPath, "n.swift")
    }

    func testMirroredFolderThatExistsComesFirst() {
        let list = suggest(["lib/a.swift"], mirrored: "lib/n.swift")
        XCTAssertEqual(list.first, LocationSuggestion(relPath: "lib/n.swift", reason: .mirrorsFolder, detail: nil))
        XCTAssertEqual(list.last?.reason, .projectRoot)
    }

    func testMirroredAtTheRootCountsAndIsNotListedTwice() {
        let list = suggest(["lib/a.swift"], mirrored: "n.swift")
        XCTAssertEqual(list.filter { $0.relPath == "n.swift" }.count, 1)
        XCTAssertEqual(list.first?.reason, .mirrorsFolder)
    }

    func testMirroredFolderIsIgnoredAsFirstChoiceWhenNotProven() {
        // Nothing from the dropped folder matched by path, so its layout is no evidence.
        let list = suggest(["lib/a.swift"], mirrored: "lib/n.swift", proven: false)
        XCTAssertNotEqual(list.first?.reason, .mirrorsFolder)
        XCTAssertEqual(LocationSuggester.preferred(list)?.relPath, "n.swift")
    }

    func testMirroredFolderMatchIsCaseInsensitiveAndUsesTheRealSpelling() {
        let list = suggest(["Lib/a.swift"], mirrored: "lib/n.swift")
        XCTAssertEqual(list.first?.relPath, "Lib/n.swift")
    }

    func testSiblingFoldersAreRankedByPopularity() {
        let sib = [SiblingTarget(dir: "x", fileName: "a.swift"),
                   SiblingTarget(dir: "y", fileName: "b.swift"),
                   SiblingTarget(dir: "y", fileName: "c.swift")]
        let list = suggest([], siblings: sib)
        XCTAssertEqual(list.map(\.relPath), ["y/n.swift", "x/n.swift", "n.swift"])
        XCTAssertEqual(list.first?.reason, .siblings)
        XCTAssertEqual(list.first?.detail, "b.swift, c.swift")
        XCTAssertEqual(list.first?.directory, "y")
    }

    func testSiblingsInTheProjectRootSuggestTheRoot() {
        let list = suggest(["lib/a.swift"], siblings: [SiblingTarget(dir: "", fileName: "a.swift")])
        XCTAssertEqual(list.first, LocationSuggestion(relPath: "n.swift", reason: .siblings, detail: "a.swift"))
        XCTAssertEqual(list.filter { $0.relPath == "n.swift" }.count, 1)
    }

    func testFolderNameMatchPrefersTheLongestMatchingTail() {
        let list = suggest(["lib/a.swift", "app/lib/b.swift", "vendor/lib/c.swift", "other/d.swift"],
                           dirs: ["Users", "me", "app", "lib"])
        let named = list.filter { $0.reason == .folderName }.map(\.relPath)
        XCTAssertEqual(named, ["app/lib/n.swift", "lib/n.swift", "vendor/lib/n.swift"])
    }

    func testFolderNameMatchIsCaseInsensitive() {
        let list = suggest(["lib/a.swift"], dirs: ["LIB"])
        XCTAssertEqual(list.first, LocationSuggestion(relPath: "lib/n.swift", reason: .folderName, detail: nil))
    }

    func testFolderNameMatchIgnoresUnrelatedFolders() {
        let list = suggest(["lib/a.swift"], dirs: ["Users", "me", "Downloads"])
        XCTAssertFalse(list.contains { $0.reason == .folderName })
    }

    func testNewFolderOnlyWhenItHangsOffAFolderTheProjectHas() {
        let anchored = suggest(["lib/a.swift"], mirrored: "lib/sub/n.swift")
        XCTAssertTrue(anchored.contains(LocationSuggestion(relPath: "lib/sub/n.swift", reason: .newFolder, detail: nil)))
        XCTAssertNotEqual(anchored.first?.reason, .mirrorsFolder, "lib/sub does not exist yet")

        let foreign = suggest(["lib/a.swift"], mirrored: "foreign/deep/n.swift")
        XCTAssertFalse(foreign.contains { $0.reason == .newFolder })
    }

    func testNewFolderIsAlsoOfferedWhenTheMirrorIsNotProven() {
        let list = suggest(["lib/a.swift"], mirrored: "lib/sub/n.swift", proven: false)
        XCTAssertTrue(list.contains { $0.reason == .newFolder })
    }

    func testSameTypeFoldersAreHintsNeverTheDefault() {
        let list = suggest(["a/x.swift", "a/y.swift", "b/z.swift", "c/readme.md"])
        XCTAssertEqual(list.map(\.relPath), ["a/n.swift", "b/n.swift", "n.swift"])
        XCTAssertEqual(list.map(\.reason), [.sameType, .sameType, .projectRoot])
        XCTAssertEqual(list.first?.detail, ".swift")
        XCTAssertEqual(LocationSuggester.preferred(list)?.relPath, "n.swift")
    }

    func testFilesWithoutExtensionGetNoTypeHint() {
        let list = suggest(["a/Makefile", "b/Dockerfile"], name: "LICENSE")
        XCTAssertFalse(list.contains { $0.reason == .sameType })
    }

    func testProtectedFoldersAreNeverSuggested() {
        let list = suggest([], mirrored: ".git/hooks/n.swift",
                           siblings: [SiblingTarget(dir: ".merge_backup", fileName: "a.swift"),
                                      SiblingTarget(dir: "../escape", fileName: "b.swift")])
        XCTAssertEqual(list.map(\.relPath), ["n.swift"])
    }

    func testAnExistingFileIsNeverSuggestedAsAHome() {
        let list = suggest(["lib/n.swift"], mirrored: "lib/n.swift")
        XCTAssertFalse(list.contains { $0.relPath == "lib/n.swift" })
    }

    func testTheListIsCappedButKeepsTheRoot() {
        let sib = (0..<10).map { SiblingTarget(dir: "d\($0)", fileName: "f\($0).swift") }
        let list = suggest([], siblings: sib, limit: 4)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list.last?.relPath, "n.swift")
        XCTAssertEqual(list.first?.reason, .siblings)
    }

    func testEverySuggestionHasAReadableSummary() {
        let reasons: [LocationSuggestion.Reason] = [.mirrorsFolder, .siblings, .folderName, .newFolder, .sameType, .projectRoot]
        for r in reasons {
            XCTAssertFalse(LocationSuggestion(relPath: "n.swift", reason: r, detail: nil).summary.isEmpty)
        }
        XCTAssertTrue(LocationSuggestion(relPath: "x/n.swift", reason: .siblings, detail: "a.swift").summary.contains("a.swift"))
        XCTAssertTrue(LocationSuggestion(relPath: "x/n.swift", reason: .sameType, detail: ".swift").summary.contains(".swift"))
    }

    func testSuggestionsSurviveAJSONRoundTrip() throws {
        let s = LocationSuggestion(relPath: "lib/n.swift", reason: .folderName, detail: nil)
        let back = try JSONDecoder().decode(LocationSuggestion.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: - Planner on real folders

    func testNewFileInADroppedFolderLandsWhereTheFolderStructureSays() throws {
        try inProject("lib/a.txt", "a\n")
        try inInbox("drop/lib/a.txt", "a\nb\n")
        try inInbox("drop/lib/new.txt", "fresh\n")

        let result = plan(inbox.appendingPathComponent("drop"))
        let n = try change(result, named: "new.txt")
        XCTAssertEqual(n.status, .new)
        XCTAssertEqual(n.matchKind, .none)
        XCTAssertEqual(n.targetRelPath, "lib/new.txt")
        XCTAssertEqual(n.suggestions.first?.reason, .mirrorsFolder)
        XCTAssertEqual(n.suggestions.last?.reason, .projectRoot)
        XCTAssertTrue(n.suggestions.contains { $0.relPath == "new.txt" }, "the root stays available")
    }

    func testNewFileInADroppedFolderCanCreateASubfolderOfAnExistingOne() throws {
        try inProject("lib/a.txt", "a\n")
        try inInbox("drop/lib/a.txt", "a\nb\n")
        try inInbox("drop/lib/sub/new.txt", "fresh\n")

        let n = try change(plan(inbox.appendingPathComponent("drop")), named: "new.txt")
        XCTAssertEqual(n.targetRelPath, "lib/sub/new.txt")
        XCTAssertTrue(n.suggestions.contains { $0.reason == .newFolder })
    }

    func testNewFileFollowsItsNeighboursWhenFolderNamesDiffer() throws {
        try inProject("src/core/a.txt", "a\n")
        try inInbox("stuff/a.txt", "a\nb\n")
        try inInbox("stuff/b.txt", "brand new\n")

        let result = plan(inbox.appendingPathComponent("stuff"))
        let b = try change(result, named: "b.txt")
        XCTAssertEqual(try change(result, named: "a.txt").targetRelPath, "src/core/a.txt")
        XCTAssertEqual(b.targetRelPath, "src/core/b.txt")
        XCTAssertEqual(b.suggestions.first?.reason, .siblings)
        XCTAssertEqual(b.suggestions.first?.detail, "a.txt")
        XCTAssertEqual(b.suggestions.last?.relPath, "b.txt")
    }

    func testAFolderThatMatchedNothingDoesNotInventAStructure() throws {
        try inProject("src/a.txt", "unrelated\n")
        try inInbox("bundle/x/new.txt", "fresh\n")
        let n = try XCTUnwrap(plan(inbox.appendingPathComponent("bundle")).first)
        XCTAssertEqual(n.targetRelPath, "new.txt", "no evidence for anything better than the root")
    }

    func testNeighboursFromDifferentSourceFoldersVoteSeparately() throws {
        try inProject("one/a.txt", "a\n")
        try inProject("two/b.txt", "b\n")
        try inInbox("s1/a.txt", "a\nx\n")
        try inInbox("s1/n1.txt", "new\n")
        try inInbox("s2/b.txt", "b\nx\n")
        try inInbox("s2/n2.txt", "new\n")

        let result = plan(inbox.appendingPathComponent("s1"), inbox.appendingPathComponent("s2"))
        XCTAssertEqual(try change(result, named: "n1.txt").targetRelPath, "one/n1.txt")
        XCTAssertEqual(try change(result, named: "n2.txt").targetRelPath, "two/n2.txt")
    }

    func testGuessedNeighboursDoNotVote() throws {
        try inProject("x/a.txt", "a\n")
        try inProject("y/a.txt", "a\n")      // "a.txt" is ambiguous, so it says nothing certain
        try inInbox("s/a.txt", "a\nb\n")
        try inInbox("s/n.txt", "new\n")
        let n = try change(plan(inbox.appendingPathComponent("s")), named: "n.txt")
        XCTAssertEqual(n.targetRelPath, "n.txt")
        XCTAssertFalse(n.suggestions.contains { $0.reason == .siblings })
    }

    func testASingleDroppedFileUsesItsFolderName() throws {
        try inProject("lib/a.txt", "a\n")
        let source = try inInbox("lib/fresh.txt", "new\n")
        let n = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(n.targetRelPath, "lib/fresh.txt")
        XCTAssertEqual(n.suggestions.first?.reason, .folderName)
    }

    func testANewFileWithNoClueGoesToTheRoot() throws {
        let source = try inInbox("fresh.txt", "new\n")
        let n = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(n.targetRelPath, "fresh.txt")
        XCTAssertEqual(n.suggestions.map(\.relPath), ["fresh.txt"])
        XCTAssertNil(n.targetModified)
    }

    func testPlanKeepsTheOrderOfDroppedFilesWhenSomeAreNew() throws {
        try inProject("lib/a.txt", "a\n")
        let a = try inInbox("a.txt", "a\nb\n")
        let fresh = try inInbox("fresh.txt", "new\n")
        let c = try inInbox("c.txt", "c\n")
        let result = plan(a, fresh, c)
        XCTAssertEqual(result.map { $0.source.lastPathComponent }, ["a.txt", "fresh.txt", "c.txt"])
        XCTAssertEqual(result.map(\.status), [.additions, .new, .new])
    }

    func testRetargetingANewFileKeepsItsSuggestions() throws {
        try inProject("lib/a.txt", "a\n")
        let source = try inInbox("lib/fresh.txt", "new\n")
        let planner = Planner(project: project)
        let n = try XCTUnwrap(planner.plan(sources: [source]).first)
        let moved = planner.retarget(n, to: "docs/fresh.txt")
        XCTAssertEqual(moved.targetRelPath, "docs/fresh.txt")
        XCTAssertEqual(moved.status, .new)
        XCTAssertEqual(moved.suggestions, n.suggestions)
    }

    // MARK: - Adding is a per-file decision

    func testTickedNewFileIsCreatedAtTheSuggestedPlaceAndUndoRemovesIt() throws {
        try inProject("lib/a.txt", "a\n")
        let source = try inInbox("lib/fresh.txt", "new\n")
        var n = try XCTUnwrap(plan(source).first)
        n.addNew = true

        let ops = Operations(project: project)
        let entry = try ops.apply([n])      // allowNew stays false: only this change is allowed to create
        XCTAssertEqual(entry.ops.map(\.op), [.create])
        XCTAssertEqual(read("lib/fresh.txt"), "new\n")

        let report = try ops.undo(batch: entry.batch)
        XCTAssertEqual(report.results.first?.outcome, .deleted)
        XCTAssertFalse(exists("lib/fresh.txt"))
        XCTAssertTrue(exists("lib/a.txt"))
    }

    func testUndoRemovesFoldersTheBatchCreatedButNotOlderOnes() throws {
        try inProject("lib/a.txt", "a\n")
        let source = try inInbox("n.txt", "new\n")
        let planner = Planner(project: project)
        var n = planner.retarget(try XCTUnwrap(planner.plan(sources: [source]).first), to: "lib/deep/er/n.txt")
        n.addNew = true
        let ops = Operations(project: project)
        let entry = try ops.apply([n])
        XCTAssertTrue(exists("lib/deep/er/n.txt"))
        _ = try ops.undo(batch: entry.batch)
        XCTAssertFalse(exists("lib/deep"))
        XCTAssertTrue(exists("lib/a.txt"))
        XCTAssertTrue(exists("lib"))
    }

    func testOnlyTheTickedNewFilesAreCreated() throws {
        let one = try inInbox("one.txt", "1\n")
        let two = try inInbox("two.txt", "2\n")
        var changes = plan(one, two)
        changes[0].addNew = true

        let entry = try Operations(project: project).apply(changes)
        XCTAssertEqual(entry.ops.map(\.path), ["one.txt"])
        XCTAssertFalse(exists("two.txt"))
        XCTAssertTrue(entry.notes.contains { $0.hasPrefix("Not in project, not added:") && $0.hasSuffix("two.txt") })
    }

    func testNewFileAtAHandPickedPath() throws {
        let source = try inInbox("readme.txt", "hello\n")
        let planner = Planner(project: project)
        var c = planner.retarget(try XCTUnwrap(planner.plan(sources: [source]).first), to: "docs/readme.txt")
        c.addNew = true
        _ = try Operations(project: project).apply([c])
        XCTAssertEqual(read("docs/readme.txt"), "hello\n")
        XCTAssertFalse(exists("readme.txt"))
    }

    func testAddNewCannotResurrectAFileThatWasPlannedAsAnUpdate() throws {
        try inProject("a.txt", "a\n")
        let source = try inInbox("a.txt", "a\nb\n")
        var c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.status, .additions)
        c.addNew = true                                   // set by mistake or by an old caller
        try FileManager.default.removeItem(at: project.appendingPathComponent("a.txt"))

        XCTAssertThrowsError(try Operations(project: project).apply([c])) { error in
            guard case MergeError.newFilesNotAllowed = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(exists("a.txt"))
    }

    func testAddNewDoesNotOverwriteAFileThatAppearedAfterPlanning() throws {
        let source = try inInbox("n.txt", "mine\nmore\n")
        var c = try XCTUnwrap(plan(source).first)
        c.addNew = true
        try inProject("n.txt", "someone else's work\n")     // created meanwhile

        XCTAssertThrowsError(try Operations(project: project).apply([c])) { error in
            guard case MergeError.stale = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(read("n.txt"), "someone else's work\n")
    }

    func testAddNewRefusesUnsafeTargets() throws {
        let source = try inInbox("n.txt", "x\n")
        let planner = Planner(project: project)
        var c = planner.retarget(try XCTUnwrap(planner.plan(sources: [source]).first), to: "../evil.txt")
        c.addNew = true
        XCTAssertEqual(c.issue, "Invalid target path")
        XCTAssertThrowsError(try Operations(project: project).apply([c]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.txt").path))
    }

    func testBatchAllowNewStillWorksForTheCLI() throws {
        let source = try inInbox("n.txt", "x\n")
        let c = try XCTUnwrap(plan(source).first)
        XCTAssertFalse(c.addNew)
        _ = try Operations(project: project).apply([c], allowNew: true)
        XCTAssertEqual(read("n.txt"), "x\n")
    }

    func testTwoNewFilesCannotShareOneTarget() throws {
        let a = try inInbox("a/n.txt", "1\n")
        let b = try inInbox("b/n.txt", "2\n")
        var changes = plan(a, b)
        XCTAssertEqual(changes.map(\.conflict), [false, true])
        for i in changes.indices { changes[i].addNew = true }
        XCTAssertThrowsError(try Operations(project: project).apply(changes)) { error in
            guard case MergeError.duplicateTarget = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(exists("n.txt"))
    }
}
