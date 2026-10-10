# 32-bit Windows programs (WoW64) on Madeira

Madeira runs unmodified 32-bit x86 Windows programs the way Windows on ARM
does: Wine's own WoW64 layer (`wow64.dll`, `wow64win.dll`) runs as native
aarch64 code, and only the program's x86 code is translated, by FEX's WOW64
module (`xtajit.dll`). This page describes the design, what changes for a
64-bit session (nothing by default), every switch with its default, how to
build the pieces, and the order the pull requests go in.

## 1. Constraints

- XNU gives every arm64 process a 4 GB hard `__PAGEZERO`: nothing can be
  mapped below host address 4 GB. Classic WoW64 assumes a 32-bit pointer is
  also the host address of what it points at, and that identity is impossible
  here.
- Every Windows "process" is a pseudo-process (threads) inside the one Mach
  task, so two 32-bit processes share one address space and cannot both own
  `[0, 4G)`.
- Everything that executes comes from the one dual-mapped RX/RW JIT pool.
  Nothing inside a guest window is ever mapped executable.
- The user address space is either large (512 GB) or small (63 GB on some
  tablets, less on a virtual device). Both must work, and a small map must not
  lose address space to 32-bit support when no 32-bit program runs.

## 2. The guest window

Each 32-bit pseudo-process owns a **guest window**: one reserved host range
`[B, B + 4 GB)`, 4 GB-aligned. Guest address `a` (below 4 GB, what the x86
code sees) lives at host address `B + a`.

- **FEX, 32-bit mode only**, pins one ARM64 register to `B` and forms every
  host address as `B + zext32(EA)`. Registers, segment bases, EIP, the lookup
  cache and the code-invalidation ranges stay in the guest namespace. The
  ARM64EC module (`xtajit64.dll`) is not built with the window: its code is
  identical to the upstream build (checked by disassembly on every FEX PR).
- **Wine's WoW64 layer** converts pointers through its typed helpers
  (`get_ptr`, `addr_32to64`, the `*_32to64` struct helpers). On this host they
  add or remove `B`; NULL stays NULL; handles, sizes and packed values are
  never offset.
- **One source of truth for `B`**:
  `NtQueryInformationProcess(ProcessWineIosWowGuestBase)` (a Wine-private
  class, 1010) returns a process's `B`, or 0 for a 64-bit process. `wow64.dll`
  and the FEX WOW64 module read it once at process start. A failed query means
  `B = 0`, i.e. upstream Wine behaviour.
- **The unix side** (`build/ntdll-unix/*_ios.c`, win32u, the wineserver)
  speaks host addresses. A ceiling a 32-bit process sends down (`zero_bits`, a
  `MEM_ADDRESS_REQUIREMENTS` limit, `HighestUserAddress`) is a guest number,
  and the unix side turns it into the host range `[B, B + L]` when it places
  memory. `build/ntdll-unix/ios_wow.h` is the interface the other unix files
  use.

### Lazy windows

Nothing is reserved for 32-bit support until a 32-bit program needs it.

- The session is **armed** when the app publishes a 32-bit main image
  (`ios_main_image_i386`, set by `WineProcessBridge.m` from the target's PE
  header) or when a 32-bit process asks for a window (a 32-bit
  `CreateProcess` child). Until then there is no reservation, no
  `TASK_VM_INFO` query, and the top-down placement bias that keeps a window
  slot free does not apply: a 64-bit session places memory exactly as before.
- A 32-bit main image gets one window, reserved at the end of `virtual_init`
  before the system frameworks can take the slot. Every other window is
  reserved on demand, one per 32-bit process.
- **Small maps:** a window is refused (`STATUS_NO_MEMORY`, one
  `[wow-window] refused: map too small` line) when the map is smaller than
  `MADEIRA_WOW_MIN_MAP_GB` or when taking it would leave less than
  `MADEIRA_WOW_MIN_FREE_GB` of free VA outside it. At most
  `MADEIRA_WOW_SMALL_VA_SLOTS` windows are alive at once on a small map.
