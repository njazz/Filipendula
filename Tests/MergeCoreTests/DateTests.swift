import XCTest
@testable import MergeCore

final class DateTests: XCTestCase {
    func testSourceOlderAndNewerAreDetected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("filipendula-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let target = project.appendingPathComponent("a.txt")
        let source = inbox.appendingPathComponent("a.txt")
        try "a\n".write(to: target, atomically: true, encoding: .utf8)
        try "a\nb\n".write(to: source, atomically: true, encoding: .utf8)

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: source.path)

        let planner = Planner(project: project)
        var c = planner.plan(sources: [source])[0]
        XCTAssertEqual(c.dateRelation, .sourceOlder)
        XCTAssertEqual(c.dateSummary, "source OLDER by 3 days")

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2 * 3600)], ofItemAtPath: source.path)
        c = planner.plan(sources: [source])[0]
        XCTAssertEqual(c.dateRelation, .sourceNewer)
        XCTAssertEqual(c.dateSummary, "source newer by 2 hours")
    }

    func testNewFileHasNoRelation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("filipendula-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("proj"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("n.txt")
        try "x\n".write(to: source, atomically: true, encoding: .utf8)
        let c = Planner(project: root.appendingPathComponent("proj")).plan(sources: [source])[0]
        XCTAssertEqual(c.dateRelation, .unknown)
        XCTAssertNil(c.dateSummary)
        XCTAssertNotNil(c.sourceModified)
    }
}
