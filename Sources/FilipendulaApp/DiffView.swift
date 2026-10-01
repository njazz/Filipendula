import SwiftUI
import MergeCore

struct DiffPane: View {
    @EnvironmentObject var model: AppModel

    private struct Loaded {
        let key: String
        let preview: DiffPreview
    }
    @State private var loaded: Loaded?
    @State private var destination = ""

    /// Identity of "what the diff shows". When it changes, the old diff is dropped immediately and the scroll
    /// view is rebuilt, so scroll position (both axes) always starts at the top for new content.
    private var contentKey: String {
        guard let c = model.focusedChange else { return "none" }
        let target = c.targetModified.map { String($0.timeIntervalSince1970) } ?? "-"
        return [c.id, c.targetRelPath, String(c.classification.added), String(c.classification.removed), target,
                String(model.settings.ignoreTrailingWhitespace), String(model.settings.contextLines)]
            .joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let change = model.focusedChange {
                header(change)
                Divider()
                content(for: change)
            } else {
                Spacer()
                Text("Select a file to see its diff").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .task(id: contentKey) { await loadPreview(key: contentKey) }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ change: PlannedChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusPill(status: change.status)
                if change.status != .identical && change.status != .new && change.status != .binary {
                    Text("+\(change.classification.added)  −\(change.classification.removed)")
                        .font(.callout.monospacedDigit())
                    if change.classification.removed > 0 {
                        Text("\(Int((change.classification.lossRatio * 100).rounded()))% of original removed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Text("From").font(.caption).foregroundStyle(.secondary)
                Text(change.source.path).font(.caption).lineLimit(1).truncationMode(.middle)
            }

            if let s = change.sourceModified {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                    Text("Source \(s.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    if let t = change.targetModified {
                        Text("· Project \(t.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = change.dateSummary {
                        Text(summary).font(.caption.weight(.semibold))
                            .foregroundStyle(change.dateRelation == .sourceOlder ? Color.orange : Color.secondary)
                    }
                }
            }

            if change.status == .new {
                if model.settings.allowNewFiles {
                    HStack {
                        Text("Create at").font(.caption).foregroundStyle(.secondary)
                        TextField("path/in/project.ext", text: $destination)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.retarget(change.id, to: destination) }
                    }
                    .onAppear { destination = change.targetRelPath }
                    .onChange(of: change.id) { _ in destination = change.targetRelPath }
                } else {
                    Label("This file does not exist in the project and will NOT be added. You can allow adding new files in Setup.",
                          systemImage: "nosign")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            } else if change.isAmbiguous {
                Picker("Target", selection: Binding(
                    get: { change.targetRelPath },
                    set: { model.retarget(change.id, to: $0) })
                ) {
                    ForEach(change.candidates, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            } else {
                HStack(spacing: 6) {
                    Text("Into").font(.caption).foregroundStyle(.secondary)
                    Text(change.targetRelPath).font(.caption.weight(.medium))
                }
            }

            if let issue = change.issue {
                Label(issue, systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
            }
            if change.conflict {
                Label("Another dropped file targets the same path", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
        }
        .padding(10)
    }

    // MARK: Body

    @ViewBuilder
    private func content(for change: PlannedChange) -> some View {
        if let l = loaded, l.key == contentKey {
            switch l.preview {
            case .identical:
                noDiff(change)
            case .binary(let oldSize, let newSize):
                VStack(spacing: 4) {
                    Spacer()
                    Text("Binary file").font(.headline)
                    Text("Replaces \(oldSize.map { "\($0) bytes" } ?? "nothing") with \(newSize) bytes")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            case .text(let lines):
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { DiffLineView(line: $0) }
                        }
                        .frame(minWidth: geo.size.width, alignment: .leading)
                    }
                    .id(l.key)   // new content = fresh scroll view = scrolled to the top-left
                }
            }
        } else {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        }
    }

    private func noDiff(_ change: PlannedChange) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "equal.circle.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No differences").font(.title3.weight(.semibold))
            Text("The dropped file is identical to \(change.targetRelPath).\nLine endings and trailing whitespace are ignored. There is nothing to merge.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func loadPreview(key: String) async {
        guard let change = model.focusedChange, let project = model.projectURL else {
            loaded = nil
            return
        }
        let options = model.options
        let context = model.settings.contextLines
        let result = await Task.detached(priority: .userInitiated) { () -> DiffPreview in
            let newData = (try? Data(contentsOf: change.source)) ?? Data()
            let target = project.appendingPathComponent(change.targetRelPath)
            let oldData = try? Data(contentsOf: target)
            return Classifier.preview(old: oldData, new: newData, options: options, context: context)
        }.value
        if !Task.isCancelled { loaded = Loaded(key: key, preview: result) }
    }
}

struct DiffLineView: View {
    let line: DiffLine

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.22)
        case .removed: return Color.red.opacity(0.22)
        case .gap: return Color.gray.opacity(0.12)
        case .context: return Color.clear
        }
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 44, alignment: .trailing)
            if line.kind == .gap {
                Text(line.text).foregroundStyle(.secondary).padding(.leading, 12)
            } else {
                Text(marker).frame(width: 20)
                Text(line.text.isEmpty ? " " : line.text)
            }
            Spacer(minLength: 0)
        }
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(line.kind == .gap ? Color.secondary : Color.primary)
        .padding(.vertical, 1)
        .background(background)
    }
}
