import XCTest
@testable import MergeCore

final class ClassifierEdgeTests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func lines(_ r: ClosedRange<Int>) -> String { r.map { "line \($0)" }.joined(separator: "\n") + "\n" }

    // MARK: Text handling

    func testByteOrderMarkIsIgnored() {
        XCTAssertEqual(Classifier.classify(old: d("a\nb\n"), new: d("\u{FEFF}a\nb\n")).status, .identical)
    }

    func testLoneCarriageReturnsAreLineBreaks() {
        XCTAssertEqual(Classifier.classify(old: d("a\rb\r"), new: d("a\nb\n")).status, .identical)
        XCTAssertEqual(Classifier.classify(old: d("a\r\nb\r\n"), new: d("a\nb\n")).status, .identical)
    }

    func testMissingFinalNewlineDoesNotMatter() {
        XCTAssertEqual(Classifier.classify(old: d("a\nb"), new: d("a\nb\n")).status, .identical)
    }

    func testTabsAndSpacesAtTheEndOfLinesAreTrimmed() {
        XCTAssertEqual(Classifier.classify(old: d("a\t \nb\n"), new: d("a\nb  \n")).status, .identical)
    }

    func testStrictWhitespaceSeesTrailingChanges() {
        let strict = ClassifierOptions(ignoreTrailingWhitespace: false)
        let c = Classifier.classify(old: d("a\nb\n"), new: d("a  \nb\n"), options: strict)
        XCTAssertNotEqual(c.status, .identical)
        XCTAssertEqual(c.added, 1)
        XCTAssertEqual(c.removed, 1)
    }

    func testIndentationAlwaysCounts() {
        XCTAssertNotEqual(Classifier.classify(old: d("a\n"), new: d("  a\n")).status, .identical)
    }

    func testLatin1FilesAreComparedWithoutCrashing() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])      // "café" with a Latin-1 é: invalid UTF-8
        XCTAssertEqual(Classifier.classify(old: latin1, new: latin1).status, .identical)
        XCTAssertEqual(Classifier.classify(old: latin1, new: d("café\ntea\n")).status, .additions)
    }

    func testEmptyFiles() {
        XCTAssertEqual(Classifier.classify(old: d(""), new: d("")).status, .identical)
        XCTAssertEqual(Classifier.classify(old: d(""), new: d("a\n")).status, .additions)
        let c = Classifier.classify(old: d("a\n"), new: d(""))
        XCTAssertEqual(c.status, .deletionsOnly)
        XCTAssertEqual(c.lossRatio, 1)
    }

    func testNewEmptyFileIsNewWithNothingAdded() {
        let c = Classifier.classify(old: nil, new: d(""))
        XCTAssertEqual(c.status, .new)
        XCTAssertEqual(c.added, 0)
    }

    // MARK: Thresholds

    func testLossThresholdIsInclusive() {
        let old = d(lines(1...10))
        let new = d(lines(5...10) + "x\n")                       // 4 of 10 removed, 1 added
        XCTAssertEqual(Classifier.classify(old: old, new: new).status, .heavyLoss)
        XCTAssertEqual(Classifier.classify(old: old, new: new, options: .init(lossThreshold: 0.41)).status, .modified)
        XCTAssertEqual(Classifier.classify(old: old, new: new, options: .init(lossThreshold: 0.4)).removed, 4)
    }

    func testHeavyLossNeedsSomethingAdded() {
        // Dropping most of the file without adding anything is red, not dark red.
        XCTAssertEqual(Classifier.classify(old: d(lines(1...10)), new: d(lines(1...2))).status, .deletionsOnly)
    }

    func testLossRatioGuardsAgainstDivisionByZero() {
        XCTAssertEqual(Classification(status: .new, added: 3, removed: 0, oldLineCount: 0).lossRatio, 0)
        XCTAssertEqual(Classification(status: .modified, added: 1, removed: 2, oldLineCount: 4).lossRatio, 0.5)
    }

    // MARK: Binary

    func testBinaryDetectionLooksOnlyAtTheFirst8KB() {
        var late = Data(repeating: 0x61, count: 9000)
        late[8500] = 0
        XCTAssertFalse(Classifier.isBinary(late))
        var early = Data(repeating: 0x61, count: 9000)
        early[10] = 0
        XCTAssertTrue(Classifier.isBinary(early))
    }

    func testTextReplacedByBinaryAndBack() {
        let bin = Data([0, 1, 2, 3])
        XCTAssertEqual(Classifier.classify(old: d("a\n"), new: bin).status, .binary)
        XCTAssertEqual(Classifier.classify(old: bin, new: d("a\n")).status, .binary)
    }

    // MARK: Status table

    func testStatusProperties() {
        let severities = MergeStatus.allCases.map(\.severity)
        XCTAssertEqual(MergeStatus.identical.severity, 0)
        XCTAssertEqual(MergeStatus.heavyLoss.severity, severities.max())
        XCTAssertEqual(MergeStatus.modified.severity, MergeStatus.binary.severity)
        XCTAssertLessThan(MergeStatus.new.severity, MergeStatus.additions.severity)

        XCTAssertEqual(Set(MergeStatus.allCases.filter(\.isRed)), [.deletionsOnly, .heavyLoss])
        XCTAssertEqual(Set(MergeStatus.allCases.filter(\.isCaution)), [.modified, .binary])
        XCTAssertEqual(Set(MergeStatus.allCases.filter(\.selectedByDefault)), [.new, .additions, .modified, .binary])

        XCTAssertEqual(Set(MergeStatus.allCases.map(\.label)).count, MergeStatus.allCases.count)
        XCTAssertEqual(Set(MergeStatus.allCases.map(\.shortLabel)).count, MergeStatus.allCases.count)
    }

    // MARK: Preview

    func testPreviewOfIdenticalAndBinaryAndNew() {
        if case .identical = Classifier.preview(old: d("a\n"), new: d("a  \r\n")) {} else { XCTFail("expected identical") }

        let bin = Data([0, 9])
        if case .binary(let oldSize, let newSize) = Classifier.preview(old: nil, new: bin) {
            XCTAssertNil(oldSize)
            XCTAssertEqual(newSize, 2)
        } else { XCTFail("expected binary") }
        if case .identical = Classifier.preview(old: bin, new: bin) {} else { XCTFail("expected identical") }

        guard case .text(let out) = Classifier.preview(old: nil, new: d("x\ny\n")) else { return XCTFail("expected text") }
        XCTAssertEqual(out.map(\.kind), [.added, .added])
        XCTAssertEqual(out.map(\.newNumber), [1, 2])
    }

    func testPreviewLineNumbersFollowBothFiles() {
        guard case .text(let out) = Classifier.preview(old: d("a\nb\nc\n"), new: d("a\nX\nc\n")) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(out.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(out.map(\.oldNumber), [1, 2, nil, 3])
        XCTAssertEqual(out.map(\.newNumber), [1, nil, 2, 3])
        XCTAssertEqual(out.map(\.id), [0, 1, 2, 3], "ids must be unique and sequential for the list view")
    }

    func testPreviewGapReportsHowManyLinesAreHidden() {
        let old = lines(1...30)
        let new = old.replacingOccurrences(of: "line 15\n", with: "changed\n")
        guard case .text(let out) = Classifier.preview(old: d(old), new: d(new), context: 1) else {
            return XCTFail("expected text")
        }
        let gaps = out.filter { $0.kind == .gap }
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps.map(\.text), ["⋯ 13 unchanged lines", "⋯ 14 unchanged lines"])
        XCTAssertEqual(Set(out.map(\.id)).count, out.count)
    }

    func testPreviewWithZeroContextShowsOnlyTheChange() {
        guard case .text(let out) = Classifier.preview(old: d(lines(1...5)), new: d(lines(1...5).replacingOccurrences(of: "line 3", with: "x")),
                                                       context: 0) else { return XCTFail("expected text") }
        XCTAssertEqual(out.filter { $0.kind == .context }.count, 0)
        XCTAssertEqual(out.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(out.filter { $0.kind == .added }.count, 1)
    }

    func testPreviewCountsMatchTheClassification() {
        let old = lines(1...40)
        let new = lines(1...10) + "inserted\n" + lines(12...40).replacingOccurrences(of: "line 30", with: "edited")
        let c = Classifier.classify(old: d(old), new: d(new))
        guard case .text(let out) = Classifier.preview(old: d(old), new: d(new), context: 2) else { return XCTFail("expected text") }
        XCTAssertEqual(out.filter { $0.kind == .added }.count, c.added)
        XCTAssertEqual(out.filter { $0.kind == .removed }.count, c.removed)
    }

    func testLargeFilesWithASmallChangeAreFast() {
        let old = (1...20_000).map { "row \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "row 10000\n", with: "row ten thousand\n")
        let start = Date()
        let c = Classifier.classify(old: d(old), new: d(new))
        XCTAssertEqual(c.status, .modified)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
