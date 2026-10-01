import ArgumentParser
import Foundation
import MergeCore

@main
struct FilipendulaCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "filipendula",
        abstract: "Classify and merge files into a project, with backups and undo.",
        discussion: """
        Colors:  green = additions only · yellow = removes some original code
                 red = only deletions · dark red = heavy loss · blue = new file
        Backups and the journal live in <project>/.merge_backup and are shared with the Filipendula app.
        """,
        version: FilipendulaInfo.version,
        subcommands: [Plan.self, Apply.self, Log.self, Undo.self, Prune.self, Gitignore.self]
    )
}

struct Common: ParsableArguments {
    @Argument(help: "Project directory.")
    var project: String

    @Argument(help: "Files or folders to merge into the project.")
    var sources: [String]

    @Option(name: .customLong("loss-threshold"),
            help: "Percent of original lines removed at which a change counts as heavy loss.")
    var lossThreshold: Double = 40

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("strict-whitespace"), help: "Treat trailing-whitespace changes as differences.")
    var strictWhitespace = false

    var options: ClassifierOptions {
        ClassifierOptions(lossThreshold: lossThreshold / 100, ignoreTrailingWhitespace: !strictWhitespace)
    }
}

// MARK: - plan

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dry run: show how each source file compares to the project. Exits 2 if anything is red.")

    @OptionGroup var common: Common
    @Flag(help: "Machine-readable output.") var json = false
    @Flag(name: .customLong("show-all"), help: "Also list identical files.") var showAll = false

    func run() throws {
        let project = try resolveDirectory(common.project)
        let planner = Planner(project: project, options: common.options)
        let changes = planner.plan(sources: resolveSources(common.sources))

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.keyEncodingStrategy = .convertToSnakeCase
            enc.dateEncodingStrategy = .iso8601
            print(String(decoding: try enc.encode(changes), as: UTF8.self))
        } else {
            Render.table(changes, style: Style(noColor: common.noColor), showAll: showAll)
        }
        if changes.contains(where: { $0.status.isRed }) { throw ExitCode(2) }
    }
}

// MARK: - apply

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply changes as one backed-up batch. Defaults to green and blue only.")

    @OptionGroup var common: Common

    @Option(help: "Comma-separated: green, blue, yellow, red, darkred, all (or status names).")
    var include: String = "green,blue"

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    @Flag(name: .customLong("add-new"),
          help: "Also create files that don't exist in the project. Without this they are listed and skipped.")
    var addNew = false

    @Flag(name: .customLong("trash-sources"),
          help: "After a successful apply, move the merged source files to the Trash (asks unless -y).")
    var trashSources = false

    @Flag(name: .customLong("accept-ambiguous"),
          help: "Also apply files whose target was a best guess among several same-named files.")
    var acceptAmbiguous = false

    func run() throws {
        let project = try resolveDirectory(common.project)
        let style = Style(noColor: common.noColor)
        let allowed = try Self.statuses(from: include)

        let planner = Planner(project: project, options: common.options)
        let changes = planner.plan(sources: resolveSources(common.sources))

        var selected: [PlannedChange] = []
        var skipped: [(PlannedChange, String)] = []
        for c in changes where c.status != .identical {
            if let issue = c.issue { skipped.append((c, issue)) }
            else if c.status == .new && !addNew { skipped.append((c, "not in the project, will not be added (use --add-new)")) }
            else if c.conflict { skipped.append((c, "duplicate target")) }
            else if c.isAmbiguous && !acceptAmbiguous { skipped.append((c, "ambiguous target (use --accept-ambiguous)")) }
            else if !allowed.contains(c.status) { skipped.append((c, "not in --include")) }
            else { selected.append(c) }
        }

        print("Will apply:")
        Render.table(selected, style: style, showAll: false)
        if !skipped.isEmpty {
            print("\nSkipped:")
            for (c, why) in skipped {
                print("  " + style.badge(c.status) + c.targetRelPath + style.paint("   (\(why))", "90"))
            }
        }
        guard !selected.isEmpty else { throw ExitCode(skipped.isEmpty ? 0 : 1) }

        let trashNote = trashSources ? " and move their sources to the Trash" : ""
        if !yes && !confirm("\nApply \(selected.count) file(s) to \(project.path)\(trashNote)?") {
            print("Aborted.")
            throw ExitCode(1)
        }

        let ops = Operations(project: project, options: common.options)
        let entry = try ops.apply(selected, allowNew: addNew)
        if trashSources {
            for o in ops.trashSources(of: selected, entry: entry) {
                print(o.trashed ? "Moved to Trash: \(o.source)" : "Kept \(o.source): \(o.reason ?? "unknown reason")")
            }
        }
        print("\nCommitted batch \(entry.batch): \(entry.ops.count) file(s). Undo with: filipendula undo \(common.project) \(entry.batch)")
    }

    static func statuses(from list: String) throws -> Set<MergeStatus> {
        var out = Set<MergeStatus>()
        for raw in list.split(separator: ",") {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "green", "additions": out.insert(.additions)
            case "blue", "new": out.insert(.new)
            case "yellow", "modified": out.formUnion([.modified, .binary])
            case "binary": out.insert(.binary)
            case "red", "deletions", "deletionsonly": out.insert(.deletionsOnly)
            case "darkred", "heavy", "heavyloss": out.insert(.heavyLoss)
            case "all": out.formUnion(MergeStatus.allCases.filter { $0 != .identical })
            default: throw ValidationError("Unknown --include value '\(raw)'")
            }
        }
        return out
    }
}

