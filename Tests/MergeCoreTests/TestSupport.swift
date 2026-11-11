import XCTest
@testable import MergeCore

/// A temp folder holding a `proj` (the project) and an `inbox` (where dropped files come from), cleaned up afterwards.
class TempProjectTestCase: XCTestCase {
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

    // MARK: Helpers

    @discardableResult
    func write(_ s: String, _ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func inProject(_ rel: String, _ text: String) throws -> URL { try write(text, project.appendingPathComponent(rel)) }

    @discardableResult
    func inInbox(_ rel: String, _ text: String) throws -> URL { try write(text, inbox.appendingPathComponent(rel)) }

    func read(_ rel: String) -> String? { try? String(contentsOf: project.appendingPathComponent(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: project.appendingPathComponent(rel).path) }

    func plan(_ sources: URL..., options: ClassifierOptions = ClassifierOptions()) -> [PlannedChange] {
        Planner(project: project, options: options).plan(sources: sources)
    }

    /// "prefix 1\nprefix 2\n…" with `count` distinct lines.
    func numbered(_ prefix: String, _ count: Int, from start: Int = 1) -> String {
        (start..<(start + count)).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
    }

    func change(_ plan: [PlannedChange], named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> PlannedChange {
        try XCTUnwrap(plan.first { $0.source.lastPathComponent == name }, "no planned change for \(name)", file: file, line: line)
    }
}
