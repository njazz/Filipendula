import Foundation

// MARK: - Status

public enum MergeStatus: String, Codable, CaseIterable, Sendable {
    case new            // blue:     no original exists
    case identical      // grey:     nothing to do
    case additions      // green:    only additions
    case modified       // yellow:   some original code removed
    case deletionsOnly  // red:      the new file adds nothing, only deletes
    case heavyLoss      // dark red: adds code but drops a large share of the original
    case binary         // yellow:   binary file replaced (hash compare only)

    public var label: String {
        switch self {
        case .new: return "New file"
        case .identical: return "Identical"
        case .additions: return "Additions only"
        case .modified: return "Removes some original code"
        case .deletionsOnly: return "Only deletions"
        case .heavyLoss: return "Heavy loss"
        case .binary: return "Binary replaced"
        }
    }

    public var shortLabel: String {
        switch self {
        case .new: return "NEW"
        case .identical: return "SAME"
        case .additions: return "ADDS"
        case .modified: return "REMOVES"
        case .deletionsOnly: return "ONLY DELETES"
        case .heavyLoss: return "HEAVY LOSS"
        case .binary: return "BINARY"
        }
    }

    /// Higher = worse. Folders in the tree take the worst child.
    public var severity: Int {
        switch self {
        case .identical: return 0
        case .new: return 1
        case .additions: return 2
        case .modified, .binary: return 3
        case .deletionsOnly: return 4
        case .heavyLoss: return 5
        }
    }

    public var isRed: Bool { self == .deletionsOnly || self == .heavyLoss }
    public var isCaution: Bool { self == .modified || self == .binary }

    /// Green, blue and yellow start checked; both reds start unchecked.
    public var selectedByDefault: Bool {
        switch self {
        case .new, .additions, .modified, .binary: return true
        case .identical, .deletionsOnly, .heavyLoss: return false
        }
    }
}

public struct ClassifierOptions: Sendable, Equatable {
    /// Fraction (0...1) of original lines removed at which "modified" becomes "heavy loss".
    public var lossThreshold: Double
    public var ignoreTrailingWhitespace: Bool

    public init(lossThreshold: Double = 0.4, ignoreTrailingWhitespace: Bool = true) {
        self.lossThreshold = lossThreshold
        self.ignoreTrailingWhitespace = ignoreTrailingWhitespace
    }
}

public struct Classification: Codable, Equatable, Sendable {
    public let status: MergeStatus
    public let added: Int
    public let removed: Int
    public let oldLineCount: Int

    public var lossRatio: Double {
        oldLineCount == 0 ? 0 : Double(removed) / Double(oldLineCount)
    }
}

// MARK: - Preview types

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed, gap }
    public var id: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
}

public enum DiffPreview: Sendable {
    case text([DiffLine])
    case binary(oldSize: Int?, newSize: Int)
    case identical
}

// MARK: - Classifier

public enum Classifier {

    // MARK: Public API

    public static func classify(old: Data?, new: Data, options: ClassifierOptions = ClassifierOptions()) -> Classification {
        let oldIsBinary = old.map { isBinary($0) } ?? false
        if isBinary(new) || oldIsBinary {
            guard let old else {
                return Classification(status: .new, added: 0, removed: 0, oldLineCount: 0)
            }
            return Classification(status: old == new ? .identical : .binary, added: 0, removed: 0, oldLineCount: 0)
        }

        let newLines = normalizedLines(new, options)
        guard let old else {
            return Classification(status: .new, added: newLines.count, removed: 0, oldLineCount: 0)
        }
        let oldLines = normalizedLines(old, options)

        var interner = Interner()
        let a = oldLines.map { interner.id($0) }
        let b = newLines.map { interner.id($0) }
        let d = diff(a, b)

        return makeClassification(added: d.inserted.count, removed: d.removed.count,
                                  oldCount: oldLines.count, options: options)
    }

