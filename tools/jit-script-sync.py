#!/usr/bin/env python3
"""Keep the embedded StikDebug JIT script in sync with madeira-jit.js.

StikJITHelper.swift ships the JIT protocol script as a base64 string literal.
It prefers a bundled `madeira-jit.js` at runtime, but that file is not part of
the Xcode target, so in practice the literal is what StikDebug runs. Editing
madeira-jit.js and rebuilding therefore changes NOTHING unless the literal is
regenerated -- a silent way for a JIT fix to never ship.

Run from the repo root:

    tools/jit-script-sync.py            # check, exit 1 if out of sync (CI-safe)
    tools/jit-script-sync.py --write    # regenerate the literal from the file
"""

import argparse
import base64
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
JS_PATH = REPO_ROOT / "app" / "Madeira" / "madeira-jit.js"
SWIFT_PATH = REPO_ROOT / "app" / "Madeira" / "StikJITHelper.swift"
LITERAL_RE = re.compile(r'^(?P<indent>\s*)private static let scriptBase64 = "(?P<b64>[A-Za-z0-9+/=]*)"$', re.M)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true",
                    help="regenerate the Swift literal from madeira-jit.js")
    args = ap.parse_args()

    if not JS_PATH.is_file():
        print(f"jit-script-sync: missing {JS_PATH}", file=sys.stderr)
        return 1
    if not SWIFT_PATH.is_file():
        print(f"jit-script-sync: missing {SWIFT_PATH}", file=sys.stderr)
        return 1

    js_bytes = JS_PATH.read_bytes()
    want = base64.b64encode(js_bytes).decode("ascii")
    swift = SWIFT_PATH.read_text(encoding="utf-8")
    m = LITERAL_RE.search(swift)
    if not m:
        print("jit-script-sync: could not find the scriptBase64 literal in "
              f"{SWIFT_PATH.relative_to(REPO_ROOT)}", file=sys.stderr)
        return 1

    have = m.group("b64")
    if have == want:
        print(f"jit-script-sync: OK -- embedded script matches "
              f"{JS_PATH.relative_to(REPO_ROOT)} ({len(js_bytes)} bytes)")
        return 0

    if not args.write:
        print("jit-script-sync: FAIL -- embedded script is STALE relative to "
              f"{JS_PATH.relative_to(REPO_ROOT)}.", file=sys.stderr)
        print("  The app would run the embedded copy, not the file you edited.",
              file=sys.stderr)
        print("  Fix with: tools/jit-script-sync.py --write", file=sys.stderr)
        return 1

    SWIFT_PATH.write_text(swift[:m.start()]
                          + f'{m.group("indent")}private static let scriptBase64 = "{want}"'
                          + swift[m.end():], encoding="utf-8")
    print(f"jit-script-sync: wrote embedded script ({len(js_bytes)} bytes) into "
          f"{SWIFT_PATH.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
