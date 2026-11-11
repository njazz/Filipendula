import Foundation

public enum MatchKind: String, Codable, Sendable {
    case path        // dropped folder structure mirrors the project
    case uniqueName  // exactly one file with that name in the project
    case ambiguous   // several files share the name (or the folder structure looks wrong); best guess picked, user should confirm
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

// MARK: - Relative path helpers

enum RelPath {
    /// "a/b/c.txt" -> "a/b";  "c.txt" -> "" (project root).
    static func directory(of rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[..<slash])
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.isEmpty ? name : dir + "/" + name
    }

    static func components(_ rel: String) -> [String] {
        rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - Similarity

public enum Similarity {
    /// At or above this share of matching lines a same-named file counts as "almost the same file".
    public static let nearMatch = 0.6
    /// Below this the target is probably a different file that merely shares the name.
    public static let lowMatch = 0.3
    /// Files with fewer lines than this are too small for a similarity score to mean anything.
    public static let minLinesForJudgement = 5

    /// Ranking weights: what the file contains matters most, where it sits is the tie-breaker that picks the right
    /// copy among same-named files.
    public static let contentWeight = 0.75
    public static let folderWeight = 0.25

    /// Jaccard overlap of the distinct lines of two files (0...1). Used to rank same-named candidates.
    public static func score(_ a: Data, _ b: Data) -> Double {
        if Classifier.isBinary(a) || Classifier.isBinary(b) { return a == b ? 1 : 0 }
        let opts = ClassifierOptions()
        let sa = Set(Classifier.normalizedLines(a, opts))
        let sb = Set(Classifier.normalizedLines(b, opts))
        let union = sa.union(sb).count
        if union == 0 { return 1 }
        return Double(sa.intersection(sb).count) / Double(union)
    }

    /// How well the folder a source file comes from lines up with a project file's folder (0...1).
    /// `sourceDirs` are the folder names of the source from the outside in; the candidate's folders are compared
    /// from the inside out, so "…/Downloads/src/lib" matches "app/src/lib" on two of three levels.
    /// A candidate in the project root has no folder to match and scores 0.
    public static func folderScore(sourceDirs: [String], candidatePath: String) -> Double {
        let cand = RelPath.components(RelPath.directory(of: candidatePath)).map { $0.lowercased() }
        guard !cand.isEmpty else { return 0 }
        let src = sourceDirs.map { $0.lowercased() }
        var common = 0
        while common < cand.count, common < src.count,
              src[src.count - 1 - common] == cand[cand.count - 1 - common] {
            common += 1
        }
        return Double(common) / Double(cand.count)
    }

    public static func combined(content: Double, folder: Double) -> Double {
        contentWeight * content + folderWeight * folder
    }

    /// "92 %" style helper for messages.
    static func percent(_ x: Double) -> Int { Int((x * 100).rounded()) }
}

/// One same-named project file, scored against a dropped file.
public struct CandidateScore: Codable, Equatable, Sendable {
    public let path: String
    /// Share of matching lines (0...1).
    public let similarity: Double
    /// How well the source's folder lines up with this file's folder (0...1).
    public let folderMatch: Double

    public var score: Double { Similarity.combined(content: similarity, folder: folderMatch) }
}

// MARK: - Where should a new file go?

public struct LocationSuggestion: Codable, Equatable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case mirrorsFolder  // same place as in the dropped folder, and that folder exists in the project
        case siblings       // other files from the same source folder were matched into this folder
        case folderName     // the name of the source folder matches a project folder
        case newFolder      // follows the dropped folder's structure and creates the missing sub-folder(s)
        case sameType       // this folder holds other files of the same type
        case projectRoot
        case replacesExisting  // overwrite the same-named project file that was matched
        case addsInPlace       // keep the matched file and add the source at the path its own folder implies
    }

    /// Full project-relative path including the file name.
    public let relPath: String
    public let reason: Reason
    /// Reason-specific extra: sibling file names, or the file type.
    public let detail: String?

