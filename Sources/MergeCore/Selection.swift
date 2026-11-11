import Foundation

/// The rules for which planned changes may be ticked and committed. They live here, not in the UI, so they are tested.
///
/// A file that doesn't exist in the project is never created by accident: it can always be ticked one by one (that is
/// the explicit "add it" decision), but it starts unchecked and "select all" skips it, unless the user chose to check
/// new files by default.
public struct SelectionPolicy: Sendable, Equatable {
    public var checkNewFilesByDefault: Bool

    public init(checkNewFilesByDefault: Bool = false) {
        self.checkNewFilesByDefault = checkNewFilesByDefault
    }

    /// Can this change be committed at all?
    public func isCommittable(_ c: PlannedChange) -> Bool {
        c.status != .identical && c.issue == nil
    }

    /// Starts checked: green, blue and yellow, as long as the target is certain and nothing else collides with it.
    /// Reds start unchecked, and so does anything that needs a second look.
    public func defaultChecked(_ c: PlannedChange) -> Bool {
        isCommittable(c) && c.status.selectedByDefault && !c.conflict && !c.needsConfirmation
            && (c.status != .new || checkNewFilesByDefault)
    }

    /// "Select all" button.
    public func includedInSelectAll(_ c: PlannedChange) -> Bool {
        isCommittable(c) && !c.conflict && (c.status != .new || checkNewFilesByDefault)
    }

    /// Marks the new files among the ticked changes as explicitly wanted, so `Operations.apply` may create them.
    /// Nothing else is marked: a change planned against an existing file can never turn into a creation.
    public func prepareForCommit(_ ticked: [PlannedChange]) -> [PlannedChange] {
        ticked.filter(isCommittable).map { c in
            var c = c
            if c.status == .new { c.addNew = true }
            return c
        }
    }
}
