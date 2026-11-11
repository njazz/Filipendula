import XCTest
@testable import MergeCore

/// Same name as a project file, but the source tree keeps it in another folder:
/// project Foo/Bar.hpp, source Foo/Baz/Bar.hpp → replace Foo/Bar.hpp, or add Foo/Baz/Bar.hpp.
final class InPlaceTests: TempProjectTestCase {

    private func suggester(_ paths: [String]) -> LocationSuggester {
        let root = URL(fileURLWithPath: "/p")
        return LocationSuggester(index: ProjectIndex(root: root, files: paths.map {
            ProjectFile(relPath: $0, url: root.appendingPathComponent($0))
        }))
    }

    func testOffersReplaceAndAddWhenTheMirroredFolderExists() {
        let s = suggester(["Foo/Bar.hpp", "Foo/Baz/Other.hpp"])
        let o = s.inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: [],
                                 mirrored: "Foo/Baz/Bar.hpp", mirroredIsProven: true)
        XCTAssertEqual(o.map(\.relPath), ["Foo/Bar.hpp", "Foo/Baz/Bar.hpp"])
        XCTAssertEqual(o.map(\.reason), [.replacesExisting, .addsInPlace])
        XCTAssertEqual(o[1].detail, "existing")
    }

    func testNewFolderIsMarkedAsSuch() {
        let s = suggester(["Foo/Bar.hpp"])
        let o = s.inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: [],
                                 mirrored: "Foo/Baz/Bar.hpp", mirroredIsProven: false)
        XCTAssertEqual(o.last?.relPath, "Foo/Baz/Bar.hpp")
        XCTAssertEqual(o.last?.detail, "new")
    }

    func testNoSecondPlaceWhenThereIsNone() {
        let s = suggester(["Foo/Bar.hpp", "Foo/Baz/Bar.hpp"])
        // mirrored path is the matched file itself
        XCTAssertTrue(s.inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: [],
                                       mirrored: "Foo/Bar.hpp", mirroredIsProven: true).isEmpty)
        // mirrored path already exists (it would have matched by path)
        XCTAssertTrue(s.inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: [],
                                       mirrored: "Foo/Baz/Bar.hpp", mirroredIsProven: true).isEmpty)
        // unrelated, unproven layout that hangs off nothing the project has
        XCTAssertTrue(suggester(["Foo/Bar.hpp"]).inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: [],
                                                                mirrored: "Other/Deep/Bar.hpp", mirroredIsProven: false).isEmpty)
        // no layout information at all
        XCTAssertTrue(s.inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: ["tmp"],
                                       mirrored: nil, mirroredIsProven: false).isEmpty)
        // protected folders are never offered
        XCTAssertTrue(suggester(["Foo/Bar.hpp"]).inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: [],
                                                                mirrored: ".git/Bar.hpp", mirroredIsProven: true).isEmpty)
    }

    func testSingleFileUsesAProjectFolderNamedLikeItsOwnFolders() {
        let s = suggester(["Foo/Bar.hpp", "Foo/Baz/Other.hpp"])
        let o = s.inPlaceOptions(fileName: "Bar.hpp", matched: "Foo/Bar.hpp", sourceDirs: ["tmp", "source", "Foo", "Baz"],
                                 mirrored: nil, mirroredIsProven: false)
        XCTAssertEqual(o.last?.relPath, "Foo/Baz/Bar.hpp")
    }

    // MARK: Through the planner

    func testDroppedFolderOffersBothPlacesAndStillReplacesByDefault() throws {
        try inProject("Foo/Bar.hpp", numbered("l", 6))
        try inProject("Foo/Baz/Other.hpp", "other\n")
        try inInbox("source/Foo/Baz/Bar.hpp", numbered("l", 6) + "more\n")
        try inInbox("source/Foo/Baz/Other.hpp", "other\nmore\n")

        let result = plan(inbox.appendingPathComponent("source"))
        let bar = try change(result, named: "Bar.hpp")
        XCTAssertEqual(bar.targetRelPath, "Foo/Bar.hpp")
        XCTAssertEqual(bar.matchKind, .uniqueName)
        XCTAssertEqual(bar.placements.map(\.relPath), ["Foo/Bar.hpp", "Foo/Baz/Bar.hpp"])
        XCTAssertTrue(try change(result, named: "Other.hpp").placements.isEmpty)
    }

    func testSingleDroppedFileFromAMatchingFolderOffersToAddInPlace() throws {
        try inProject("Foo/Bar.hpp", numbered("l", 6))
        try inProject("Foo/Baz/Other.hpp", "other\n")
        let source = try inInbox("Foo/Baz/Bar.hpp", numbered("l", 6) + "more\n")
        let c = try XCTUnwrap(plan(source).first)
        XCTAssertEqual(c.targetRelPath, "Foo/Bar.hpp")
        XCTAssertEqual(c.placements.last?.relPath, "Foo/Baz/Bar.hpp")
    }

    func testChoosingAddCreatesTheFileAndLeavesTheOriginalAlone() throws {
        try inProject("Foo/Bar.hpp", numbered("l", 6))
        try inProject("Foo/Baz/Other.hpp", "other\n")
        let source = try inInbox("Foo/Baz/Bar.hpp", numbered("l", 6) + "more\n")
        let planner = Planner(project: project)
        let c = try XCTUnwrap(planner.plan(sources: [source]).first)
        let add = try XCTUnwrap(c.placements.first { $0.reason == .addsInPlace })

        var moved = planner.retarget(c, to: add.relPath)
        XCTAssertEqual(moved.status, .new)
        XCTAssertEqual(moved.placements, c.placements, "the choice stays available")
        moved.addNew = true
        let ops = Operations(project: project)
        let entry = try ops.apply([moved])
        XCTAssertEqual(read("Foo/Baz/Bar.hpp"), numbered("l", 6) + "more\n")
        XCTAssertEqual(read("Foo/Bar.hpp"), numbered("l", 6))

        _ = try ops.undo(batch: entry.batch)
        XCTAssertFalse(exists("Foo/Baz/Bar.hpp"))
        XCTAssertEqual(read("Foo/Bar.hpp"), numbered("l", 6))
    }

    func testPlacementsAreEmptyForNewAndIdenticalLayouts() throws {
        try inProject("Foo/Bar.hpp", "a\n")
        try inInbox("source/Foo/Bar.hpp", "a\nb\n")
        try inInbox("source/Foo/New.hpp", "n\n")
        let result = plan(inbox.appendingPathComponent("source"))
        XCTAssertTrue(try change(result, named: "Bar.hpp").placements.isEmpty)
        XCTAssertTrue(try change(result, named: "New.hpp").placements.isEmpty)
    }
}