    public var directory: String { RelPath.directory(of: relPath) }

    public var summary: String {
        switch reason {
        case .mirrorsFolder: return "same place as in the dropped folder"
        case .siblings: return detail.map { "next to \($0), which matched here" } ?? "next to files that matched here"
        case .folderName: return "folder name matches the source folder"
        case .newFolder: return "creates new folder(s), as in the dropped folder"
        case .sameType: return detail.map { "other \($0) files live here" } ?? "other files of this type live here"
        case .projectRoot: return "project root"
        case .replacesExisting: return "replace the matching file in the project"
        case .addsInPlace:
            return detail == "new" ? "add as a new file, creating the folder(s) of the source tree"
                                   : "add as a new file in the matching folder of the source tree"
        }
    }
}

/// Another dropped file from the same source folder that already found its place in the project.
struct SiblingTarget: Equatable {
    let dir: String        // project folder it matched into ("" = root)
    let fileName: String
}

struct LocationSuggester {
    let index: ProjectIndex
    private let dirsByLowercase: [String: String]

    init(index: ProjectIndex) {
        self.index = index
        var map: [String: String] = [:]
        for d in index.directories.sorted() { map[d.lowercased()] = map[d.lowercased()] ?? d }
        dirsByLowercase = map
    }

    /// Ranked places to put a file that has no original, best first. Always ends with an entry for the project root
    /// unless that is already listed. The first entry whose reason is not `.sameType` is the default choice.
    ///
    /// - Parameters:
    ///   - sourceDirs: folder names the source file sits in, outside in (used to match folder names).
    ///   - mirrored: the project-relative path implied by a dropped folder's structure, if there is one.
    ///   - mirroredIsProven: the dropped folder's structure demonstrably matches the project (some file matched by
    ///     path), so `mirrored` can be the first choice. Otherwise it only serves to create sub-folders under a folder
    ///     the project already has.
    ///   - siblings: where the other files from the same source folder landed.
    func suggest(fileName: String, sourceDirs: [String], mirrored: String?, mirroredIsProven: Bool = true,
                 siblings: [SiblingTarget], limit: Int = 6) -> [LocationSuggestion] {
        var out: [LocationSuggestion] = []
        var seen = Set<String>()

        func add(_ dir: String, _ reason: LocationSuggestion.Reason, _ detail: String? = nil) {
            let rel = RelPath.join(dir, fileName)
            guard let clean = try? PathRules.validate(rel), clean == rel else { return }
            guard index.byPath[rel] == nil, seen.insert(rel.lowercased()).inserted else { return }
            out.append(LocationSuggestion(relPath: rel, reason: reason, detail: detail))
        }

        // The folder the mirrored path would use, if it is a usable one.
        var mirroredDir: String?
        if let m = mirrored, let clean = try? PathRules.validate(m) {
            mirroredDir = RelPath.directory(of: clean)
        }

        // 1. The dropped folder's own structure, when that folder already exists in the project.
        if mirroredIsProven, let dir = mirroredDir, dir.isEmpty || dirsByLowercase[dir.lowercased()] != nil {
            add(dirsByLowercase[dir.lowercased()] ?? dir, .mirrorsFolder)
        }

        // 2. Folders that the neighbours from the same source folder were matched into, most popular first.
        var votes: [String: (count: Int, names: [String])] = [:]
        for s in siblings {
            var v = votes[s.dir] ?? (count: 0, names: [String]())
            v.count += 1
            v.names.append(s.fileName)
            votes[s.dir] = v
        }
        for (dir, v) in votes.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            add(dir, .siblings, v.names.sorted().prefix(2).joined(separator: ", "))
        }

