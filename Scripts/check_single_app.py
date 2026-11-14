#!/usr/bin/env python3
import argparse
import os
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "build/release/Paper Library.app"


def app_copies():
    roots = [ROOT]
    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    if derived_data.is_dir():
        roots.extend(path for path in derived_data.glob("PaperLibrary-*") if path.is_dir())
    copies = set()
    for root in roots:
        for directory, children, _ in os.walk(root, followlinks=False):
            path = Path(directory)
            if path.suffix != ".app":
                children[:] = [name for name in children if name not in {".git", "node_modules", ".venv", "venv"} and not (path / name).is_symlink()]
                continue
            children[:] = []
            try:
                info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
            except (OSError, ValueError):
                continue
            if info.get("CFBundleIdentifier") == "local.paperlibrary.app":
                copies.add(path.resolve())
    return copies


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-missing", action="store_true")
    args = parser.parse_args()
    copies = app_copies()
    unexpected = copies - {CANONICAL.resolve()}
    if unexpected:
        parser.exit(1, "Unexpected Paper Library app copies:\n" + "\n".join(str(path) for path in sorted(unexpected)) + "\n")
    if not copies and not args.allow_missing:
        parser.exit(1, f"The app is missing: {CANONICAL}\n")
    print(f"PASS: {len(copies)} persistent Paper Library app; canonical path: {CANONICAL}")


if __name__ == "__main__":
    main()