- Large maps use the band below the 64-bit Chromium pools (slots at
  `0x7100000000` and `0x7200000000`); the `[cage]` holdback is carved only for
  a second concurrent 32-bit process, and a spill slot below the FEX host band
  is used only when the band is full.
- A window is released when its process exits and torn down when the next
  32-bit process needs a slot (release-on-next-adopt): nothing joins a dead
  pseudo-process's threads, so the teardown cannot run on the dying thread.
- `MADEIRA_WOW_PLACEHOLDERS=1` restores ahead-of-time placeholders for every
  slot, for a 64-bit launcher that starts 32-bit children on a crowded map.

Inside a window, TEB/PEB pairs, 32-bit stacks, images (relocated to their
guest base) and `KUSER_SHARED_DATA` at guest `0x7ffe0000` are placed by the
unix side. The page past `B + 4 GB` is an overrun guard.

### .NET Framework programs (Wine Mono)

A 32-bit .NET Framework program (verified: Terraria) runs on Wine Mono, which
the app bundles when it is built with `build/wine-mono` (docs/BUILDING.md)
and links as `C:\windows\mono\mono-2.0` every session. Three settings turn on
by themselves when that runtime loads, and only then:

- mscoree sets `MONO_THREADS_SUSPEND=coop` and adds `keep-delegates` to
  `MONO_DEBUG` before it loads Mono. Mono's default hybrid suspend relies on
  `SuspendThread` stopping the target, which it does not do here (section 5).
- When `libmono-2.0-x86.dll` is mapped into a window, the window's anonymous
  RWX memory becomes plain read/write to the host, Mono's 64 KB code chunks
  included (`virtual_ios.c`, ml1279/ml1282). The host never executes those
  bytes: FEX arms a chunk read-only when it translates from it and disarms it
  on the first write, as on Windows. Before, every store Mono's JIT made into
  a chunk was emulated through the JIT pool's alias (25 M stores in 7 minutes
  of Terraria).
- FEX arms its Mono backpatcher bridge for that DLL and, once it has found
  the backpatcher, turns SMC detection off for the process (ml1280): Mono
  rewrites live code only through the backpatcher, which the bridge handles.

The bundled `mscorlib.dll` is patched at build time (`build/wine-mono/bundle.sh`,
ml1281, a dirty hack, see the TODO there): `GC.Collect(gen,
GCCollectionMode.Optimized, ...)` returns without collecting, as .NET allows.
Mono ran a full blocking collection for every such call, and Terraria makes
one per frame (85-150 ms each, ~8 FPS).

Unity games load their own `mono-2.0-bdwgc.dll`, not through mscoree, and are
not matched. The switches are in section 8.

## 3. Launch path (`app/Madeira/WineProcessBridge.m`)