        // 3. A project folder named like the source folder: the longest matching tail of the source's folders wins.
        //    A full match ("src/lib" == "src/lib") beats a partial one ("lib" at the end of "app/lib").
        var named: [String] = []
        let tail = sourceDirs.suffix(6)
        for k in stride(from: tail.count, through: 1, by: -1) {
            let suffix = tail.suffix(k).joined(separator: "/").lowercased()
            if let exact = dirsByLowercase[suffix], !named.contains(exact) { named.append(exact) }
        }
        for k in stride(from: tail.count, through: 1, by: -1) {
            let suffix = "/" + tail.suffix(k).joined(separator: "/").lowercased()
            for (lower, actual) in dirsByLowercase.sorted(by: { $0.key < $1.key })
            where lower.hasSuffix(suffix) && !named.contains(actual) {
                named.append(actual)
            }
        }
        for dir in named.prefix(3) { add(dir, .folderName) }

        // 4. The dropped folder's structure with folders that don't exist yet. Only when it hangs off a folder the
        //    project already has, otherwise a whole foreign tree would be created.
        if let dir = mirroredDir, !dir.isEmpty, dirsByLowercase[dir.lowercased()] == nil,
           let first = RelPath.components(dir).first, dirsByLowercase[first.lowercased()] != nil {
            add(dir, .newFolder)
        }

        // 5. Folders that hold the most files of the same type (a hint only; never the default).
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            var counts: [String: Int] = [:]
            for f in index.files where (f.name as NSString).pathExtension.lowercased() == ext {
                counts[RelPath.directory(of: f.relPath), default: 0] += 1
            }
            for (dir, _) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(2) {
                add(dir, .sameType, "." + ext)
            }
        }

        // 6. The project root is always an option.
        add("", .projectRoot)

        if out.count > limit {
            let root = out.first { $0.relPath == fileName }
            var trimmed = Array(out.filter { $0.relPath != fileName }.prefix(limit - 1))
            if let root { trimmed.append(root) }
            out = trimmed
        }
        return out
    }

    /// For a file that matched an existing project file: the choice between replacing that file and adding the
    /// source as a new file where its own folder structure says it belongs (`source/Foo/Baz/Bar.hpp` next to a
    /// project `Foo/Bar.hpp` may belong in `Foo/Baz/`). Empty when there is no such second place.
    /// The place comes from the dropped folder's layout (`mirrored`), or else from a project folder that is
    /// named like the tail of the source's folders.
    func inPlaceOptions(fileName: String, matched: String, sourceDirs: [String],
                        mirrored: String?, mirroredIsProven: Bool) -> [LocationSuggestion] {
        var dir: String?
        var proven = mirroredIsProven
        if let m = mirrored, let clean = try? PathRules.validate(m) {
            dir = RelPath.directory(of: clean)
        } else {
            let tail = sourceDirs.suffix(6)
            for k in stride(from: tail.count, through: 1, by: -1) {
                if let exact = dirsByLowercase[tail.suffix(k).joined(separator: "/").lowercased()] {
                    dir = exact
                    proven = true
                    break
                }
            }
        }
        guard let dir else { return [] }
        let rel = RelPath.join(dir, fileName)
        guard (try? PathRules.validate(rel)) == rel, rel.lowercased() != matched.lowercased(),
              index.byPath[rel] == nil else { return [] }

        let exists = dir.isEmpty || dirsByLowercase[dir.lowercased()] != nil
        let anchored = RelPath.components(dir).first.map { dirsByLowercase[$0.lowercased()] != nil } ?? false
        guard exists || anchored || proven else { return [] }
        let actualDir = dirsByLowercase[dir.lowercased()] ?? dir
        return [LocationSuggestion(relPath: matched, reason: .replacesExisting, detail: nil),
                LocationSuggestion(relPath: RelPath.join(actualDir, fileName), reason: .addsInPlace,
                                   detail: exists ? "existing" : "new")]
    }

    /// The suggestion that is used unless the user picks another one.
    static func preferred(_ list: [LocationSuggestion]) -> LocationSuggestion? {
        list.first { $0.reason != .sameType } ?? list.first
    }
}
