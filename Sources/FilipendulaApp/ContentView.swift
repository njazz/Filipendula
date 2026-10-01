import SwiftUI
import MergeCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false
    @State private var confirmCommit = false
    @State private var showSetup = false
    @AppStorage("layout.treeFraction") private var treeFraction = 0.3
    @AppStorage("layout.logFraction") private var logFraction = 0.15

    private var windowTitle: String {
        var t = "Filipendula \(FilipendulaInfo.version)"
        if let p = model.projectURL { t += " — \(p.lastPathComponent)" }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                VStack(spacing: 0) {
                    GeometryReader { top in
                        HStack(spacing: 0) {
                            TreePane().frame(width: max(top.size.width * treeFraction, 240))
                            SplitHandle(axis: .vertical, total: top.size.width, fraction: $treeFraction,
                                        range: 0.15...0.6, growsWithDrag: true)
                            DiffPane().frame(maxWidth: .infinity)
                        }
                    }
                    SplitHandle(axis: .horizontal, total: geo.size.height, fraction: $logFraction,
                                range: 0.08...0.6, growsWithDrag: false)
                    LogPane().frame(height: max(geo.size.height * logFraction, 70))
                }
            }
        }
        .navigationTitle(windowTitle)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .sheet(isPresented: $showSetup) {
            SetupView().environmentObject(model)
        }
        .confirmationDialog(model.commitSummary.title, isPresented: $confirmCommit, titleVisibility: .visible) {
            if model.commitSummary.red > 0 {
                Button("Commit anyway", role: .destructive) { model.commit() }
            } else {
                Button("Commit") { model.commit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.commitSummary.message)
        }
        .alert(model.alert?.title ?? "", isPresented: alertBinding, presenting: model.alert) { a in
            switch a.action {
            case .forceUndo(let batch):
                Button("Overwrite edited files", role: .destructive) { model.undo(batch, force: true) }
                Button("Leave them", role: .cancel) {}
            case .rollback(let batches):
                Button("Roll back") { model.rollback(batches) }
                Button("Later", role: .cancel) {}
            case nil:
                Button("OK", role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { model.chooseProject() } label: { Label("Open Project…", systemImage: "folder") }

            Text(model.projectURL?.path ?? "No project open")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)

            Spacer(minLength: 8)

            if model.isWorking { ProgressView().controlSize(.small) }

            Button { showSetup = true } label: { Label("Setup", systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)

            Button {
                if model.commitSummary.needsConfirmation { confirmCommit = true } else { model.commit() }
            } label: {
                Label("Commit (\(model.selectedChanges.count))", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedChanges.isEmpty || model.isWorking)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
    }
}
