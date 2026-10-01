import Foundation

public enum MatchKind: String, Codable, Sendable {
    case path        // dropped folder structure mirrors the project
    case uniqueName  // exactly one file with that name in the project
    case ambiguous   // several files share the name; best guess picked, user should confirm
    case none        // no original: new file
    case manual      // user chose the target
}

public struct Match: Sendable {
    public let kind: MatchKind
    public let files: [ProjectFile]
}

public struct Matcher: Sendable {
    public let index: ProjectIndex
    public init(index: ProjectIndex) { self.index = index }

    /// 1. relative path  2. unique filename  3. several candidates  4. nothing.
    public func match(relPath: String?, fileName: String) -> Match {
        if let rel = relPath, let f = index.byPath[rel] {
            return Match(kind: .path, files: [f])
        }
        let named = index.byName[fileName] ?? []
        switch named.count {
        case 0: return Match(kind: .none, files: [])
        case 1: return Match(kind: .uniqueName, files: named)
        default: return Match(kind: .ambiguous, files: named)
        }
    }
}

public enum Similarity {
    /// Jaccard overlap of the distinct lines of two files (0...1). Used to rank ambiguous candidates.
    public static func score(_ a: Data, _ b: Data) -> Double {
        if Classifier.isBinary(a) || Classifier.isBinary(b) { return a == b ? 1 : 0 }
        let opts = ClassifierOptions()
        let sa = Set(Classifier.normalizedLines(a, opts))
        let sb = Set(Classifier.normalizedLines(b, opts))
        let union = sa.union(sb).count
        if union == 0 { return 1 }
        return Double(sa.intersection(sb).count) / Double(union)
    }
}
