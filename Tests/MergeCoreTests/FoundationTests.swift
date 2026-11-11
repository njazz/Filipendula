import XCTest
@testable import MergeCore

final class ScannerTests: TempProjectTestCase {

    func testIgnoredFoldersAndFilesAreSkipped() throws {
        try inProject("src/a.swift", "a")
        try inProject(".git/config", "x")
        try inProject("node_modules/pkg/index.js", "x")
        try inProject(".merge_backup/b1/a.swift", "x")
        try inProject(".build/debug/x", "x")
        try inProject("DerivedData/y", "x")
        try inProject("src/__pycache__/m.pyc", "x")
        try inProject("src/.DS_Store", "x")
        let rels = ProjectScanner.regularFiles(in: project).map(\.rel)
        XCTAssertEqual(rels, ["src/a.swift"])
    }

    func testDotfilesThatAreNotIgnoredAreKept() throws {
        try inProject(".gitignore", "x")
        try inProject(".env", "x")
        try inProject("a/.hidden/file", "x")
        XCTAssertEqual(ProjectScanner.regularFiles(in: project).map(\.rel), [".env", ".gitignore", "a/.hidden/file"])
    }

    func testResultsAreSortedWithForwardSlashesAndNoLeadingSlash() throws {
        try inProject("b/z.txt", "x")
        try inProject("a/y.txt", "x")
        try inProject("a.txt", "x")
        let rels = ProjectScanner.regularFiles(in: project).map(\.rel)
        XCTAssertEqual(rels, rels.sorted())
        XCTAssertTrue(rels.allSatisfy { !$0.hasPrefix("/") })
        XCTAssertEqual(Set(rels), ["a.txt", "a/y.txt", "b/z.txt"])
    }

    func testSymlinksAreNeverFollowedOrListed() throws {
        try inProject("real.txt", "x")
        let outside = root.appendingPathComponent("outside")
        try write("secret", outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.txt"),
                                                   withDestinationURL: project.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linkdir"),
                                                   withDestinationURL: outside)
        XCTAssertEqual(ProjectScanner.regularFiles(in: project).map(\.rel), ["real.txt"])
    }

    func testCustomIgnoreListReplacesTheDefault() throws {
        try inProject("skip/a.txt", "x")
        try inProject("node_modules/b.txt", "x")
        let rels = ProjectScanner.regularFiles(in: project, ignored: ["skip"]).map(\.rel)
        XCTAssertEqual(rels, ["node_modules/b.txt"])
    }

    func testMissingRootGivesNoFiles() {
        XCTAssertTrue(ProjectScanner.regularFiles(in: root.appendingPathComponent("nope")).isEmpty)
        XCTAssertTrue(ProjectScanner.scan(root.appendingPathComponent("nope")).files.isEmpty)
    }

    func testIndexLookups() throws {
        try inProject("a/util.txt", "1")
        try inProject("b/util.txt", "2")
        try inProject("c.txt", "3")
        let idx = ProjectScanner.scan(project)
        XCTAssertEqual(idx.files.count, 3)
        XCTAssertEqual(idx.byPath["a/util.txt"]?.name, "util.txt")
        XCTAssertEqual(idx.byName["util.txt"]?.count, 2)
        XCTAssertEqual(idx.byName["c.txt"]?.map(\.relPath), ["c.txt"])
        XCTAssertNil(idx.byPath["missing.txt"])
        XCTAssertEqual(idx.directories, ["a", "b"])
    }

    func testMatcherOrderOfPreference() throws {
        try inProject("a/util.txt", "1")
        try inProject("b/util.txt", "2")
        try inProject("only.txt", "3")
        let m = Matcher(index: ProjectScanner.scan(project))
        XCTAssertEqual(m.match(relPath: "b/util.txt", fileName: "util.txt").kind, .path)
        XCTAssertEqual(m.match(relPath: "zzz/util.txt", fileName: "util.txt").kind, .ambiguous)
        XCTAssertEqual(m.match(relPath: nil, fileName: "only.txt").kind, .uniqueName)
        XCTAssertEqual(m.match(relPath: "x/only.txt", fileName: "only.txt").kind, .uniqueName)
        XCTAssertEqual(m.match(relPath: nil, fileName: "ghost.txt").kind, .none)
    }
}

final class HashingTests: TempProjectTestCase {
    func testKnownVectors() {
        XCTAssertEqual(Hashing.sha256(data: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.sha256(data: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testFileHashEqualsDataHashAcrossChunkBoundaries() throws {
        for size in [0, 1, (1 << 20) - 1, 1 << 20, (1 << 20) + 1, 2_500_000] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let url = root.appendingPathComponent("blob-\(size)")
            try data.write(to: url)
            XCTAssertEqual(try Hashing.sha256(file: url), Hashing.sha256(data: data), "size \(size)")
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try Hashing.sha256(file: root.appendingPathComponent("missing")))
    }
}

final class PathRulesTests: XCTestCase {
    func testAcceptsAndNormalizes() throws {
        XCTAssertEqual(try PathRules.validate("a/b.txt"), "a/b.txt")
        XCTAssertEqual(try PathRules.validate("a//b///c.txt"), "a/b/c.txt")
        XCTAssertEqual(try PathRules.validate("  a/b.txt \n"), "a/b.txt")
        XCTAssertEqual(try PathRules.validate("a/b/"), "a/b")
        XCTAssertEqual(try PathRules.validate("Ünïcode/файл.txt"), "Ünïcode/файл.txt")
        XCTAssertEqual(try PathRules.validate("dir/.hidden"), "dir/.hidden")
        XCTAssertEqual(try PathRules.validate("a/.gitignore"), "a/.gitignore")
    }

    func testRejectsUnsafePaths() {
        let bad = ["", "   ", "/", "/abs/path", "~/x", "..", "../x", "a/../b", "a/..", ".", "./a", "a/./b",
                   ".git", ".git/config", "a/.git/hooks", ".merge_backup", ".merge_backup/b/x", "x/.merge_backup"]
        for p in bad {
            XCTAssertThrowsError(try PathRules.validate(p), "'\(p)' should be refused") { error in
                guard case MergeError.invalidPath = error else { return XCTFail("wrong error for \(p): \(error)") }
            }
        }
    }
}

final class MergeErrorTests: XCTestCase {
    func testEveryErrorHasAMessage() {
        let errors: [MergeError] = [
            .invalidPath("x"), .duplicateTarget("x"), .stale(path: "x", planned: .additions, now: .modified),
            .backupVerificationFailed("x"), .writeVerificationFailed("x"), .nothingToApply, .newFilesNotAllowed(2),
            .noSuchBatch("b"), .ambiguousBatch("b"), .notUndoable(batch: "b", state: .undone), .backupsPruned("b"),
        ]
        for e in errors { XCTAssertFalse((e.errorDescription ?? "").isEmpty, "\(e)") }
        XCTAssertTrue(MergeError.newFilesNotAllowed(2).errorDescription!.contains("2"))
        XCTAssertTrue(MergeError.stale(path: "p.txt", planned: .additions, now: .modified).errorDescription!.contains("p.txt"))
    }
}
