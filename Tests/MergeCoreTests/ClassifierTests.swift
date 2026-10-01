import XCTest
@testable import MergeCore

final class ClassifierTests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func lines(_ r: ClosedRange<Int>) -> String {
        r.map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func testNewFile() {
        let c = Classifier.classify(old: nil, new: d("a\nb\n"))
        XCTAssertEqual(c.status, .new)
        XCTAssertEqual(c.added, 2)
    }

    func testIdentical() {
        XCTAssertEqual(Classifier.classify(old: d("a\nb\n"), new: d("a\nb\n")).status, .identical)
    }

    func testCRLFAndTrailingWhitespaceAreIgnored() {
        let c = Classifier.classify(old: d("a\nb\n"), new: d("a  \r\nb\r\n"))
        XCTAssertEqual(c.status, .identical)
    }

    func testAdditionsOnly() {
        let c = Classifier.classify(old: d("a\nb\n"), new: d("a\nx\nb\n"))
        XCTAssertEqual(c.status, .additions)
        XCTAssertEqual(c.added, 1)
        XCTAssertEqual(c.removed, 0)
    }

    func testModifiedIsYellow() {
        let new = lines(1...10).replacingOccurrences(of: "line 5", with: "changed")
        let c = Classifier.classify(old: d(lines(1...10)), new: d(new))
        XCTAssertEqual(c.status, .modified)
        XCTAssertEqual(c.added, 1)
        XCTAssertEqual(c.removed, 1)
    }

    func testDeletionsOnlyIsRed() {
        let c = Classifier.classify(old: d(lines(1...5)), new: d(lines(1...3)))
        XCTAssertEqual(c.status, .deletionsOnly)
        XCTAssertEqual(c.removed, 2)
        XCTAssertEqual(c.added, 0)
    }

    func testEmptyReplacementIsDeletionsOnly() {
        XCTAssertEqual(Classifier.classify(old: d(lines(1...5)), new: d("")).status, .deletionsOnly)
    }

    func testHeavyLossIsDarkRed() {
        let c = Classifier.classify(old: d(lines(1...10)), new: d("line 1\nline 2\nbrand new\n"))
        XCTAssertEqual(c.status, .heavyLoss)
        XCTAssertEqual(c.removed, 8)
        XCTAssertEqual(c.added, 1)
    }

    func testThresholdIsConfigurable() {
        let old = d(lines(1...10))
        let new = d(lines(1...9).replacingOccurrences(of: "line 9", with: "changed")) // -2 +1 => 20%
        XCTAssertEqual(Classifier.classify(old: old, new: new).status, .modified)
        XCTAssertEqual(Classifier.classify(old: old, new: new, options: .init(lossThreshold: 0.15)).status, .heavyLoss)
    }

    func testBinary() {
        let a = Data([0x00, 0x01, 0x02])
        let b = Data([0x00, 0x01, 0x03])
        XCTAssertEqual(Classifier.classify(old: a, new: b).status, .binary)
        XCTAssertEqual(Classifier.classify(old: a, new: a).status, .identical)
        XCTAssertEqual(Classifier.classify(old: nil, new: a).status, .new)
    }

    func testPreviewCollapsesUnchangedRuns() {
        let old = lines(1...50)
        let new = old.replacingOccurrences(of: "line 25\n", with: "changed\n")
        guard case .text(let out) = Classifier.preview(old: d(old), new: d(new), context: 2) else {
            return XCTFail("expected text preview")
        }
        XCTAssertTrue(out.contains { $0.kind == .gap })
        XCTAssertEqual(out.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(out.filter { $0.kind == .added }.count, 1)
        XCTAssertLessThan(out.count, 15)
    }

    func testStatusSeverityOrder() {
        XCTAssertLessThan(MergeStatus.additions.severity, MergeStatus.modified.severity)
        XCTAssertLessThan(MergeStatus.modified.severity, MergeStatus.deletionsOnly.severity)
        XCTAssertLessThan(MergeStatus.deletionsOnly.severity, MergeStatus.heavyLoss.severity)
    }
}
