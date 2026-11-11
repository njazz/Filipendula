# Changelog

## 0.1.7

### Added
- **Add in place instead of replacing.** When a dropped file has the same name as a project file but sits in another folder of the source tree (project `Foo/Bar.hpp`, source `Foo/Baz/Bar.hpp`), the diff pane offers a *Place* choice: replace `Foo/Bar.hpp`, or add the source as a new file at `Foo/Baz/Bar.hpp`. The add option is offered when that folder already exists in the project, hangs off an existing folder, or the dropped folder demonstrably mirrors the project. Replacing stays the default. Choosing *Add* ticks the file; undo removes it. `plan` mentions the option, and the tree shows a branch icon.

## 0.1.6

### Added
- **Suggested locations for new files.** A dropped file that isn't in the project now gets ranked suggestions for where it could go: the same place as in the dropped folder, the folder its neighbours from the same source folder were matched into, a project folder named like the source folder, a new sub-folder of an existing folder, or the root. The diff pane shows them in a picker with the reason for each (and a path field for anything else); `filipendula plan` lists them too.
- **Per-file "Add this file".** New files can always be ticked one at a time (tree checkbox or the switch in the diff pane). Committing creates only the ticked ones; undo removes them again. The Setup option is now *Check new files by default* and only decides whether they start ticked.
- **Same-named files are compared properly.** Every project file with the same name is scored by shared lines (75 %) and by how well its folder matches the source's folder (25 %). The picker lists each copy with its score, and a close call is called out.
- **Wrong matches are caught.** If a dropped folder's structure points at a file that shares almost nothing with the update while another same-named file matches well, the better one is suggested (asking for confirmation). A target with very few shared lines is flagged in the app and in `plan`, starts unchecked, and is skipped by `apply` unless `--accept-ambiguous`.
- Targets you picked by hand are remembered when you drop more files.
- A confirmation before committing new files (unless they are checked by default).
- Test coverage for matching, new-file placement, the selection rules (now `SelectionPolicy` in MergeCore), scanner, hashing, path rules, classifier edge cases, planner edge cases, journal and operations.

### Changed
- A new file in a dropped folder is no longer created under the folder's own name (`drop/lib/x.swift`); it follows the structure the folder shares with the project.
- The target picker stays available after you choose a target.

## 0.1.5

### Added
- **Setup window** (button in the toolbar, ⌘,) holds every option: heavy-loss threshold, whitespace handling, adding new files, moving sources to the Trash, confirmation for yellow files, diff context lines, show identical files, and backup maintenance (prune, reveal, .gitignore).
- **Multi-selection in the tree** (click, shift-click, ⌘-click). Toggling a checkbox, or the right-click menu, applies to every selected row. Folder rows have a tri-state checkbox.
- **Select all / Deselect all / Clear** buttons above the tree, with a one-line summary of what was dropped.
- **Move dropped files to the Trash after a commit** (option, off by default, always asks). Only merged files that are unchanged since the commit are moved; the journal notes each one. CLI: `apply --trash-sources`.
- **Activity log**: drops, "no diff" results, skipped files, commits and Trash moves appear in the log next to the batches.
- Version in the window title; `filipendula --version`.
- Resizable panes (tree 30 % wide and log 15 % high by default, remembered).

### Changed
- **Files that don't exist in the project are never added** unless "Allow adding new files" is on (CLI: `--add-new`). They are listed as "not in project, not added" everywhere, and the commit refuses to create them even if the original disappeared after planning.
- Green files are re-checked after every refresh.
- Identical files are reported explicitly ("No diff: …") in the tree, the diff pane, the log and the CLI.
- Backup maintenance moved from the log pane into Setup.

### Fixed
- The diff pane keeps its scroll position when showing new content; it now always starts at the top.

## 0.1.0
- First version: classifier, journal with verified backups and undo, SwiftUI app, CLI.
