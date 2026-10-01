import Foundation
import MergeCore

struct Style {
    let color: Bool

    init(noColor: Bool) {
        color = !noColor && isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    func paint(_ s: String, _ code: String) -> String {
        color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    func code(for status: MergeStatus) -> String {
        switch status {
        case .new: return "34"                 // blue
        case .identical: return "90"           // grey
        case .additions: return "32"           // green
        case .modified, .binary: return "33"   // yellow
        case .deletionsOnly: return "31"       // red
        case .heavyLoss: return "1;38;5;124"   // bold dark red
        }
    }

    func badge(_ status: MergeStatus) -> String {
        paint(status.shortLabel.padding(toLength: 13, withPad: " ", startingAt: 0), code(for: status))
    }
}

enum Render {
    static func table(_ changes: [PlannedChange], style: Style, showAll: Bool) {
        let rows = showAll ? changes : changes.filter { $0.status != .identical || $0.issue != nil }
        if rows.isEmpty {
            print("No diff: every dropped file is identical to the project, nothing to merge.")
            return
        }
        for c in rows {
            let stats: String
            switch c.status {
            case .binary: stats = "binary"
            case .new: stats = "+\(c.classification.added)"
            default: stats = "+\(c.classification.added) -\(c.classification.removed)"
            }
            var line = style.badge(c.status)
                + stats.padding(toLength: 12, withPad: " ", startingAt: 0)
                + c.targetRelPath
            var flags: [String] = []
            if c.status == .heavyLoss || c.status == .modified {
                flags.append("\(Int((c.classification.lossRatio * 100).rounded()))% of original removed")
            }
            if let d = c.dateSummary, c.dateRelation != .same { flags.append(d) }
            if c.status == .new { flags.append("not in project") }
            if c.isAmbiguous { flags.append("ambiguous: \(c.candidates.count) candidates") }
            if c.conflict { flags.append("conflict: duplicate target") }
            if let issue = c.issue { flags.append(issue) }
            if !flags.isEmpty { line += style.paint("   (" + flags.joined(separator: "; ") + ")", "90") }
            print(line)
        }
        let same = changes.filter { $0.status == .identical && $0.issue == nil }
        if !showAll && !same.isEmpty {
            let names = same.prefix(4).map { $0.source.lastPathComponent }.joined(separator: ", ")
            print("\nNo diff: \(same.count) file(s) identical to the project, nothing to merge (\(names)\(same.count > 4 ? ", ..." : "")).")
        }
        print("")
        var counts: [MergeStatus: Int] = [:]
        for c in changes { counts[c.status, default: 0] += 1 }
        let summary = MergeStatus.allCases
            .compactMap { s -> String? in
                guard let n = counts[s], n > 0 else { return nil }
                return style.paint("\(n) \(s.shortLabel.lowercased())", style.code(for: s))
            }
            .joined(separator: "  ")
        print(summary)
    }
}

func confirm(_ question: String) -> Bool {
    guard isatty(STDIN_FILENO) == 1 else { return false }
    print("\(question) [y/N] ", terminator: "")
    guard let answer = readLine()?.lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

func resolveDirectory(_ p: String) throws -> URL {
    let path = (p as NSString).expandingTildeInPath
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        throw NSError(domain: "filipendula", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(p)"])
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func resolveSources(_ list: [String]) -> [URL] {
    list.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
}