| Step | 32-bit target | Anything else |
|---|---|---|
| Machine | `IMAGE_FILE_HEADER.Machine` read off disk: a `C:\...` path under the prefix's `drive_c`, or a bare name found in the bundle's `i386-windows` and in neither 64-bit farm | not probed further; the existing name heuristic decides, unchanged |
| Session core | plain `aarch64-windows` (a WoW64 process's 64-bit half is aarch64) | unchanged |
| Farms | `C:\windows\syswow64` -> `i386-windows`, plus `syswow64\wbem` and the x86 side-by-side store in `C:\windows\winsxs` | the same three, whenever the bundle has the i386 set: a 64-bit launcher (or the Dock host) starts 32-bit children, and the store's links name the bundle path, which changes on reinstall |
| Bare name | `C:\windows\syswow64\<name>` | `C:\windows\system32\<name>` |
| Before `__wine_main` | `ios_main_image_i386 = 1`; `FEX_MADEIRA_HOSTPROBE` published | `ios_main_image_i386 = 0`; `FEX_MADEIRA_HOSTPROBE` published only if the bundle has the i386 set |

A bundle without `i386-windows/ntdll.dll` never treats a target as 32-bit, so
it behaves exactly as before. To run the 32-bit build of a name both sets
carry (`explorer.exe`, `cmd.exe`), give its full path,
`C:\windows\syswow64\<name>`.

The x86 side-by-side store holds the assemblies Wine ships as
`WINE_MANIFEST` resources (Common-Controls 6.0, VC80/VC90 CRT and ATL,
GDI+ 1.0/1.1, MSXML 3/4/6), written the way `dlls/setupapi/fakedll.c` would,
because this port never runs wineboot's fake-DLL install. Only `x86_`
assemblies are written, which 64-bit processes never look up.

`FEX_MADEIRA_HOSTPROBE` carries the answers of the `hw.optional.*` sysctls
FEX's modules cannot query themselves (a wrong "present" either corrupts SSE
results silently, e.g. FEAT_AFP, or is an illegal instruction, e.g. FlagM2 on
A13). The app publishes it for every session, and both the WOW64 and the
ARM64EC module read it; the ARM64EC module also takes LRCPC2 and AFP from it.

## 4. Unix calls from 32-bit DLLs

Every statically linked unix library has its 64-bit table and, where 32-bit
callers exist, a `*_unix_call_wow64_funcs` table that reads 32-bit argument
blocks and converts the guest pointers inside them. `load_builtin_unixlib()`
(`virtual_ios.c`) binds by the module's export name (PE32 or PE32+) and by the
caller's bitness; a library without a 32-bit table refuses a 32-bit caller
instead of handing it the 64-bit table. 64-bit callers get the same tables
from the same branches as before. Tables provided: winemetal (DXMT's Metal
renderer; the 32-bit table lives in DXMT's `winemetal_unix.c`), ws2_32,
bcrypt, secur32, crypt32, dwrite, nsi (TCP connections, network interfaces,
addresses and routes, and the row/field reads) and the audio driver (on the
existing engine). win32u goes through `wow64win.dll`.

### Direct3D 9

The i386 `d3d9.dll` in the farm is DXMT's thin shim (`dxmt/src/d3d9shim`,
exported as `d3d9shim.dll` whatever file name it is installed under):

- By default its `DllMain` forwards every export to `d3d9-emulated.dll`, DXMT's
  D3D9 frontend built for i386 and translated by FEX like the program itself.
  That frontend reaches Metal through winemetal's 32-bit table.
- With `d3d9 = native` in `madeira.cfg` (the app exports it as `MADEIRA_D3D9`),
  the shim binds its own unix side instead and the frontend runs as native
  ARM64 code in `libdxmt_combined.a` (`build/dxmt-ios/build.sh`, the
  `dxmt_madeira_native` objects). `load_builtin_unixlib()` binds
  `dxmt_d3d9_unix_call_wow64_funcs` to a 32-bit module whose export name is
  `d3d9shim`, never to the emulated frontend.
- Native D3D9 objects hold host pointers into the guest window, so the window
  reclaim calls `d3d9_native_window_teardown(B)` before a dead process's
  window is replaced with `PROT_NONE`. The hook is weak in `virtual_ios.c`;
  DXMT's definition replaces the default, which only reports that it is
  missing.

`build/wine-i386/build.sh` installs the shim as `d3d9.dll` and `d3d9shim.dll`
and the emulated frontend as `d3d9-emulated.dll`.

The ARM64EC `d3d9.dll` that x64 programs load is DXMT's frontend too, built for
ARM64EC from the same source (`ninja -C build-pe-arm64ec src/d3d9/d3d9.dll` in the
DXMT tree, stripped). It replaces Wine's, which goes through wined3d's OpenGL
backend and so always returned NULL from `Direct3DCreate9` here.
`MADEIRA_D3D9_X64=0` makes `Direct3DCreate9` / `Direct3DCreate9Ex` fail the same
way again. Not exported, unlike Wine's: `Direct3DCreate9On12`, `PSGPError`,
`PSGPSampleTexture` (the i386 frontend lacks them as well).
`tests/x86/build-d3d9-cube.sh` builds the acceptance test, a spinning
cube through a real device with a dynamic vertex buffer the guest locks every
frame.

