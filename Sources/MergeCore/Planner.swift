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
    /// Share of identical lines between the source and the chosen target (0...1). Nil for new files and unreadable files.
    public var similarity: Double? = nil
    /// Every project file with the same name, scored against the source, best match first (the chosen target leads).
    /// Filled whenever more than one file shares the name.
    public var candidateScores: [CandidateScore] = []
    /// Where a new file (no original) could go, best first. The target path is the preferred entry.
    public var suggestions: [LocationSuggestion] = []
    /// For a change that matched an existing file: replace it, or add the source as a new file where its own folder
    /// structure puts it. Empty when there is only one sensible place.
    public var placements: [LocationSuggestion] = []
    /// Why this target was picked, when that needs saying.
    public var note: String? = nil
    /// The user explicitly asked for this new file to be created. Only honoured for changes planned as `.new`.
    public var addNew: Bool = false

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

    /// The target exists and shares the name, but hardly any lines: probably a different file. A target the user
    /// picked by hand is never flagged.
    public var isLowSimilarity: Bool {
        guard matchKind != .manual, matchKind != .none, status != .identical, status != .new,
              let s = similarity else { return false }
        return classification.oldLineCount >= Similarity.minLinesForJudgement && s < Similarity.lowMatch
    }

    /// Should be looked at before it is committed (never checked by default, skipped by the CLI without a flag).
    public var needsConfirmation: Bool { isAmbiguous || isLowSimilarity }
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
        let candidates = expand(sources)
        let suggester = LocationSuggester(index: index)
        var result = candidates.map { cand -> PlannedChange in
            var c = planOne(cand, matcher: matcher)
            c.sourceModified = Planner.modificationDate(cand.url)
            if c.issue == nil, c.matchKind != .none {
                c.placements = suggester.inPlaceOptions(fileName: cand.url.lastPathComponent, matched: c.targetRelPath,
                                                        sourceDirs: cand.context, mirrored: cand.mirrored,
                                                        mirroredIsProven: cand.hint != nil)
            }
            return c
        }
        result = locateNewFiles(result, candidates)
        for i in result.indices {
            result[i].targetModified = result[i].status == .new
                ? nil
                : index.byPath[result[i].targetRelPath].flatMap { Planner.modificationDate($0.url) }
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
        c.note = nil
        c.issue = nil
        if let file = index.byPath[clean] {
            guard let oldData = try? Data(contentsOf: file.url) else {
                c.issue = "Cannot read target"
                return c
            }
            c.classification = Classifier.classify(old: oldData, new: newData, options: options)
            c.similarity = Similarity.score(newData, oldData)
        } else {
            c.classification = Classifier.classify(old: nil, new: newData, options: options)
            c.similarity = nil
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
        /// Project-relative path implied by a dropped folder whose structure demonstrably mirrors the project
        /// (at least one file matched by path). Nil for single files and for folders that matched nothing.
        let hint: String?
        /// Best guess of the project path the dropped folder's structure implies, even when nothing matched.
        let mirrored: String?
        /// Folder names the source sits in, outside in.
        let context: [String]
        /// Files from the same source folder share this key.
        let folderKey: String
    }

    /// Expands dropped folders into files. For each folder it decides whether its internal structure
    /// mirrors the project root ("src/a.swift") or the folder itself is a subfolder ("<folder>/a.swift").
    func expand(_ sources: [URL]) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ url: URL, hint: String?, mirrored: String?) {
            let std = url.standardizedFileURL
            if seen.insert(std.path).inserted {
                let dir = std.deletingLastPathComponent()
                out.append(Candidate(url: url, hint: hint, mirrored: mirrored,
                                     context: dir.pathComponents.filter { $0 != "/" },
                                     folderKey: dir.path))
            }
        }
        for src in sources {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                add(src, hint: nil, mirrored: nil)
                continue
            }
            let files = ProjectScanner.regularFiles(in: src)
            let prefix = src.lastPathComponent
            let plainHits = files.filter { index.byPath[$0.rel] != nil }.count
            let prefixedHits = files.filter { index.byPath[prefix + "/" + $0.rel] != nil }.count
            let usePrefix = prefixedHits >= plainHits && prefixedHits > 0
            let trusted = plainHits > 0 || prefixedHits > 0
            for f in files {
                let path = usePrefix ? prefix + "/" + f.rel : f.rel
                add(f.url, hint: trusted ? path : nil, mirrored: path)
            }
        }
        return out
    }

    private func scoreCandidates(_ files: [ProjectFile], newData: Data, context: [String]) -> [CandidateScore] {
        files.map { f -> CandidateScore in
            let data = (try? Data(contentsOf: f.url)) ?? Data()
            return CandidateScore(path: f.relPath,
                                  similarity: Similarity.score(newData, data),
                                  folderMatch: Similarity.folderScore(sourceDirs: context, candidatePath: f.relPath))
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    }

    private func planOne(_ cand: Candidate, matcher: Matcher) -> PlannedChange {
        let url = cand.url
        let name = url.lastPathComponent
        let empty = Classification(status: .identical, added: 0, removed: 0, oldLineCount: 0)

        guard let newData = try? Data(contentsOf: url) else {
            return PlannedChange(source: url, targetRelPath: cand.hint ?? name, matchKind: .none, candidates: [],
                                 classification: empty, conflict: false, issue: "Cannot read source file")
        }

        let match = matcher.match(relPath: cand.hint, fileName: name)
        if match.kind == .none || match.kind == .manual {
            // The final location is chosen in `locateNewFiles`, once the siblings are known.
            return PlannedChange(source: url, targetRelPath: name, matchKind: .none, candidates: [],
                                 classification: Classifier.classify(old: nil, new: newData, options: options),
                                 conflict: false, issue: nil)
        }

        let sameName = index.byName[name] ?? []
        var kind = match.kind
        var chosen = match.files[0]
        var scores: [CandidateScore] = []
        var note: String?

        switch match.kind {
        case .ambiguous:
            scores = scoreCandidates(sameName, newData: newData, context: cand.context)
            if let first = scores.first, let file = index.byPath[first.path] { chosen = file }
            if scores.count > 1 {
                let second = scores[1]
                let first = scores[0]
                note = first.score - second.score < 0.1
                    ? "\(scores.count) files named \(name) fit about equally well. Best guess: \(first.path) (\(Similarity.percent(first.similarity))% of lines match)."
                    : "\(scores.count) files are named \(name). Best fit: \(first.path) (\(Similarity.percent(first.similarity))% of lines match)."
            }

        case .path:
            // The dropped folder points at one file. Check that it really is the file this one updates: if hardly any
            // lines match while another file with the same name matches well, suggest that one instead.
            if sameName.count > 1 {
                scores = scoreCandidates(sameName, newData: newData, context: cand.context)
                if let pathScore = scores.first(where: { $0.path == chosen.relPath }),
                   pathScore.similarity < Similarity.nearMatch,
                   let best = scores.first(where: { $0.path != chosen.relPath && $0.similarity >= Similarity.nearMatch
                                                        && $0.similarity - pathScore.similarity >= 0.25 }),
                   let file = index.byPath[best.path] {
                    note = "The folder structure points to \(chosen.relPath), but only \(Similarity.percent(pathScore.similarity))% of its lines match. "
                        + "\(best.path) matches \(Similarity.percent(best.similarity))%, so that one is suggested."
                    chosen = file
                    kind = .ambiguous
                }
            }

        default:
            break
        }

        guard let oldData = try? Data(contentsOf: chosen.url) else {
            return PlannedChange(source: url, targetRelPath: chosen.relPath, matchKind: kind,
                                 candidates: scores.map(\.path), classification: empty,
                                 conflict: false, issue: "Cannot read project file")
        }

        // Chosen target first, the rest by fit.
        if scores.count > 1, let at = scores.firstIndex(where: { $0.path == chosen.relPath }), at != 0 {
            scores.insert(scores.remove(at: at), at: 0)
        }
        var change = PlannedChange(source: url, targetRelPath: chosen.relPath, matchKind: kind,
                                   candidates: scores.count > 1 ? scores.map(\.path) : [],
                                   classification: Classifier.classify(old: oldData, new: newData, options: options),
                                   conflict: false, issue: nil)
        change.similarity = Similarity.score(newData, oldData)
        change.candidateScores = scores.count > 1 ? scores : []
        change.note = note
        return change
    }

    /// Second pass: decides where each new file goes, using what the first pass learned about its neighbours.
    private func locateNewFiles(_ changes: [PlannedChange], _ cands: [Candidate]) -> [PlannedChange] {
        guard changes.contains(where: { $0.matchKind == .none && $0.issue == nil }) else { return changes }

        var neighbours: [String: [SiblingTarget]] = [:]
        for (c, cand) in zip(changes, cands) where c.issue == nil && (c.matchKind == .path || c.matchKind == .uniqueName) {
            neighbours[cand.folderKey, default: []]
                .append(SiblingTarget(dir: RelPath.directory(of: c.targetRelPath), fileName: cand.url.lastPathComponent))
        }

        let suggester = LocationSuggester(index: index)
        var out = changes
        for i in out.indices where out[i].matchKind == .none && out[i].issue == nil {
            let cand = cands[i]
            let list = suggester.suggest(fileName: cand.url.lastPathComponent,
                                         sourceDirs: cand.context,
                                         mirrored: cand.mirrored,
                                         mirroredIsProven: cand.hint != nil,
                                         siblings: neighbours[cand.folderKey] ?? [])
            out[i].suggestions = list
            if let best = LocationSuggester.preferred(list) {
                out[i].targetRelPath = best.relPath
                if best.reason != .projectRoot { out[i].note = "Suggested location: \(best.summary)." }
            }
        }
        return out
    }
}
