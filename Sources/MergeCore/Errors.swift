import Foundation

public enum MergeError: LocalizedError {
    case invalidPath(String)
    case duplicateTarget(String)
    case stale(path: String, planned: MergeStatus, now: MergeStatus)
    case backupVerificationFailed(String)
    case writeVerificationFailed(String)
    case nothingToApply
    case newFilesNotAllowed(Int)
    case noSuchBatch(String)
    case ambiguousBatch(String)
    case notUndoable(batch: String, state: BatchState)
    case backupsPruned(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let p):
            return "Invalid or unsafe target path: \(p)"
        case .duplicateTarget(let p):
            return "Two selected files map to the same target: \(p)"
        case .stale(let path, let planned, let now):
            return "\(path) changed since the plan was made (was \(planned.label), now \(now.label)). Re-plan and review again."
        case .backupVerificationFailed(let p):
            return "Backup of \(p) could not be verified. Nothing was modified."
        case .writeVerificationFailed(let p):
            return "Written file \(p) did not match the expected hash. The batch was rolled back."
        case .nothingToApply:
            return "Nothing to apply."
        case .newFilesNotAllowed(let n):
            return "\(n) file(s) do not exist in the project and adding new files is turned off, so nothing was added."
        case .noSuchBatch(let b):
            return "No batch matching '\(b)'."
        case .ambiguousBatch(let b):
            return "Batch id '\(b)' is ambiguous; use more characters."
        case .notUndoable(let b, let s):
            return "Batch \(b) is \(s.rawValue) and cannot be undone."
        case .backupsPruned(let b):
            return "Backups for batch \(b) were pruned, so it can no longer be undone."
        }
    }
}