## 5. Thread contexts

On iOS `SuspendThread` does not stop the target, so for **32-bit processes
only** the wineserver applies a `SetThreadContext` at resume time, while the
thread is held in the same system call it was captured in, and refuses one
on a running thread. The 32-bit registers live in the thread's WoW64 CPU area
(`TEB64->TlsSlots[WOW64_TLS_CPURESERVED]`), as in Wine. The FEX WOW64 module
stores its state into that area whenever a system call or unix call leaves
emitted code, and reloads it when it finds `WOW64_CPURESERVED_FLAG_RESET_STATE`
on the way back, as wow64cpu does. 64-bit processes keep the existing
behaviour.

## 6. Invariants

1. Any pointer guest code can observe is a guest address (below 4 GB).
2. Any pointer the native side dereferences is a host address. Guest to host
   is `+B` of the **owning** process, for cross-process operations too.
3. NULL converts to NULL in both directions.
4. Handles, sizes, flags and packed values are never offset.
5. Exception records crossing the boundary convert `ExceptionAddress` and the
   address in `ExceptionInformation[1]` of an access violation (`wow64.dll`
   does this once; the FEX WOW64 module keeps its own records host-side).
6. Code invalidation and self-modifying-code tracking use the guest namespace
   at the FEXCore / InvalidationTracker boundary.
7. Nothing inside a window is mapped executable.
8. Every new branch is keyed on `ios_wow_base() != 0`, the session being
   armed, an i386 image or process, or the WOW64 build of FEX.

## 7. 64-bit sessions: unchanged

The series does not change the 64-bit engine's defaults. In particular:

- madsync stays on (`inproc-sync` defaulted to 1 in `build/madsync/madsync.c`);
  the series adds no other in-process sync engine. (Fastsync, added later, has
  been the default engine since 2026-09-30; `inproc-sync = 1` still selects
  madsync.)
- The FEX code-buffer cap and ladder (128 MB, ml1052), the owner-aware
  code-buffer guard (ml1035), the bounded sweep retry (ml1106) and the
  ARM64EC alias cache (ml1116) are untouched; the ARM64EC FEX DLL builds to
  the same bytes.
- The audio engine (ml1026 mixer, ml1068 float format), the JIT pool policy,
  the SMC handling and `signal_set_full_context` are untouched.
- No address space is reserved and no placement changes until a 32-bit
  program runs (section 2).

## 8. Switches

Environment names. Set them as `env.NAME = value` in `Documents/madeira.cfg`;
the app exports them before Wine starts. "32-bit" in the scope column means
the switch is only consulted for a WoW64 process, window or thread.

