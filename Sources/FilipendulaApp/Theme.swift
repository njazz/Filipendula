import SwiftUI
import MergeCore

extension MergeStatus {
    var color: Color {
        switch self {
        case .new: return .blue
        case .identical: return .gray
        case .additions: return .green
        case .modified, .binary: return .yellow
        case .deletionsOnly: return .red
        case .heavyLoss: return Color(red: 0.55, green: 0.08, blue: 0.08)
        }
    }
}

extension BatchState {
    var color: Color {
        switch self {
        case .committed: return .green
        case .pending: return .red
        case .partiallyUndone: return .yellow
        case .undone, .rolledBack: return .gray
        }
    }
    var title: String {
        switch self {
        case .committed: return "committed"
        case .pending: return "interrupted"
        case .partiallyUndone: return "partly undone"
        case .undone: return "undone"
        case .rolledBack: return "rolled back"
        }
    }
    var canUndo: Bool { self == .committed || self == .partiallyUndone || self == .pending }
}

struct StatusDot: View {
    let status: MergeStatus
    var body: some View {
        Circle().fill(status.color).frame(width: 10, height: 10)
    }
}

struct StatusPill: View {
    let status: MergeStatus
    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(status.color.opacity(0.25))
            .overlay(Capsule().stroke(status.color, lineWidth: 1))
            .clipShape(Capsule())
    }
}
