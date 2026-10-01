import SwiftUI
import MergeCore

/// Session events (drops, "no diff", skipped files, commits) and committed batches in one timeline, newest first.
private enum LogItem: Identifiable {
    case event(ActivityEvent)
    case batch(JournalEntry)

    var id: String {
        switch self {
        case .event(let e): return "e-" + e.id.uuidString
        case .batch(let b): return "b-" + b.batch
        }
    }

    var time: Date {
        switch self {
        case .event(let e): return e.time
        case .batch(let b): return b.time
        }
    }
}

struct LogPane: View {
    @EnvironmentObject var model: AppModel

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var items: [LogItem] {
        let all = model.activity.map { LogItem.event($0) } + model.batches.map { LogItem.batch($0) }
        return all.sorted { $0.time > $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Text("\(model.batches.count) batch(es)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            let list = items
            if list.isEmpty {
                Text("Nothing logged yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(list) { item in
                        switch item {
                        case .event(let e): eventRow(e)
                        case .batch(let b): batchRow(b)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Rows

    private func eventRow(_ e: ActivityEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.df.string(from: e.time)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Image(systemName: icon(e.kind)).foregroundStyle(color(e.kind))
            Text(e.message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func icon(_ k: ActivityEvent.Kind) -> String {
        switch k {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ k: ActivityEvent.Kind) -> Color {
        switch k {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        }
    }

    private func batchRow(_ entry: JournalEntry) -> some View {
        DisclosureGroup {
            ForEach(entry.ops) { op in
                HStack(spacing: 8) {
                    Text(op.op == .create ? "CREATE" : "REPLACE")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    StatusDot(status: op.status)
                    Text(op.path).lineLimit(1).truncationMode(.middle)
                    if op.undone == true {
                        Text("undone").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(op.op == .create ? "+\(op.added)" : "+\(op.added) −\(op.removed)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 8) {
                Text(Self.df.string(from: entry.time)).font(.callout.monospacedDigit())
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text("Batch \(entry.batch)").font(.callout)
                Text("\(entry.ops.count) file(s)").font(.callout).foregroundStyle(.secondary)
                if entry.pruned == true { Text("backups pruned").font(.caption).foregroundStyle(.secondary) }
                Text(entry.state.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(entry.state.color.opacity(0.25))
                    .clipShape(Capsule())
                Spacer()
                if entry.state.canUndo && entry.pruned != true {
                    Button(entry.state == .pending ? "Roll back" : "Undo batch") {
                        model.undo(entry.batch)
                    }
                    .disabled(model.isWorking)
                }
            }
        }
    }
}
