# 32-bit Windows programs (WoW64) on Madeira

This document describes how Madeira runs unmodified 32-bit x86 Windows
programs: Wine's own WoW64 layer runs as native ARM64 code, and only the
program's x86 code is translated by FEX's WOW64 module (`xtajit.dll`). It is the
condensed, upstream-facing version of the fork's working log. Code comments
cite that log as `WOW64_DESIGN.md §N`; it lives in the 125hz fork
(`WOW64_DESIGN.md` on `wip/ml2000`) and is not needed to read this page.

## 1. Constraints

- XNU gives every arm64 process a 4 GB hard `__PAGEZERO`: nothing can be
  mapped below host address 4 GB. Classic WoW64 assumes a 32-bit pointer is
  also the host address of what it points at, and that identity is impossible
  here.
- Every Windows "process" is a pseudo-process (threads) inside the one Mach
  task, so two 32-bit processes share one address space and cannot both own
  `[0, 4G)`.
- Everything that executes comes from the one dual-mapped RX/RW JIT pool
  granted by the debugger at startup. Nothing inside a guest window is ever
  mapped executable.
- The device's user address space is either 512 GB (phones with the
  extended-virtual-addressing entitlement or a large default map) or 63 GB
  (`TASK_VM_INFO.max_address = 0xfc0000000`, seen on an A16 tablet). Both must
  work.

## 2. The guest window

Each 32-bit pseudo-process owns a **guest window**: one reserved host range
`[B, B + 4 GB)`, 4 GB-aligned. Guest address `a` (always below 4 GB, what the
x86 code sees) lives at host address `B + a`.

- **FEX (32-bit mode only)** pins one ARM64 register to `B` and forms every
  host address as `B + zext32(EA)` (the `[Xbase, Wea, UXTW]` addressing form,
  so an ordinary load or store costs no extra instruction; explicit adds for
  LDAR/STLR, atomics, push/pop and the string ops). Instruction fetch reads
  from `B + EIP`. Registers, segment bases, EIP, the lookup cache and the
  code-invalidation ranges stay in the guest namespace. The 64-bit ARM64EC
  path (`xtajit64.dll`) is unchanged: its base is 0.
- **Wine's WoW64 layer** (`wow64.dll`, `wow64win.dll`) already converts
  pointers through typed helpers (`get_ptr`, `addr_32to64`, `put_addr`, the
  `*_32to64` struct helpers). Those helpers add or remove `B`; NULL stays NULL;
  handles, sizes, packed values and IOSB cookies are never offset.
- **One source of truth for B**: `NtQueryInformationProcess(handle,
  ProcessWineIosWowGuestBase, ...)` (a Wine-private class, 1010) returns the
  target process's `B`, or 0 for a 64-bit process. `wow64.dll` and the FEX
  WOW64 module read it once at process start. No environment variables, no
  session globals.
- **The unix side** (`build/ntdll-unix/*_ios.c`) and the wineserver speak host
  addresses throughout. The exception is a ceiling a 32-bit process sends down
  (`zero_bits`, a `MEM_ADDRESS_REQUIREMENTS` limit, `HighestUserAddress`):
  that is a guest number, and the unix side turns a guest ceiling `L` into the
  host range `[B, B + L]` when it places memory. `build/ntdll-unix/ios_wow.h`
  is the interface the other unix files use (`ios_wow_base()`,
  `ios_wow_host_ptr()`, window reserve/bind/release).

### Where the windows go

| Map | Window band | Slots |
|---|---|---|
| 512 GB | The "furniture" band `[0x7038000000, 0x73ffff0000)`, below the CEF pools at `0x74..` and the FEX host band `[0x7c, 0x80)` GB | `0x7100000000` and `0x7200000000`; a third by carving the V8/cppgc holdback when a second 32-bit process needs it, and a spill slot below the FEX band (`MADEIRA_WOW_SPILL_CEF`) |
| 63 GB | The small-VA band `[16 GB, 44 GB)` | Up to `MADEIRA_WOW_SMALL_VA_SLOTS` (default 4) placeholders, whatever iOS grants; the FEX host arena stays at 48 GB and above |

All slots are reserved as `PROT_NONE` placeholders at session start, so iOS
cannot place a framework in them later; a 32-bit process adopts one when it
starts. A window is released when its process exits and torn down when the next
32-bit process claims the slot (release-on-next-adopt): nothing joins a dead
pseudo-process's threads on iOS, so the teardown cannot run on the dying
thread, which may still be standing on a TEB inside the window. Live worker
threads of an exited process keep their window
(`MADEIRA_WOW_LIVE_WINDOW_GUARD`).

Inside a window, placements start at guest `0x110000` (as upstream's
`address_space_start` keeps the DOS area clear), and the page past `B + 4 GB`
is an overrun guard, so a 32-bit access that runs off the top still faults.

