import SwiftUI
import AppKit
import MergeCore

// MARK: - Small types

struct AppAlert {
    enum Action {
        case forceUndo(String)
        case rollback([String])
    }
    var title: String
    var message: String
    var action: Action?
}

enum CheckState {
    case on, off, mixed, disabled
}

struct ActivityEvent: Identifiable {
    enum Kind { case info, success, warning }
    let id = UUID()
    let time: Date
    let kind: Kind
    let message: String
}

struct CommitSummary {
    var count = 0
    var caution = 0
    var red = 0
    var trash = 0
    var lines: [String] = []
    var needsConfirmation = false

    var title: String { "Commit \(count) file(s)?" }
    var message: String {
        (lines.map { "• " + $0 } + ["Originals are backed up first. The batch can be undone from the log."])
            .joined(separator: "\n")
    }
}

// MARK: - Settings (everything behind the Setup button)

struct AppSettings: Codable, Equatable {
    var lossThresholdPercent: Double = 40
    var ignoreTrailingWhitespace = true
    var showIdentical = false
    /// Off by default: dropped files that don't exist in the project are listed but never added.
    var allowNewFiles = false
    /// Off by default: move merged source files to the Trash after a commit (always asks first).
    var trashSourcesAfterCommit = false
    var confirmYellow = true
    var contextLines = 3

