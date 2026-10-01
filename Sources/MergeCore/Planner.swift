import Foundation

public struct PlannedChange: Identifiable, Codable, Equatable, Sendable {
    public var id: String { source.path }
    public let source: URL
    public var targetRelPath: String
    public var matchKind: MatchKind
    /// Ranked project paths (best first) when the filename matched several files.
    public var candidates: [String]
    public var classification: Classification
    /// Another change earlier in the list already targets the same path.
    public var conflict: Bool
    /// Unreadable source/target or invalid path. Such changes are never applied.
    public var issue: String?
    /// File modification dates, informational only (they never change the classification).
    public var sourceModified: Date? = nil
    public var targetModified: Date? = nil

    public enum DateRelation: Sendable { case sourceNewer, sourceOlder, same, unknown }

    public var dateRelation: DateRelation {
        guard let s = sourceModified, let t = targetModified else { return .unknown }
        let d = s.timeIntervalSince(t)
        if abs(d) < 2 { return .same }
        return d > 0 ? .sourceNewer : .sourceOlder
    }

    /// e.g. "source newer by 2 days", "source OLDER by 3 hours", "same modification date".
    public var dateSummary: String? {
        guard let s = sourceModified, let t = targetModified else { return nil }
        let delta = abs(s.timeIntervalSince(t))
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 1
        f.unitsStyle = .full
        let span = f.string(from: delta) ?? "\(Int(delta)) s"
        switch dateRelation {
        case .sourceNewer: return "source newer by \(span)"
        case .sourceOlder: return "source OLDER by \(span)"
        case .same: return "same modification date"
        case .unknown: return nil
        }
    }

    public var status: MergeStatus { classification.status }
    public var isAmbiguous: Bool { matchKind == .ambiguous }
}

public struct Planner: Sendable {
    public let project: URL
    public let index: ProjectIndex
    public var options: ClassifierOptions

    public init(project: URL, options: ClassifierOptions = ClassifierOptions()) {
        self.project = project.standardizedFileURL.resolvingSymlinksInPath()
        self.options = options
        self.index = ProjectScanner.scan(self.project)
    }

    // MARK: Plan

    public func plan(sources: [URL]) -> [PlannedChange] {
        let matcher = Matcher(index: index)
        let result = expand(sources).map { cand -> PlannedChange in
            var c = planOne(cand.url, hint: cand.hint, matcher: matcher)
            c.sourceModified = Planner.modificationDate(cand.url)
            c.targetModified = index.byPath[c.targetRelPath].flatMap { Planner.modificationDate($0.url) }
            return c
        }
        return Planner.resolveConflicts(result)
    }

    /// User picked a different target (or a new destination) for a change.
    public func retarget(_ change: PlannedChange, to rel: String) -> PlannedChange {
        var c = change
        guard let clean = try? PathRules.validate(rel) else {
            c.issue = "Invalid target path"
            return c
        }
        guard let newData = try? Data(contentsOf: change.source) else {
            c.issue = "Cannot read source"
            return c
        }
        c.targetRelPath = clean
        c.targetModified = index.byPath[clean].flatMap { Planner.modificationDate($0.url) }
        c.matchKind = .manual
        c.issue = nil
        if let file = index.byPath[clean] {
            guard let oldData = try? Data(contentsOf: file.url) else {
                c.issue = "Cannot read target"
                return c
            }
            c.classification = Classifier.classify(old: oldData, new: newData, options: options)
        } else {
            c.classification = Classifier.classify(old: nil, new: newData, options: options)
        }
        return c
    }

    public static func resolveConflicts(_ changes: [PlannedChange]) -> [PlannedChange] {
        var out = changes
        var seen = Set<String>()
        for i in out.indices {
            out[i].conflict = false
            guard out[i].status != .identical else { continue }
            if !seen.insert(out[i].targetRelPath.lowercased()).inserted {
                out[i].conflict = true
            }
        }
        return out
    }

    // MARK: Internals

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    struct Candidate {
        let url: URL
        let hint: String?   // project-relative path implied by a dropped folder
    }

    /// Expands dropped folders into files. For each folder it decides whether its internal structure
    /// mirrors the project root ("src/a.swift") or the folder itself is a subfolder ("<folder>/a.swift").
    func expand(_ sources: [URL]) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ url: URL, _ hint: String?) {
            if seen.insert(url.standardizedFileURL.path).inserted {
                out.append(Candidate(url: url, hint: hint))
            }
        }
        for src in sources {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                add(src, nil)
                continue
            }
            let files = ProjectScanner.regularFiles(in: src)
            let prefix = src.lastPathComponent
            let plainHits = files.filter { index.byPath[$0.rel] != nil }.count
            let prefixedHits = files.filter { index.byPath[prefix + "/" + $0.rel] != nil }.count
            let usePrefix = prefixedHits >= plainHits
            for f in files {
                add(f.url, usePrefix ? prefix + "/" + f.rel : f.rel)
            }
        }
        return out
    }

    private func planOne(_ url: URL, hint: String?, matcher: Matcher) -> PlannedChange {
        let name = url.lastPathComponent
        let empty = Classification(status: .identical, added: 0, removed: 0, oldLineCount: 0)

        guard let newData = try? Data(contentsOf: url) else {
            return PlannedChange(source: url, targetRelPath: hint ?? name, matchKind: .none, candidates: [],
                                 classification: empty, conflict: false, issue: "Cannot read source file")
        }

        let match = matcher.match(relPath: hint, fileName: name)
        switch match.kind {
        case .none, .manual:
            let rel = (hint.flatMap { try? PathRules.validate($0) }) ?? name
            return PlannedChange(source: url, targetRelPath: rel, matchKind: .none, candidates: [],
                                 classification: Classifier.classify(old: nil, new: newData, options: options),
                                 conflict: false, issue: nil)

        case .path, .uniqueName, .ambiguous:
            var files = match.files
            if match.kind == .ambiguous {
                let scored = files.map { f -> (ProjectFile, Double) in
                    let d = (try? Data(contentsOf: f.url)) ?? Data()
                    return (f, Similarity.score(newData, d))
                }
                files = scored.sorted {
                    $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.relPath < $1.0.relPath
                }.map { $0.0 }
            }
            let best = files[0]
            guard let oldData = try? Data(contentsOf: best.url) else {
                return PlannedChange(source: url, targetRelPath: best.relPath, matchKind: match.kind,
                                     candidates: files.map(\.relPath), classification: empty,
                                     conflict: false, issue: "Cannot read project file")
            }
            return PlannedChange(source: url, targetRelPath: best.relPath, matchKind: match.kind,
                                 candidates: match.kind == .ambiguous ? files.map(\.relPath) : [],
                                 classification: Classifier.classify(old: oldData, new: newData, options: options),
                                 conflict: false, issue: nil)
        }
    }
}
