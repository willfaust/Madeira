# Diablo II: Resurrected: executable section regression

Related report: https://github.com/willfaust/Madeira/issues/354

Companion Wine PR: https://github.com/willfaust/wine/pull/49 (pinned by the
`wine` submodule in this branch).

The initial missing-import failure and the later loader failure are separate.
Wine's `sfc.dll`, `sfc_os.dll` and `tbs.dll` satisfy the missing imports; include
them in the ARM64EC DLL farm via `build/wine-pe/build-modules.sh sfc sfc_os tbs`.
They do not resolve the subsequent `NoExec` failure by themselves.

## Evidence from the October 17 device log

The same section handle (`0x4c`) is mapped twice, each time for 1 MiB:

* The executable view is `0x702fe40000`. Its initial all-zero backing is copied
  and remapped into the JIT pool (`[jit-copy] PRE-REMAP`, `[jit-pool] anon RWX`).
* A second view is mapped at `0x702ff40000`.
* Both notifications are skipped because there is no `ArbitraryUserPointer`.
* Execution at the first view plus `0x3ae4` reports an executable-interval miss
  and `NoExec`. Wine reports that address as committed `MEM_MAPPED`, protection
  `0x20` (`PAGE_EXECUTE_READ`), yet the dumped code bytes are zero.
* `D2R_loader.dll` initialization then fails with `c0000005`.

The log establishes the missing executable notification. The second view being
used to emit code is an inference from the dual mapping and zero-byte failure;
the log does not dump writes through that view. Independently, copying just one
view into unrelated backing breaks section sharing and must be avoided.

## Changes

`virtual_ios.c` keeps pagefile-backed sections as host data in the x64 emulator:
Wine retains guest execute permission, while host protection does not include
execute and therefore does not invoke the anonymous JIT-pool copy/remap path.
This also applies when a view is made executable after mapping. Images,
file-backed mappings, WoW64 windows, native EC allocations and system views are
excluded. No executable permission is granted to a guest page that did not
already have it.

The companion Wine change in `signal_arm64ec.c` notifies the emulator of each
committed region in a non-image section, using the queried protection. It runs
before the loader-name gate, serves both map syscalls, skips reserved holes and
uses paired memory-protection callbacks rather than parsing the view as a PE.
Existing unmap notifications remove the section's executable intervals.

Both changes are necessary: notifying FEX alone would allow it to decode the
disconnected zero-filled copy; preserving sharing alone leaves `NoExec`.

## Validation and device test

Run `python3 tests/host/check-guest-section.py` with the companion Wine revision.
It compiles the actual policy and notification helpers with address/undefined
behavior sanitizers and tests exclusions, host-page rounding, committed versus
reserved ranges, callback pairing, and the unchanged image callback path.

Build the standalone regression using the pinned LLVM-MinGW compiler:

```sh
toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang \
  -O2 -Wall -Wextra -Werror tests/x64/shared-section-x64.c \
  -o tests/x64/shared-section-x64.exe
```

Launch `shared-section-x64.exe` in Madeira. It maps an executable view first,
writes a tiny x64 function through a writable sibling, verifies shared bytes,
executes it, rewrites it with an instruction-cache flush, changes protections,
then unmaps and remaps the executable view. The expected final line is
`shared-section: PASS`. A baseline build should fail byte coherence or execution.
No game files or additional runtime DLLs are needed for this regression.

Then launch D2R with fresh logs. Look for `[guest-section]`, absence of an anon
pool copy for that section, and progress beyond the previous loader failure.
Addresses vary per run. Retain any new error: this change targets a startup
blocker, not a demonstrated complete-game compatibility fix. On-device execution
and D2R gameplay remain unverified until this test is run on an iPhone.

Rebuild both native `libntdll_unix.a` and ARM64EC `ntdll.dll` when integrating;
changing only the Windows DLL cannot repair native section backing. A complete
IPA also needs the other build inputs listed in `docs/BUILDING.md`.

Host validation for this draft: the sanitizer harness and existing x64 image
policy check passed; `virtual_ios.c` compiled for arm64 iPhoneOS with Xcode's
iPhoneOS 26.5 SDK; the ARM64EC ntdll and three dependency DLLs built with the
pinned LLVM-MinGW 20260421 toolchain. The Windows build was configured with
`--without-freetype` because only these DLLs were needed, and used a local Bison
3.8.2. The checked-in DLLs were stripped/installed using the repository scripts.
The native build emits an existing enum-switch warning at
`MemoryWineIosJitPoolAddress`. No complete IPA or device run was performed.