| Switch | Default | Scope | Effect |
|---|---|---|---|
| `MADEIRA_WOW_PLACEHOLDERS` | 0 | session | 1: reserve every window slot at session start (the old behaviour) |
| `MADEIRA_WOW_SMALL_VA_SLOTS` | 2 | 32-bit | Most windows alive at once on a small map |
| `MADEIRA_WOW_MIN_MAP_GB` | 48 | 32-bit | Refuse a window on a map smaller than this |
| `MADEIRA_WOW_MIN_FREE_GB` | 8 | 32-bit | Refuse a window that would leave less free VA than this outside it |
| `MADEIRA_WOW_EXTRA_WINDOW` | on | 32-bit | Allow a window carved from the `[cage]` holdback tail for a second process |
| `MADEIRA_WOW_SPILL_CEF` | on | 32-bit | Allow a spill window below the FEX host band when the band is full |
| `MADEIRA_WOW_LIVE_WINDOW_GUARD` | on | 32-bit | Keep an exited process's window while its worker threads still exist |
| `MADEIRA_WOW_STRICT_LIMITS` | on | 32-bit | Treat an allocation as a guest request only when both bounds are in the caller's window |
| `MADEIRA_LAA` | on | 32-bit | A 32-bit main image that is not large-address-aware still gets a 4 GB guest ceiling (0: 2 GB) |
| `MADEIRA_LAA_LOWFIRST` | on | 32-bit | With a raised ceiling, place below 2 GB first and spill above only when the low half cannot serve |
| `MADEIRA_LAA_HIGH_IMAGES` | on | 32-bit | With a raised ceiling, Wine's builtin i386 images may load above 2 GB (0: keep them low) |
| `MADEIRA_GUEST_IMAGE_WRITE` | on | 32-bit | Pages of an i386 image view inside a window are writable data to the host (the JIT never executes them in place) |
| `MADEIRA_WOW64_BY_TEB` | on | 32-bit | `is_wow64()` per thread, from the TEB; identical to the old answer for 64-bit threads |
| `MADEIRA_SECTION_PROCESS_LIMIT` | on | 32-bit | A section mapping uses only the calling process's own WoW64 ceiling |
| `MADEIRA_WINPROC_HANDLE` | on | 32-bit | Recognise a 32-bit window-procedure handle that arrives with its guest base added |
| `MADEIRA_GDI_SHARED_SECTION` | armed session | session | GDI handle table in a named section with 32-bit views (1/0 force it) |
| `MADEIRA_CTX_SET` | on | 32-bit | Apply `SetThreadContext` at resume (section 5) |
| `MADEIRA_CTX_REFRESH` | on | 32-bit | Re-capture a snapshot context when the thread is stopped again (never one with a pending Set) |
| `MADEIRA_CTX_START_WAIT` | on | 32-bit | A thread created suspended reports its start context, not a snapshot of a half-initialised thread |
| `MADEIRA_WOW_INIT_CTX_RETRY` | on | 32-bit | `wow64.dll` retries the initial 32-bit context query while the new thread's CPU area is not published yet |
| `MADEIRA_UNWIND_GUARD` | on | 32-bit | An unwind that repeats the same Pc/Sp three times on a thread of a WoW64 process ends as unhandled instead of spinning |
| `MADEIRA_IO_STATUS_OWNER` | on | mixed session | Write an I/O status block in the layout of the process that owns it (identical answer in a 64-bit-only session) |
| `MADEIRA_AFD_EVENT_HANDLE` | on | 32-bit | Convert an AFD event handle a 32-bit caller passed with its guest base added |
| `MADEIRA_HEAP_COMPACT`, `_COMBINED`, `_RECLAIM`, `_STATS` | off | 32-bit | Opt-in 32-bit heap policies |
| `MADEIRA_CPU_COUNT` | unset | per launch | Overrides the `cpu-count` key for one program (unset: unchanged) |
| `MADEIRA_STRICT_SPLITLOCK` | on | FEX WOW64 | `StrictInProcessSplitLocks` default for 32-bit guests (an explicit FEX setting wins) |
| `MADEIRA_WOW_SYSCALL_SWEEP` | on | FEX WOW64 | Let the code-buffer sweeper move threads parked in a system call |
| `MADEIRA_D3D9` | unset (emulated) | i386 `d3d9.dll` | `native`: the D3D9 shim uses the native ARM64 frontend. Also set by the `d3d9` key of `madeira.cfg` |
| `MADEIRA_D3D9_X64` | on | x64 `d3d9.dll` | `0`: Direct3D 9 creation fails for x64 programs, as it did with Wine's wined3d frontend |
| `MADEIRA_WOW_RWX_PLAIN` | unset (automatic) | 32-bit | Anonymous RWX memory in a window is plain read/write to the host once Wine Mono's `libmono-2.0-x86.dll` is mapped there; 1: in every window, 0: never (stores go through the JIT pool's alias, as before; also keeps FEX's Mono bridge off) |
| `MADEIRA_WINEMONO_BRIDGE` | automatic for `libmono-2.0-x86.dll` | FEX WOW64 | FEX's Mono backpatcher bridge (ml712) and, once it finds the backpatcher, SMC detection off for the process (ml1280); 0 keeps both off. The 64-bit runtime still needs 1 |
| `MADEIRA_MONO_DEFAULTS` | on | Wine Mono | mscoree sets `MONO_THREADS_SUSPEND=coop` and adds `keep-delegates` to `MONO_DEBUG` before Mono loads; values already set win; 0 sets nothing |

