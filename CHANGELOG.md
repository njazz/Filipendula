# Changelog

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