    private enum CodingKeys: String, CodingKey {
        case lossThresholdPercent, ignoreTrailingWhitespace, showIdentical, allowNewFiles
        case trashSourcesAfterCommit, confirmYellow, contextLines
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        lossThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .lossThresholdPercent) ?? d.lossThresholdPercent
        ignoreTrailingWhitespace = try c.decodeIfPresent(Bool.self, forKey: .ignoreTrailingWhitespace) ?? d.ignoreTrailingWhitespace
        showIdentical = try c.decodeIfPresent(Bool.self, forKey: .showIdentical) ?? d.showIdentical
        allowNewFiles = try c.decodeIfPresent(Bool.self, forKey: .allowNewFiles) ?? d.allowNewFiles
        trashSourcesAfterCommit = try c.decodeIfPresent(Bool.self, forKey: .trashSourcesAfterCommit) ?? d.trashSourcesAfterCommit
        confirmYellow = try c.decodeIfPresent(Bool.self, forKey: .confirmYellow) ?? d.confirmYellow
        contextLines = try c.decodeIfPresent(Int.self, forKey: .contextLines) ?? d.contextLines
    }

    private static let storageKey = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    // Project and pending drops
    @Published private(set) var projectURL: URL?
    @Published private(set) var changes: [PlannedChange] = [] {
        didSet {
            changeIndex = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    private(set) var changeIndex: [String: PlannedChange] = [:]

    /// Which files will be committed (the checkboxes).
    @Published var checked: Set<String> = []
    /// Rows highlighted in the tree (multi-selection). Files and "dir:" rows.
    @Published var selection: Set<String> = [] {
        didSet { updateFocus(previous: oldValue) }
    }
    /// The file shown in the diff pane.
    @Published var focusedID: String?
    @Published var collapsedDirs: Set<String> = []

    @Published var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    // Log
    @Published private(set) var batches: [JournalEntry] = []
    @Published private(set) var activity: [ActivityEvent] = []

    // UI state
    @Published private(set) var isWorking = false
    @Published var alert: AppAlert?

    private var sources: [URL] = []
    private var planner: Planner?
    private var planGeneration = 0
    private var pendingDropLog = false

    private static let lastProjectKey = "lastProjectPath"

    init() {
        settings = AppSettings.load()
        if let path = UserDefaults.standard.string(forKey: Self.lastProjectKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                openProject(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    }

    // MARK: Derived state

    var options: ClassifierOptions {
        ClassifierOptions(lossThreshold: settings.lossThresholdPercent / 100,
                          ignoreTrailingWhitespace: settings.ignoreTrailingWhitespace)
    }

    var visibleChanges: [PlannedChange] {
        settings.showIdentical ? changes : changes.filter { $0.status != .identical || $0.issue != nil }
    }

    var focusedChange: PlannedChange? { focusedID.flatMap { changeIndex[$0] } }

    /// Can this change be committed at all? New files only if adding them is allowed in Setup.
    func isCommittable(_ c: PlannedChange) -> Bool {
        c.status != .identical && c.issue == nil && (c.status != .new || settings.allowNewFiles)
    }

    func defaultChecked(_ c: PlannedChange) -> Bool {
        isCommittable(c) && c.status.selectedByDefault && !c.conflict && !c.isAmbiguous
    }

    var selectedChanges: [PlannedChange] {
        changes.filter { checked.contains($0.id) && isCommittable($0) }
    }

    var summary: (dropped: Int, review: Int, identical: Int, notInProject: Int, problems: Int) {
        var review = 0, identical = 0, notInProject = 0, problems = 0
        for c in changes {
            if c.issue != nil { problems += 1 }
            else if c.status == .identical { identical += 1 }
            else if c.status == .new { notInProject += 1 }
            else { review += 1 }
        }
        return (changes.count, review, identical, notInProject, problems)
    }

    var commitSummary: CommitSummary {
        let sel = selectedChanges
        var s = CommitSummary()
        s.count = sel.count
        s.caution = sel.filter { $0.status.isCaution }.count
        s.red = sel.filter { $0.status.isRed }.count
        s.trash = settings.trashSourcesAfterCommit ? Set(sel.map { $0.source.path }).count : 0
        if s.red > 0 { s.lines.append("\(s.red) red file(s): they add little, or lose a lot of the original") }
        if s.caution > 0 && settings.confirmYellow { s.lines.append("\(s.caution) yellow file(s): they remove some original code") }
        if s.trash > 0 { s.lines.append("\(s.trash) dropped file(s) will be moved to the Trash afterwards") }
        s.needsConfirmation = s.red > 0 || (s.caution > 0 && settings.confirmYellow) || s.trash > 0
        return s
    }

    // MARK: Project

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    func openProject(_ url: URL) {
        projectURL = url
        UserDefaults.standard.set(url.path, forKey: Self.lastProjectKey)
        sources = []
        changes = []
        checked = []
        selection = []
        focusedID = nil
        collapsedDirs = []
        planner = nil
        activity = []
        log("Opened \(url.path)")
        reloadJournal(checkPending: true)
    }

    // MARK: Drops

    func handleDrop(_ urls: [URL]) {
        guard projectURL != nil else {
            if urls.count == 1, Self.isDirectory(urls[0]) {
                openProject(urls[0])
            } else {
                alert = AppAlert(title: "Open a project first",
                                 message: "Choose the project folder (or drop a single folder here to open it), then drop files to merge.",
                                 action: nil)
            }
            return
        }
        for u in urls where !sources.contains(u) { sources.append(u) }
        pendingDropLog = true
        replan()
    }

    func clearPending() {
        sources = []
        changes = []
        checked = []
        selection = []
        focusedID = nil
        log("Cleared the list of dropped files.")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: Planning

    func replan() {
        guard let project = projectURL else { return }
        let existing = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
        sources = existing
        guard !existing.isEmpty else {
            changes = []
            checked = []
            selection = []
            focusedID = nil
            return
        }
        let options = self.options

        planGeneration += 1
        let generation = planGeneration
        isWorking = true
        Task.detached(priority: .userInitiated) {
            let planner = Planner(project: project, options: options)
            let result = planner.plan(sources: existing)
            await self.finishPlan(planner: planner, result: result, generation: generation)
        }
    }

    private func finishPlan(planner: Planner, result: [PlannedChange], generation: Int) {
        guard generation == planGeneration else { return }
        isWorking = false
        self.planner = planner

        let previous = changeIndex
        var newChecked = Set<String>()
        for c in result where isCommittable(c) {
            if c.status == .additions && !c.isAmbiguous && !c.conflict {
                newChecked.insert(c.id)                       // green is always (re)checked
            } else if let old = previous[c.id], old.status == c.status {
                if checked.contains(c.id) { newChecked.insert(c.id) }
            } else if defaultChecked(c) {
                newChecked.insert(c.id)
            }
        }
        let freshIDs = Set(result.map { $0.id }).subtracting(previous.keys)

        changes = result
        checked = newChecked

        if let f = focusedID, changeIndex[f] == nil { focusedID = nil }
        if focusedID == nil { focusedID = visibleChanges.first?.id }
        selection = focusedID.map { [$0] } ?? []

        if pendingDropLog {
            pendingDropLog = false
            logDrop(result.filter { freshIDs.contains($0.id) })
        }
    }

    private func logDrop(_ fresh: [PlannedChange]) {
        guard !fresh.isEmpty else {
            log("Those files are already in the list.")
            return
        }
        let problems = fresh.filter { $0.issue != nil }
        let identical = fresh.filter { $0.issue == nil && $0.status == .identical }
        let notInProject = fresh.filter { $0.issue == nil && $0.status == .new }
        let review = fresh.filter { $0.issue == nil && $0.status != .identical && $0.status != .new }

        if !review.isEmpty {
            var parts: [String] = []
            let green = review.filter { $0.status == .additions }.count
            let yellow = review.filter { $0.status.isCaution }.count
            let red = review.filter { $0.status.isRed }.count
            if green > 0 { parts.append("\(green) green") }
            if yellow > 0 { parts.append("\(yellow) yellow") }
            if red > 0 { parts.append("\(red) red") }
            log("Dropped \(fresh.count) file(s): \(review.count) to review (\(parts.joined(separator: ", "))).")
        }
        if !identical.isEmpty {
            let names = Self.nameList(identical)
            if identical.count == fresh.count {
                log("No diff: all \(identical.count) dropped file(s) are identical to the project, nothing to merge (\(names)).")
            } else {
                log("No diff for \(identical.count) file(s): identical to the project (\(names)).")
            }
        }
        if !notInProject.isEmpty {
            let names = Self.nameList(notInProject)
            if settings.allowNewFiles {
                log("\(notInProject.count) file(s) not in the project; they will be added if checked (\(names)).")
            } else {
                log("Not in the project, will NOT be added: \(names).", .warning)
            }
        }
        for p in problems.prefix(5) {
            log("Problem with \(p.source.lastPathComponent): \(p.issue ?? "unknown")", .warning)
        }
    }

    private static func nameList(_ items: [PlannedChange], limit: Int = 4) -> String {
        let names = items.map { $0.source.lastPathComponent }
        let head = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? head + " (+\(names.count - limit) more)" : head
    }

    func retarget(_ id: String, to rel: String) {
        guard let planner, let idx = changes.firstIndex(where: { $0.id == id }) else { return }
        var updated = changes
        updated[idx] = planner.retarget(changes[idx], to: rel)
        changes = Planner.resolveConflicts(updated)
        if defaultChecked(changes[idx]) { checked.insert(id) } else { checked.remove(id) }
    }

    // MARK: Settings reactions

    private func settingsChanged(from old: AppSettings) {
        settings.save()
        if old.lossThresholdPercent != settings.lossThresholdPercent
            || old.ignoreTrailingWhitespace != settings.ignoreTrailingWhitespace {
            replan()
        }
        if old.allowNewFiles != settings.allowNewFiles {
            let newIDs = changes.filter { $0.status == .new }.map { $0.id }
            if settings.allowNewFiles {
                for c in changes where c.status == .new && defaultChecked(c) { checked.insert(c.id) }
            } else {
                checked.subtract(newIDs)
            }
            if !newIDs.isEmpty {
                log(settings.allowNewFiles
                    ? "Adding new files is ON: \(newIDs.count) file(s) not in the project can now be added."
                    : "Adding new files is OFF: \(newIDs.count) file(s) not in the project will not be added.",
                    settings.allowNewFiles ? .info : .warning)
            }
        }
    }

    // MARK: Selection and checkboxes

    private func updateFocus(previous: Set<String>) {
        let added = selection.subtracting(previous)
        if let id = added.first(where: { changeIndex[$0] != nil }) { focusedID = id }
    }

    func toggleCollapsed(_ rowID: String) {
        if collapsedDirs.contains(rowID) { collapsedDirs.remove(rowID) } else { collapsedDirs.insert(rowID) }
    }

    func checkState(_ fileIDs: [String]) -> CheckState {
        var on = 0, total = 0
        for id in fileIDs {
            guard let c = changeIndex[id], isCommittable(c) else { continue }
            total += 1
            if checked.contains(id) { on += 1 }
        }
        if total == 0 { return .disabled }
        if on == 0 { return .off }
        return on == total ? .on : .mixed
    }

    /// Clicking a checkbox flips it for its row. If that row is part of a multi-selection, it flips for all of them.
    func toggleCheck(rowID: String, fileIDs: [String]) {
        let state = checkState(fileIDs)
        guard state != .disabled else { return }
        setChecked(state != .on, rowID: rowID, fileIDs: fileIDs)
    }

    func setChecked(_ on: Bool, rowID: String, fileIDs: [String]) {
        var ids = Set(fileIDs)
        if selection.contains(rowID) && selection.count > 1 {
            for sel in selection { ids.formUnion(expandRow(sel)) }
        }
        for id in ids {
            guard let c = changeIndex[id], isCommittable(c) else { continue }
            if on { checked.insert(id) } else { checked.remove(id) }
        }
    }

    private func expandRow(_ rowID: String) -> [String] {
        guard rowID.hasPrefix("dir:") else { return [rowID] }
        let prefix = String(rowID.dropFirst(4)) + "/"
        return visibleChanges.filter { $0.targetRelPath.hasPrefix(prefix) }.map { $0.id }
    }

    func selectAll() {
        checked = Set(changes.filter { isCommittable($0) && !$0.conflict }.map { $0.id })
    }

    func deselectAll() {
        checked = []
    }

    // MARK: Commit

    func commit() {
        guard let project = projectURL else { return }
        let selected = selectedChanges
        guard !selected.isEmpty else { return }
        let options = self.options
        let allowNew = settings.allowNewFiles
        let trash = settings.trashSourcesAfterCommit
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let ops = Operations(project: project, options: options)
                let entry = try ops.apply(selected, allowNew: allowNew)
                let trashed = trash ? ops.trashSources(of: selected, entry: entry) : []
                await self.finishCommit(entry, trashed: trashed)
            } catch {
                await self.fail(error)
            }
        }
    }

    private func finishCommit(_ entry: JournalEntry, trashed: [TrashOutcome]) {
        isWorking = false
        log("Committed \(entry.ops.count) file(s) as batch \(entry.batch). Undo it from the list below.", .success)
        for note in entry.notes where note.hasPrefix("Not in project") { log(note, .warning) }

        let moved = trashed.filter { $0.trashed }
        if !moved.isEmpty { log("Moved \(moved.count) dropped file(s) to the Trash.", .success) }
        for t in trashed where !t.trashed {
            log("Kept \(URL(fileURLWithPath: t.source).lastPathComponent) in place: \(t.reason ?? "unknown reason").", .warning)
        }
        sources.removeAll { !FileManager.default.fileExists(atPath: $0.path) }

        reloadJournal(checkPending: false)
        replan()   // committed files are now identical and drop out of the list
    }

    // MARK: Undo

    func undo(_ batch: String, force: Bool = false) {
        guard let project = projectURL else { return }
        let options = self.options
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let report = try Operations(project: project, options: options).undo(batch: batch, force: force)
                await self.finishUndo(report)
            } catch {
                await self.fail(error)
            }
        }
    }

    private func finishUndo(_ report: UndoReport) {
        isWorking = false
        reloadJournal(checkPending: false)
        replan()

        var lines: [String] = []
        let restored = report.results.filter { $0.outcome == .restored || $0.outcome == .deleted }.count
        if restored > 0 { lines.append("\(restored) file(s) restored.") }
        for r in report.skippedCorrupt { lines.append("Skipped \(r.path): backup unusable (\(r.detail ?? "corrupt")). The current file was left as is.") }
        for r in report.skippedModified { lines.append("Skipped \(r.path): edited after the commit.") }
        for r in report.failed { lines.append("Failed \(r.path): \(r.detail ?? "unknown error")") }

        let clean = report.isComplete && report.skippedModified.isEmpty && report.skippedCorrupt.isEmpty && report.failed.isEmpty
        log(clean ? "Undid batch \(report.batch): \(restored) file(s) restored."
                  : "Batch \(report.batch) only partly undone.",
            clean ? .success : .warning)
        if clean { return }
        alert = AppAlert(title: report.isComplete ? "Batch undone" : "Batch partly undone",
                         message: lines.joined(separator: "\n"),
                         action: report.skippedModified.isEmpty ? nil : .forceUndo(report.batch))
    }

    func rollback(_ batchIDs: [String]) {
        guard let project = projectURL else { return }
        let options = self.options
        isWorking = true
        Task.detached(priority: .userInitiated) {
            let ops = Operations(project: project, options: options)
            for id in batchIDs { _ = try? ops.undo(batch: id) }
            await self.finishRollback()
        }
    }

    private func finishRollback() {
        isWorking = false
        log("Rolled back the interrupted commit.", .success)
        reloadJournal(checkPending: false)
        replan()
    }

    // MARK: Maintenance (used by the Setup window)

    func pruneCandidateCount(days: Int) -> Int {
        guard let project = projectURL else { return 0 }
        return Operations(project: project).pruneCandidates(olderThanDays: days).count
    }

    @discardableResult
    func prune(days: Int) -> String {
        guard let project = projectURL else { return "No project open." }
        let message: String
        do {
            let report = try Operations(project: project).prune(olderThanDays: days)
            reloadJournal(checkPending: false)
            let mb = Double(report.bytesFreed) / 1_048_576
            message = "Removed backups of \(report.batches.count) batch(es), freed \(String(format: "%.1f", mb)) MB."
        } catch {
            message = "Prune failed: \(error.localizedDescription)"
        }
        log(message)
        return message
    }

    @discardableResult
    func addToGitignore() -> String {
        guard let project = projectURL else { return "No project open." }
        let message: String
        do {
            message = try Operations.addToGitignore(project: project)
                ? "Added .merge_backup/ to .gitignore."
                : ".gitignore already covers .merge_backup."
        } catch {
            message = "Could not update .gitignore: \(error.localizedDescription)"
        }
        log(message)
        return message
    }

    func revealBackups() {
        guard let project = projectURL else { return }
        let dir = project.appendingPathComponent(".merge_backup", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([project])
        }
    }

    // MARK: Journal and activity log

    func reloadJournal(checkPending: Bool) {
        guard let project = projectURL else { batches = []; return }
        let entries = Journal(directory: project.appendingPathComponent(".merge_backup", isDirectory: true)).load()
        batches = entries.reversed()
        if checkPending {
            let pending = entries.filter { $0.state == .pending }
            if !pending.isEmpty {
                alert = AppAlert(
                    title: "Interrupted commit found",
                    message: "A previous merge didn't finish (\(pending.map { $0.batch }.joined(separator: ", "))). Roll it back from the verified backups?",
                    action: .rollback(pending.map { $0.batch }))
            }
        }
    }

    func log(_ message: String, _ kind: ActivityEvent.Kind = .info) {
        activity.append(ActivityEvent(time: Date(), kind: kind, message: message))
        if activity.count > 300 { activity.removeFirst(activity.count - 300) }
    }

    private func fail(_ error: Error) {
        isWorking = false
        reloadJournal(checkPending: false)
        log("Failed: \(error.localizedDescription)", .warning)
        alert = AppAlert(title: "Operation failed", message: error.localizedDescription, action: nil)
    }
}
