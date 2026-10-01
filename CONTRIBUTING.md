# Contributing

Bug reports and pull requests are welcome.

## Setup

macOS 13+, Xcode 15+ (Swift 5.9).

```bash
swift test              # core logic: classifier, apply/undo, integrity, prune
./run.sh                # build and launch a debug .app
```

## Layout

- `Sources/MergeCore` holds all logic and has no UI dependency. New behavior goes here first, with tests.
- `Sources/filipendula` is the CLI, `Sources/FilipendulaApp` the SwiftUI app. Both only call into `MergeCore`.

## Rules of thumb

- Anything that writes to a user's project must go through `Operations` (backup, verify, journal, undo).
- Never relabel "something was removed" as green. The colors are a safety promise.
- Bumping the version: edit `Sources/MergeCore/Version.swift` and `MARKETING_VERSION` in `project.yml`, add a `CHANGELOG.md` entry. CI fails if the two versions differ.
