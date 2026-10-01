import SwiftUI
import MergeCore

/// Every option lives here. Opened with the "Setup" button (or ⌘,).
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pruneDays = 30
    @State private var confirmPrune = false
    @State private var maintenanceMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Classification") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Heavy-loss threshold: \(Int(model.settings.lossThresholdPercent))%")
                        Slider(value: $model.settings.lossThresholdPercent, in: 10...90, step: 5)
                        Text("A file that adds code but removes at least this share of the original lines is marked heavy loss (dark red).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Ignore trailing whitespace", isOn: $model.settings.ignoreTrailingWhitespace)
                    Text("Line endings (CRLF/LF) are always ignored when comparing.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Files") {
                    Toggle("Allow adding new files (not in the project)", isOn: $model.settings.allowNewFiles)
                    Text("Off: dropped files that don't exist in the project are listed but never added. On: they can be checked and are created at the path you choose.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Move dropped files to the Trash after a commit", isOn: $model.settings.trashSourcesAfterCommit)
                    Text("Only files that were merged, and only if they are unchanged since the commit. Always asks first. Files go to the Trash, they are not deleted permanently.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Show identical files in the tree", isOn: $model.settings.showIdentical)
                }

                Section("Safety") {
                    Toggle("Ask before committing yellow files", isOn: $model.settings.confirmYellow)
                    Text("Yellow means some original lines are removed. Red files always ask.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Diff") {
                    Stepper("Context lines: \(model.settings.contextLines)", value: $model.settings.contextLines, in: 1...10)
                }

                Section("Backups") {
                    HStack {
                        Stepper("Older than \(pruneDays) days", value: $pruneDays, in: 1...365)
                        Button("Prune…") { confirmPrune = true }
                            .disabled(model.pruneCandidateCount(days: pruneDays) == 0)
                    }
                    Text("\(model.pruneCandidateCount(days: pruneDays)) finished batch(es) match. Pruned batches can no longer be undone.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Reveal backups in Finder") { model.revealBackups() }
                        Button("Add .merge_backup/ to .gitignore") { maintenanceMessage = model.addToGitignore() }
                    }
                    if let maintenanceMessage {
                        Text(maintenanceMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.projectURL == nil)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Filipendula \(FilipendulaInfo.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to defaults") { model.settings = AppSettings() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 520, idealHeight: 700)
        .confirmationDialog("Delete the backups of \(model.pruneCandidateCount(days: pruneDays)) batch(es) older than \(pruneDays) days?",
                            isPresented: $confirmPrune, titleVisibility: .visible) {
            Button("Delete backups", role: .destructive) { maintenanceMessage = model.prune(days: pruneDays) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Those batches can no longer be undone.")
        }
    }
}