    /// Unified-style preview with `context` unchanged lines around each change.
    public static func preview(old: Data?, new: Data,
                               options: ClassifierOptions = ClassifierOptions(),
                               context: Int = 3) -> DiffPreview {
        let oldIsBinary = old.map { isBinary($0) } ?? false
        if isBinary(new) || oldIsBinary {
            if let old, old == new { return .identical }
            return .binary(oldSize: old?.count, newSize: new.count)
        }

        let newLines = normalizedLines(new, options)
        guard let old else {
            let lines = newLines.enumerated().map {
                DiffLine(id: $0.offset, kind: .added, text: $0.element, oldNumber: nil, newNumber: $0.offset + 1)
            }
            return .text(lines)
        }
        let oldLines = normalizedLines(old, options)

        var interner = Interner()
        let a = oldLines.map { interner.id($0) }
        let b = newLines.map { interner.id($0) }
        let d = diff(a, b)

        var full: [DiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, d.removed.contains(i) {
                full.append(DiffLine(id: 0, kind: .removed, text: oldLines[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            } else if j < newLines.count, d.inserted.contains(j) {
                full.append(DiffLine(id: 0, kind: .added, text: newLines[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            } else if i < oldLines.count && j < newLines.count {
                full.append(DiffLine(id: 0, kind: .context, text: oldLines[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1
                j += 1
            } else {
                break
            }
        }

        let changed = full.indices.filter { full[$0].kind != .context }
        if changed.isEmpty { return .identical }

        var visible = [Bool](repeating: false, count: full.count)
        for idx in changed {
            let lo = max(0, idx - context)
            let hi = min(full.count - 1, idx + context)
            for k in lo...hi { visible[k] = true }
        }

        var out: [DiffLine] = []
        var hidden = 0
        func flush() {
            if hidden > 0 {
                out.append(DiffLine(id: out.count, kind: .gap, text: "⋯ \(hidden) unchanged lines",
                                    oldNumber: nil, newNumber: nil))
                hidden = 0
            }
        }
        for (k, line) in full.enumerated() {
            if visible[k] {
                flush()
                var l = line
                l.id = out.count
                out.append(l)
            } else {
                hidden += 1
            }
        }
        flush()
        return .text(out)
    }

    // MARK: Internals

    static func makeClassification(added: Int, removed: Int, oldCount: Int, options: ClassifierOptions) -> Classification {
        let status: MergeStatus
        if added == 0 && removed == 0 {
            status = .identical
        } else if removed == 0 {
            status = .additions
        } else if added > 0, oldCount > 0, Double(removed) / Double(oldCount) >= options.lossThreshold {
            status = .heavyLoss
        } else if added == 0 {
            status = .deletionsOnly
        } else {
            status = .modified
        }
        return Classification(status: status, added: added, removed: removed, oldLineCount: oldCount)
    }

    /// NUL byte in the first 8 KB => binary.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    /// Decodes (UTF-8, falling back to Latin-1), normalizes CRLF/CR to LF, optionally trims trailing whitespace.
    static func normalizedLines(_ data: Data, _ options: ClassifierOptions) -> [String] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        if let first = lines.first, first.hasPrefix("\u{FEFF}") {
            lines[0] = String(first.dropFirst())
        }
        if options.ignoreTrailingWhitespace {
            lines = lines.map(trimTrailingWhitespace)
        }
        return lines
    }

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)].isWhitespace {
            end = s.index(before: end)
        }
        return String(s[..<end])
    }

    struct LineDiff {
        var removed: Set<Int>   // indices into old
        var inserted: Set<Int>  // indices into new
    }

    /// Myers diff (CollectionDifference) over interned line ids, after trimming the common prefix/suffix.
    static func diff(_ a: [Int], _ b: [Int]) -> LineDiff {
        let minCount = min(a.count, b.count)
        var prefix = 0
        while prefix < minCount && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < minCount - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])

        var removed = Set<Int>()
        var inserted = Set<Int>()
        if aMid.isEmpty {
            inserted = Set(prefix..<(prefix + bMid.count))
        } else if bMid.isEmpty {
            removed = Set(prefix..<(prefix + aMid.count))
        } else {
            let d = bMid.difference(from: aMid)
            for change in d {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset + prefix)
                case .insert(let offset, _, _): inserted.insert(offset + prefix)
                }
            }
        }
        return LineDiff(removed: removed, inserted: inserted)
    }

    /// Maps each distinct line to a small int so diffing compares ints, with no hash collisions.
    struct Interner {
        private var table: [String: Int] = [:]
        mutating func id(_ s: String) -> Int {
            if let v = table[s] { return v }
            let v = table.count
            table[s] = v
            return v
        }
    }
}
