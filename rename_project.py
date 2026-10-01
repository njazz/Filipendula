#!/usr/bin/env python3
"""Rename a project: replaces the old name inside text files AND in file/folder names.

  python3 rename_project.py NewName [folder] [--old MergeDrop] [-n] [-y]

  -n / --dry-run   show what would change, touch nothing
  -y               don't ask for confirmation

Case variants are handled:  MergeDrop -> NewName,  mergedrop -> newname,  MERGEDROP -> NEWNAME
(so MergeDropApp -> NewNameApp, the CLI 'mergedrop' -> 'newname', dev.mergedrop.app -> dev.newname.app).
Skips .git, .build, build, binary files and this script itself.
"""
import argparse, os, re, sys
from pathlib import Path

SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules", "__pycache__"}
SKIP_SUFFIX = (".xcodeproj", ".xcworkspace")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("new")
    ap.add_argument("folder", nargs="?", default=".")
    ap.add_argument("--old", default="MergeDrop")
    ap.add_argument("-n", "--dry-run", action="store_true")
    ap.add_argument("-y", "--yes", action="store_true")
    a = ap.parse_args()

    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", a.new):
        sys.exit("New name must be letters/digits only and start with a letter (it becomes a Swift module name).")
    if a.new == a.old:
        sys.exit("New name equals the old name.")

    root, me = Path(a.folder).resolve(), Path(__file__).resolve()
    pairs = [(a.old, a.new), (a.old.lower(), a.new.lower()), (a.old.upper(), a.new.upper())]
    swap = lambda s: [s := s.replace(x, y) for x, y in pairs][-1]
    has = lambda s: any(x in s for x, _ in pairs)

    edits, renames = [], []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.endswith(SKIP_SUFFIX)]
        for name in dirs + files:
            p = Path(dirpath, name)
            if has(name):
                renames.append(p)
        for f in files:
            p = Path(dirpath, f)
            if p == me:
                continue
            try:
                raw = p.read_bytes()
                if b"\0" in raw:
                    continue
                text = raw.decode("utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if has(text):
                edits.append((p, text))

    if not edits and not renames and not has(root.name):
        sys.exit(f"Nothing named '{a.old}' found in {root}")

    print(f"{len(edits)} file(s) with text changes, {len(renames)} file/folder name(s) to rename")
    for p, _ in edits:
        print("  edit   ", p.relative_to(root))
    for p in sorted(renames, key=lambda p: -len(p.parts)):
        print("  rename ", p.relative_to(root), "->", swap(p.name))
    if has(root.name):
        print("  rename  (this folder)", root.name, "->", swap(root.name))

    if a.dry_run:
        return
    if not a.yes and input("Apply? [y/N] ").strip().lower() not in ("y", "yes"):
        sys.exit("Aborted.")

    for p, text in edits:                                    # contents first (paths still valid)
        with open(p, "w", encoding="utf-8", newline="") as fh:
            fh.write(swap(text))
    for p in sorted(renames, key=lambda p: -len(p.parts)):  # deepest first, so parents stay valid
        p.rename(p.with_name(swap(p.name)))
    if has(root.name):
        root.rename(root.with_name(swap(root.name)))
        print(f"Done. The folder is now: {root.with_name(swap(root.name))}")
    else:
        print("Done.")


if __name__ == "__main__":
    main()
