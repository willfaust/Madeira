#!/usr/bin/env python3
"""Check that everything the Xcode link step needs is actually on disk.

Most of Madeira.app is NOT in this repository. The emulator core (FEX), the
Windows server layer (wineserver / ntdll / win32u) and the D3D11->Metal layer
(DXMT) are gitignored build products, produced by the scripts in build/ and by
FEX's own cmake build, from three submodules. A clean clone therefore cannot be
linked at all, and the failure it produces is a wall of "library not found"
from ld rather than anything that names the real problem.

This says the real problem up front, before any build starts, and names the
script that produces each missing piece.

The required list is parsed out of project.pbxproj rather than hardcoded, so it
cannot drift from the project. System libraries resolved against SDKROOT
(libc++.tbd, libz.tbd, libsqlite3.tbd) are excluded: they come from the SDK, and
being absent from the working tree is correct for them.

Usage: tools/check-build-inputs.sh [--quiet]
Exit 0 when the tree can be linked, 1 when it cannot.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "app", "Madeira.xcodeproj", "project.pbxproj")

# Every archive is referenced from the Madeira group, so its `path` resolves
# against app/Madeira/. That includes the FEX ones, which climb out with ../..
GROUP_DIR = os.path.join(ROOT, "app", "Madeira")

# What produces each archive, for the report. Keyed by basename.
PRODUCED_BY = {
    "libFEXCore.a":        "FEX/build-ios (cmake, see FEX submodule build-ios)",
    "libFEXCore_Base.a":   "FEX/build-ios (cmake)",
    "libfmt.a":            "FEX/build-ios/External/fmt (cmake)",
    "libcephes_128bit.a":  "FEX/build-ios/External/cephes (cmake)",
    "libxxhash.a":         "FEX/build-ios/External/xxhash (cmake)",
    "libsoftfloat_3e.a":   "FEX/build-ios/External/SoftFloat-3e (cmake)",
    "libJemallocLibs.a":   "FEX/build-ios (cmake)",
    "libwineserver.a":     "build/wineserver/build.sh",
    "libntdll_unix.a":     "build/ntdll-unix/build.sh",
    "libwin32u_unix.a":    "build/win32u-unix/build.sh",
    "libdxmt_combined.a":  "build/dxmt-ios/build.sh (needs llvm-mingw + LLVM 15)",
}


def linked_archives(pbxproj_text):
    """Basenames of archives the Frameworks phase links, minus SDK system libs.

    Two hops, because that is how the format works: the phase lists PBXBuildFile
    ids, and each of those names the PBXFileReference that carries the path.
    Reading the phase directly finds bare ids with no `fileRef =` and silently
    yields nothing, which is how the first version of this reported a cheerful
    "0 of 0" on a tree that cannot link.
    """
    phase = re.search(r"PBXFrameworksBuildPhase.*?files = \((.*?)\);",
                      pbxproj_text, re.S)
    if not phase:
        sys.exit("check-build-inputs: FAIL -- no PBXFrameworksBuildPhase found")

    # fileRef -> (name, path, sourceTree), for every file reference.
    refs = {}
    for m in re.finditer(
            r"([0-9A-F]{8}) /\* (.*?) \*/ = \{isa = PBXFileReference;(.*?)\};",
            pbxproj_text, re.S):
        ident, comment, body = m.groups()
        path = re.search(r'path = "?([^";]+)"?;', body)
        refs[ident] = (comment, path.group(1) if path else comment)

    # PBXBuildFile id -> file reference id.
    build_files = {}
    for m in re.finditer(
            r"([0-9A-F]{8}) /\* .*? \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{8})",
            pbxproj_text):
        build_files[m.group(1)] = m.group(2)

    out = []
    for m in re.finditer(r"([0-9A-F]{8}) /\* .*? \*/,", phase.group(1)):
        ref = refs.get(build_files.get(m.group(1), ""))
        if not ref:
            continue
        comment, path = ref
        base = os.path.basename(path)
        if not base.endswith(".a"):
            continue                      # .tbd/.framework come from the SDK
        out.append((base, path))

    if not out:
        # Never report success on an unparsed project: "found nothing" and
        # "nothing is missing" must not look the same.
        sys.exit("check-build-inputs: FAIL -- parsed 0 archives from the project; "
                 "the parser is wrong, not the tree")
    return out


def main():
    quiet = "--quiet" in sys.argv
    listing = "--list" in sys.argv
    with open(PBXPROJ, encoding="utf-8") as fh:
        archives = linked_archives(fh.read())

    missing, present = [], []
    for base, path in sorted(set(archives)):
        target = os.path.normpath(os.path.join(GROUP_DIR, path))
        (present if os.path.exists(target) else missing).append((base, target))

    # --list prints the required paths relative to the repo root, one per line.
    # scripts/publish-build-libs.sh tars exactly this set and the IPA workflow
    # restores it, so the list has one definition instead of three. Relative,
    # because tar and the restore step both run from the repo root.
    if listing:
        for _base, path in sorted(set(archives)):
            print(os.path.relpath(os.path.normpath(os.path.join(GROUP_DIR, path)), ROOT))
        return 0

    submodules = []
    for name in ("FEX", "wine", "research/dxmt"):
        d = os.path.join(ROOT, name)
        n = len(os.listdir(d)) if os.path.isdir(d) else 0
        if n == 0:
            submodules.append(name)

    if not quiet:
        print(f"  {len(present)} of {len(present) + len(missing)} linked archives "
              f"present")
        for base, _ in present:
            print(f"    ok    {base}")

    if missing:
        print("")
        print(f"check-build-inputs: CANNOT LINK -- {len(missing)} archives missing")
        print("")
        for base, target in missing:
            rel = os.path.relpath(target, ROOT)
            print(f"  missing  {rel}")
            print(f"           produced by: {PRODUCED_BY.get(base, 'unknown')}")
        if submodules:
            print("")
            print("  submodules not checked out (their sources are absent):")
            for name in submodules:
                print(f"    {name}/  -> git submodule update --init --recursive")
        print("")
        print("  These are gitignored build products, not committed files: the")
        print("  emulator core, the Windows server layer and the D3D->Metal layer")
        print("  all have to be built before Madeira.app can be linked. A clean")
        print("  clone cannot build this app; see build/dxmt-ios/README.md for the")
        print("  DXMT toolchain, and note that build/wineserver/build.sh patches a")
        print("  prebuilt app/Madeira/libwineserver.a rather than producing one.")
        print("")
        print("  To make CI work, publish them once from a Mac that already builds")
        print("  the app:")
        print("      scripts/publish-build-libs.sh")
        print("  .github/workflows/ipa.yml restores that asset on an ordinary")
        print("  macOS runner.")
        return 1

    if not quiet:
        print("check-build-inputs: OK -- all linked archives are present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