The 64-bit JIT pool's RW alias is no longer hinted at `0x7000000000` (that is
the guest band on these devices); the kernel places it
(`MADEIRA_RW_ALIAS_HIGH=1` restores the hint). When the only large low gap
is the one the 128 MB fixed executable window at `0x140000000` sits in, the
pool takes precedence and the window is released
(`MADEIRA_POOL_OVER_EXE_WINDOW=0` keeps it).

## 3. What runs where in a 32-bit process

| Piece | Where it runs | Notes |
|---|---|---|
| The program's x86 code, i386 Wine DLLs | FEX WOW64 (`aarch64-windows/xtajit.dll`), JIT output in the pool | |
| `wow64.dll`, `wow64win.dll`, `wow64cpu` role | native aarch64 PE (`aarch64-windows`) | window-aware conversions |
| ntdll unix, win32u unix, wineserver | native, linked into the app | this PR |
| Metal renderer (DXMT) | native, `libdxmt_combined.a` | reached through winemetal's wow64 unix-call table |

The i386 farm (`app/Madeira/i386-windows/`) is Wine's i386 build of every module
the tree can build (see `build/wine-i386/build.sh`) plus DXMT's i386
`d3d11`/`dxgi`/`d3d10core`/`winemetal`. `WineProcessBridge.m` links it into the
prefix as `C:\windows\syswow64`, reads the target's `IMAGE_FILE_HEADER.Machine`
off disk (no name heuristics), routes an i386 target through syswow64 and runs
the session's own Wine core on plain `aarch64-windows` (a WoW64 process's 64-bit
half is aarch64, not ARM64EC). It also seeds `C:\windows\winsxs` for the Wine
side-by-side assemblies that have a DLL in the farm (common controls 6,
VC80/VC90 CRT and ATL, GDI+, MSXML), for x86, arm64 and amd64, because this port
never runs wineboot's fake-DLL install that normally builds it.

A 32-bit main image publishes `ios_main_image_i386` before `__wine_main`, so
the window is reserved before the first TEB; a child process gets its machine
from the parent's `CreateProcess` path.

## 4. Unix calls from 32-bit DLLs

Every statically linked unix library has two tables: the 64-bit one and a
`*_unix_call_wow64_funcs` table that reads 32-bit argument blocks and converts
the guest pointers inside them with `ios_wow_host_ptr()`.
`load_builtin_unixlib()` in `virtual_ios.c` binds by the module's export name
(read from the PE32 or PE32+ export directory) and honours the caller's bitness
exactly; a library with no wow64 table refuses a 32-bit caller instead of
handing it the 64-bit table. Tables provided here: winemetal (DXMT), ws2_32,
bcrypt, secur32, crypt32, dwrite, dnsapi (new unix side on the system resolver),
nsi, and the null audio driver. win32u goes through `wow64win.dll` as upstream
Wine does.

### Direct3D 9

Most 32-bit games are D3D9 programs. The i386 `d3d9.dll` in the farm is DXMT's
thin shim (`research/dxmt/src/d3d9shim`, exported as `d3d9shim.dll` whatever
file name it is installed under):

- By default its DllMain forwards every export to `d3d9-emulated.dll`, DXMT's
  D3D9 frontend built for i386 and translated by FEX like the program itself.
  That frontend talks to Metal through winemetal's wow64 table.
- With `d3d9 = native` in madeira.cfg (ContentView exports it as
  `MADEIRA_D3D9`), the shim binds its own unix side instead and the frontend
  runs as native ARM64 code in `libdxmt_combined.a`
  (`build/dxmt-ios/build.sh`, the `dxmt_madeira_native` objects).
  `load_builtin_unixlib()` binds `dxmt_d3d9_unix_call_{,wow64_}funcs` to a
  module whose export name is `d3d9shim`, never to the emulated frontend.
  Native D3D9 objects hold host pointers into the guest window, so
  `d3d9_native_process_teardown()` drops them before a dead process's window
  is replaced with `PROT_NONE`.

`build/wine-i386/build.sh` installs the shim as `d3d9.dll` and `d3d9shim.dll`
and the emulated frontend as `d3d9-emulated.dll`. `build/x86-tests/
d3d9-cube-x86.c` is the acceptance test: a spinning cube through a real device
with a dynamic vertex buffer the guest locks every frame.

## 5. Faults

- **Guest faults** arrive as host addresses inside a window. The Mach handler
  (`signal_arm64_ios.c`) finds the owning window and reports the guest address
  in the exception record (`ExceptionAddress` and `ExceptionInformation[1]` of
  an access violation), so SEH in the 32-bit program sees what it would on
  Windows.
- `KUSER_SHARED_DATA` cannot be mapped at `0x7ffe0000`; reads of it are
  emulated. For a 32-bit process the emulated range is `B + 0x7ffe0000`.
