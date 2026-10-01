import SwiftUI
import MergeCore

// MARK: - Tree data

struct TreeNode: Identifiable {
    let id: String
    let name: String
    let change: PlannedChange?
    let children: [TreeNode]?
    let worst: MergeStatus
    let fileIDs: [String]
}

struct TreeRow: Identifiable {
    let id: String
    let depth: Int
    let name: String
    let change: PlannedChange?
    let isDir: Bool
    let isExpanded: Bool
    let worst: MergeStatus
    let fileIDs: [String]
}

enum TreeBuilder {
    private final class Box {
        let name: String
        let path: String
        var dirs: [String: Box] = [:]
        var leaves: [PlannedChange] = []
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    static func build(_ changes: [PlannedChange]) -> [TreeNode] {
        let root = Box(name: "", path: "")
        for c in changes {
            let comps = c.targetRelPath.split(separator: "/").map(String.init)
            var node = root
            for comp in comps.dropLast() {
                let path = node.path.isEmpty ? comp : node.path + "/" + comp
                if let next = node.dirs[comp] {
                    node = next
                } else {
                    let next = Box(name: comp, path: path)
                    node.dirs[comp] = next
                    node = next
                }
            }
            node.leaves.append(c)
        }
        return convert(root)
    }

    private static func convert(_ box: Box) -> [TreeNode] {
        let dirs = box.dirs.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { d -> TreeNode in
                let kids = convert(d)
                let worst = kids.map { $0.worst }.max { $0.severity < $1.severity } ?? .identical
                return TreeNode(id: "dir:" + d.path, name: d.name, change: nil, children: kids,
                                worst: worst, fileIDs: kids.flatMap { $0.fileIDs })
            }
        let files = box.leaves
            .sorted { $0.targetRelPath.localizedStandardCompare($1.targetRelPath) == .orderedAscending }
            .map { c in
                TreeNode(id: c.id,
                         name: c.targetRelPath.split(separator: "/").last.map(String.init) ?? c.targetRelPath,
                         change: c, children: nil, worst: c.status, fileIDs: [c.id])
            }
        return dirs + files
    }

    /// Flattens the tree into rows (respecting collapsed folders) so the List can multi-select them natively.
    static func flatten(_ nodes: [TreeNode], collapsed: Set<String>, depth: Int = 0) -> [TreeRow] {
        var out: [TreeRow] = []
        for n in nodes {
            let isDir = n.children != nil
            let expanded = isDir && !collapsed.contains(n.id)
            out.append(TreeRow(id: n.id, depth: depth, name: n.name, change: n.change, isDir: isDir,
                               isExpanded: expanded, worst: n.worst, fileIDs: n.fileIDs))
            if expanded, let kids = n.children {
                out += flatten(kids, collapsed: collapsed, depth: depth + 1)
            }
        }
        return out
    }
}

// MARK: - Pane

struct TreePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let rows = TreeBuilder.flatten(TreeBuilder.build(model.visibleChanges), collapsed: model.collapsedDirs)
        VStack(spacing: 0) {
            header
            Divider()
            List(rows, selection: $model.selection) { row in
                TreeRowView(row: row)
            }
            .listStyle(.sidebar)
            .overlay { if rows.isEmpty { emptyState } }
        }
    }

    private var header: some View {
        let s = model.summary
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Select all") { model.selectAll() }
                Button("Deselect all") { model.deselectAll() }
                Spacer(minLength: 4)
                Button("Clear") { model.clearPending() }
            }
            .controlSize(.small)
            .disabled(model.changes.isEmpty)

            Text(summaryText(s))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
    }

    private func summaryText(_ s: (dropped: Int, review: Int, identical: Int, notInProject: Int, problems: Int)) -> String {
        if s.dropped == 0 { return model.projectURL == nil ? "No project open" : "Nothing dropped yet" }
        var parts = ["\(s.dropped) dropped", "\(s.review) to review"]
        if s.identical > 0 { parts.append("\(s.identical) identical (no diff)") }
        if s.notInProject > 0 {
            parts.append("\(s.notInProject) not in project" + (model.settings.allowNewFiles ? "" : ", not added"))
        }
        if s.problems > 0 { parts.append("\(s.problems) with problems") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var emptyState: some View {
        let s = model.summary
        VStack(spacing: 8) {
            if model.projectURL == nil {
                Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                Text("Open a project folder").foregroundStyle(.secondary)
            } else if s.dropped == 0 {
                Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                Text("Drop files or folders anywhere").foregroundStyle(.secondary)
            } else if s.identical == s.dropped {
                Image(systemName: "equal.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("No differences").font(.headline)
                Text("All \(s.dropped) dropped file(s) are identical to the project.\nNothing to merge.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Turn on \"Show identical files\" in Setup to list them.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Nothing to review").foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Rows

struct TreeRowView: View {
    let row: TreeRow
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(row.depth) * 14)

            if row.isDir {
                Button { model.toggleCollapsed(row.id) } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            CheckBox(state: model.checkState(row.fileIDs)) {
                model.toggleCheck(rowID: row.id, fileIDs: row.fileIDs)
            }

            StatusDot(status: row.worst)
            if row.isDir { Image(systemName: "folder").foregroundStyle(.secondary) }
            Text(row.name).lineLimit(1)

            if let c = row.change { badges(for: c) }

            Spacer(minLength: 8)

            if let c = row.change {
                Text(stats(for: c)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Check selected") { model.setChecked(true, rowID: row.id, fileIDs: row.fileIDs) }
            Button("Uncheck selected") { model.setChecked(false, rowID: row.id, fileIDs: row.fileIDs) }
            if row.isDir {
                Divider()
                Button(row.isExpanded ? "Collapse" : "Expand") { model.toggleCollapsed(row.id) }
            }
        }
    }

    @ViewBuilder
    private func badges(for c: PlannedChange) -> some View {
        if c.status == .new && !model.settings.allowNewFiles {
            Text("not in project, not added")
                .font(.caption2).foregroundStyle(.orange)
                .help("This file does not exist in the project, so it will not be added. Change this in Setup.")
        }
        if c.isAmbiguous {
            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                .help("Several project files share this name. Best guess selected; review the target.")
        }
        if c.dateRelation == .sourceOlder {
            Image(systemName: "clock").foregroundStyle(.orange)
                .help(c.dateSummary ?? "Source is older than the project file")
        }
        if c.conflict {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                .help("Another dropped file targets the same path.")
        }
        if let issue = c.issue {
            Image(systemName: "xmark.octagon").foregroundStyle(.red).help(issue)
        }
    }

    private func stats(for c: PlannedChange) -> String {
        switch c.status {
        case .binary: return "binary"
        case .new: return model.settings.allowNewFiles ? "+\(c.classification.added)" : "not added"
        case .identical: return "no diff"
        default: return "+\(c.classification.added) −\(c.classification.removed)"
        }
    }
}

struct CheckBox: View {
    let state: CheckState
    let action: () -> Void

    private var symbol: String {
        switch state {
        case .on: return "checkmark.square.fill"
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        case .disabled: return "square.dashed"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .disabled ? Color.secondary.opacity(0.4) : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(state == .disabled)
    }
}