// MARK: - log

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List committed batches and their file operations.")

    @Argument(help: "Project directory.") var project: String
    @Flag(help: "Machine-readable output.") var json = false
    @Flag(name: .customLong("no-color")) var noColor = false

    func run() throws {
        let url = try resolveDirectory(project)
        let entries = Operations(project: url).journal.load()

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.keyEncodingStrategy = .convertToSnakeCase
            enc.dateEncodingStrategy = .iso8601
            print(String(decoding: try enc.encode(entries), as: UTF8.self))
            return
        }
        let style = Style(noColor: noColor)
        if entries.isEmpty { print("No batches yet."); return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in entries {
            let stateColor: String
            switch e.state {
            case .committed: stateColor = "32"
            case .pending: stateColor = "1;31"
            case .partiallyUndone: stateColor = "33"
            default: stateColor = "90"
            }
            print("\(e.batch)  " + style.paint(e.state.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0), stateColor)
                  + " \(e.ops.count) file(s)  \(df.string(from: e.time))")
            for op in e.ops {
                let mark = op.undone == true ? " (undone)" : ""
                print("    \(op.op.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
                      + style.badge(op.status) + "\(op.path)\(mark)")
            }
            if e.pruned == true { print(style.paint("    backups pruned: cannot be undone", "90")) }
            for note in e.notes { print(style.paint("    note: \(note)", "90")) }
            if e.state == .pending {
                print(style.paint("    interrupted batch: run `filipendula undo` to roll it back", "1;31"))
            }
        }
    }
}

// MARK: - undo

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore files from a batch's verified backups.",
        discussion: """
        Each backup is hash-checked against the journal before it is used; a corrupt or missing backup is \
        skipped and reported. Files edited after the commit are not overwritten unless you confirm or pass --force.
        """)

    @Argument(help: "Project directory.") var project: String
    @Argument(help: "Batch id or unique prefix. Defaults to the latest undoable batch.") var batch: String?
    @Flag(help: "Overwrite files that were edited after the commit.") var force = false

    func run() throws {
        let url = try resolveDirectory(project)
        let ops = Operations(project: url)

        let id: String
        if let batch { id = batch }
        else if let latest = ops.latestUndoable() { id = latest.batch }
        else { print("Nothing to undo."); return }

        var report = try ops.undo(batch: id, force: force)
        printReport(report)

        if !force, !report.skippedModified.isEmpty,
           confirm("\n\(report.skippedModified.count) file(s) were edited after the commit. Overwrite them anyway?") {
            report = try ops.undo(batch: id, force: true)
            printReport(report)
        }
        if !report.isComplete { throw ExitCode(1) }
    }

    private func printReport(_ r: UndoReport) {
        print("Batch \(r.batch): \(r.finalState.rawValue)")
        for res in r.results {
            print("  \(res.outcome.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)) \(res.path)"
                  + (res.detail.map { "  (\($0))" } ?? ""))
        }
    }
}

// MARK: - prune

struct Prune: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete backups of old, finished batches. Those batches can no longer be undone.")

    @Argument(help: "Project directory.") var project: String
    @Option(name: .customLong("older-than"), help: "Age in days.") var olderThan: Int = 30
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    func run() throws {
        let url = try resolveDirectory(project)
        let ops = Operations(project: url)
        let candidates = ops.pruneCandidates(olderThanDays: olderThan)
        guard !candidates.isEmpty else { print("Nothing older than \(olderThan) days to prune."); return }
        for c in candidates { print("  \(c.batch)  \(c.state.rawValue)  \(c.ops.count) file(s)") }
        if !yes && !confirm("\nDelete backups of \(candidates.count) batch(es)? They can't be undone afterwards.") {
            print("Aborted.")
            throw ExitCode(1)
        }
        let report = try ops.prune(olderThanDays: olderThan)
        let mb = Double(report.bytesFreed) / 1_048_576
        print("Pruned \(report.batches.count) batch(es), freed \(String(format: "%.1f", mb)) MB.")
    }
}

// MARK: - gitignore

struct Gitignore: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add .merge_backup/ to the project's .gitignore.")

    @Argument(help: "Project directory.") var project: String

    func run() throws {
        let url = try resolveDirectory(project)
        print(try Operations.addToGitignore(project: url) ? "Added .merge_backup/ to .gitignore." : ".gitignore already covers .merge_backup.")
    }
}