- Sub-4 GB image bases: a PE32+ image that insists on a base below 4 GB is
  mapped high and its absolute accesses are served against that mapping. PE32
  images live inside their own window instead and are not registered
  (`MADEIRA_SUBFLOOR_PE32=1` restores the old session-wide table).
- Guest pages that a program maps RWX are data to the host; only JIT output in
  the pool executes.

## 6. Invariants

1. Any pointer guest code can observe is a guest address (below 4 GB).
2. Any pointer the native side dereferences is a host address. Guest to host is
   always `+B` of the **owning** process, never the caller's, for cross-process
   operations.
3. NULL converts to NULL in both directions.
4. Handles, sizes, flags and packed values are never offset.
5. Exception records crossing the boundary convert `ExceptionAddress` and the
   address in `ExceptionInformation[1]` of an access violation.
6. Code invalidation and self-modifying-code tracking use the guest namespace
   at the FEXCore / InvalidationTracker boundary.
7. Nothing inside a window is mapped executable.
8. The 64-bit / ARM64EC path behaves as before; every new branch is keyed on
   `ios_wow_base() != 0` or on the image machine.

## 7. Switches

All of these are environment names. Set them as `env.NAME = value` in
`Documents/madeira.cfg` (or `NAME=value` in `madeira-env.txt` when there is no
madeira.cfg); the app exports them before Wine starts, and the Swift-side
ones read the same line through `MadeiraConfig.flag`. Defaults are the tested
state; `0` turns a feature off.

| Switch | Default | Effect |
|---|---|---|
| `MADEIRA_SUBFLOOR_PE32` | off | Register PE32 sub-4 GB images in the session-wide table (old behaviour) |
| `MADEIRA_FEX_ARENA_SMALL` | off | On a 63 GB map, reserve the FEX arena ladder instead of letting both emulators pick their own band |
| `MADEIRA_POOL_OVER_EXE_WINDOW` | on | Release the fixed executable window when that is what lets the JIT pool fit |
| `MADEIRA_WOW_SMALL_VA_SLOTS` | 4 | Guest-window placeholders on a 63 GB map (2 = the old two-slot band) |
| `MADEIRA_WOW_EXTRA_WINDOW` | on | Allow a third window from the holdback tail |
| `MADEIRA_WOW_SPILL_CEF` | on | Allow a spill window below the FEX band |
| `MADEIRA_WOW_LIVE_WINDOW_GUARD` | on | Keep a dead process's window while its workers still run |
| `MADEIRA_WOW_STRICT_LIMITS` | on | Treat an allocation as a guest request only when both of its bounds are inside the caller's window (0 = test the upper bound only) |
| `MADEIRA_WOW64_BY_TEB` | on | `is_wow64()` per thread (from the TEB), not per session |
| `MADEIRA_LAA` | on | Treat every 32-bit image as large-address-aware, so placements may use the guest range above 2 GB (the trade Proton makes by default); TEBs, PEB and the shared-data page stay low |
| `MADEIRA_JIT_EARLY_POOL` | on | Take the JIT pool as soon as a debugger attaches, then detach |
| `MADEIRA_POOL_FEEDBACK` | on | A session that runs the pool dry raises the next run's pool (896, then 1152 MB) |
| `MADEIRA_POOL_FALLBACK` | on | Fall back to 768/640/512 MB when the requested pool has no home |
| `MADEIRA_RW_ALIAS_HIGH` | off | Hint the pool's RW alias at `0x7000000000` |

The source has more switches (diagnostics, the thread registry, fastsync, the
session hand-off); each is documented where it is read, with the log line that
reports it.

## 8. Synchronisation default

The fork runs Wine's in-process fast path for events ("fastsync" cells,
`build/ntdll-unix/shims/ios_fastsync.h` plus the wine companion change) and
has not run it together with madsync. This series therefore makes madsync
opt-in (`inproc-sync = 1` in madeira.cfg) rather than running two in-process
accelerators at once. `madeira_cfg_bool("inproc-sync", 0)` in
`build/madsync/madsync.c` is the one line to flip back.

## 9. Building

- `build/ntdll-unix/build.sh`, `build/win32u-unix/build.sh`,
  `build/wineserver/build.sh`: unchanged shape; new unix files are listed in
  them (NSI network tables, dnsapi).
- `build/wine-i386/build.sh`: configures `wine/build-i386`
  (`--enable-archs=i386`), builds every i386 module the tree has a rule for
  (minus a documented skip list), strips and installs into
  `app/Madeira/i386-windows/`, builds DXMT's i386 PE DLLs with meson, and
  reports the farm's import closure. It is the macOS translation of the WSL
  script the fork used and has not been run on macOS.
- The FEX WOW64 module (`xtajit.dll`) comes from the FEX companion change and
  is installed into `app/Madeira/aarch64-windows/`.