`inproc-sync` (madsync) is a `madeira.cfg` key, not part of this series, and
keeps its default of 1.

## 9. Building

The i386 and aarch64 WoW64 binaries are built from the pinned submodules;
none are committed with the code.

1. **i386 farm:** `build/wine-i386/build.sh` configures `wine/build-i386`
   (`--enable-archs=i386`), builds every i386 module the tree has a rule for
   minus a documented skip list, strips and installs into
   `app/Madeira/i386-windows/`, builds DXMT's i386 `d3d11`/`dxgi`/`d3d10core`/
   `winemetal` against that tree with meson, and reports the farm's import
   closure. `build/wine-i386/build.sh kernel32 user32` rebuilds only those
   modules; `SKIP_DXMT=1` leaves DXMT out. The unix side needs
   `libdxmt_combined.a` rebuilt from the pinned DXMT (`build/dxmt-ios/build.sh`),
   which carries winemetal's 32-bit table.
   It is the macOS form of the WSL script the 32-bit work was built with; it
   was first run on macOS on 2026-09-29 (717 Wine modules plus DXMT, no
   missing imports). Wine's configure needs bison 3.0 or newer; macOS ships
   2.3, so put Homebrew's first on PATH (`/opt/homebrew/opt/bison/bin`).
2. **aarch64 side:** `app/Madeira/aarch64-windows/` needs `wow64.dll` and
   `wow64win.dll`, and `ntdll.dll` rebuilt, from the pinned Wine's aarch64 PE
   build (`make -C dlls/wow64 dlls/wow64win dlls/ntdll` in a tree configured
   with `--enable-archs=aarch64`).
3. **FEX WOW64 module:** `build/fex-wow64/build.sh` configures `FEX/build-wow64`
   for `aarch64-w64-mingw32` with the iOS host options, builds target
   `wow64fex` and installs `Bin/libwow64fex.dll` as
   `app/Madeira/aarch64-windows/xtajit.dll`.
4. **Smoke test:** `tests/x86/build.sh hello-x86` builds a kernel32-only
   i386 PE into `app/Madeira/i386-windows/`. Put `env.MADEIRA_EXE = hello-x86.exe`
   in `madeira.cfg` and launch: the log shows
   `PE probe: machine=0x14c (i386: WoW64)`, the program's
   `MADEIRA-X86-32: hello from a 32-bit PE`, and exit code 42.

`app/Madeira/i386-windows/` is a folder reference in the Xcode project; it is
tracked empty (`.gitkeep`) so the project builds before step 1 has run.

## 10. Merge order

Each repository's PRs merge in order, with merge commits, before the
Madeira PRs that pin them:

1. willfaust/rpmalloc#1.
2. willfaust/wine#6, #7, #8, #9, #10, #11, #12.
3. willfaust/FEX#2, #3, #4 (FEX#3 pins rpmalloc#1).
4. willfaust/Madeira#40, then #41 (pins the Wine series), then #42, #43 and
   #44, then the launch PR (pins FEX#4), then the winemetal PR (pins DXMT),
   then the D3D9 PR (pins willfaust/dxmt#2, which merges after dxmt#1).

A pin that points at a 125hz merge branch moves to the corresponding upstream
merge commit once the submodule PRs are merged.
