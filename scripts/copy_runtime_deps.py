#!/usr/bin/env python3
"""Copy platform runtime shared libraries next to the built sample executables.

On Windows the SDL3 binding links against an import library, so the matching
SDL3.dll must sit beside each executable at run time. This mirrors the DLL
vendored in sdl3.c3l/linked-libs/windows-x64/ into the build output dir.

No-op on Linux/macOS, where SDL3 is linked statically. Run after `c3c build`
and before running any windowed sample.
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# project.json's "output" dir; c3c drops each executable here.
OUTPUT_DIR = ROOT / "build"
# Runtime shared libraries to mirror into OUTPUT_DIR on Windows.
WINDOWS_RUNTIME_DEPS = [
    ROOT / "lib" / "sdl3.c3l" / "linked-libs" / "windows-x64" / "SDL3.dll",
]


def up_to_date(src: Path, dst: Path) -> bool:
    return (dst.exists()
            and dst.stat().st_size == src.stat().st_size
            and dst.stat().st_mtime >= src.stat().st_mtime)


def main():
    if sys.platform != "win32":
        print("copy_runtime_deps: nothing to do on this platform (static linking)")
        return

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for src in WINDOWS_RUNTIME_DEPS:
        if not src.exists():
            sys.exit(
                f"copy_runtime_deps: missing {src}\n"
                f"  Vendor the DLL there (it pairs with the committed import lib),\n"
                f"  e.g. from vcpkg: vcpkg install sdl3:x64-windows, then copy\n"
                f"  installed/x64-windows/bin/SDL3.dll into that directory."
            )
        dst = OUTPUT_DIR / src.name
        if up_to_date(src, dst):
            print(f"copy_runtime_deps: {dst.name} up to date")
            continue
        shutil.copy2(src, dst)
        print(f"copied {src.name} -> {dst}")


if __name__ == "__main__":
    main()
