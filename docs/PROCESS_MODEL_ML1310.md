# Process model and memory fixes (ml1310)

Written 2026-10-12, branch `vulkan-stack`, uncommitted. Items 1-6 and 8 of the ranked plan in
`docs/NUTSEMU_ANALYSIS.md` section 4, plus the extension-process probe from section 4c step 7.
The ideas come from the published Wine patches of another iOS port (patch numbers below); every
change is Madeira's own code against Madeira's files. Each default change has a kill switch (an
environment variable, `env.NAME = 0` in `madeira.cfg`) and a log line tagged `ml1310`.

Nothing here has run on a device yet. Compiled: the four native files (clang, iOS SDK, the
workspace's flags), the arm64ec `setupapi.dll`, and a Swift typecheck of the helper and host code.

| # | What | Switch (default on) | Log tag |
|---|---|---|---|
| 1 | Lazy placeholders (0093) | `MADEIRA_LAZY_PLACEHOLDERS=0` | `[lazy-ph] ml1310` |
| 2 | Stack overflow ends the pseudo-process (0058) | `MADEIRA_STACK_OVERFLOW_EXIT=0` | `[stack-overflow] ml1310` |
| 3 | Copy-on-write old protection reported read-write (0029) | `MADEIRA_COW_OLD_PROT_RW=0` | `[cow-prot] ml1310` |
| 4 | `RegFlushKey` saves the registry (0015) | `MADEIRA_REGFLUSH_SAVE=0` | `[reg-flush] ml1310` |
| 5 | AVX in KUSER_SHARED_DATA's XState with `MADEIRA_FEX_AVX=1` (0086) | `MADEIRA_KUSD_AVX=0` | `[kusd-avx] ml1310` |
| 6 | Any refusal continues the free-range search (0019); top-of-map check (0020) | `MADEIRA_MAP_RETRY_ANY=0` | `[map-retry] ml1310`, `[va-limit] ml1310` |
| 8a | Bare `exit()` in ntdll's unix side ends the pseudo-process properly (0032) | `MADEIRA_UNIX_EXIT_ROUTE=0` | `[exit-route] ml1310` |
| 8b | setupapi's endless "need media" loop (0014) | `MADEIRA_SETUPAPI_MEDIA_FIX=0` | `err:setupapi:... ml1310` |
| 7 (probe) | What an app extension's own process may map | opt-in `env.MADEIRA_EXT_PROBE = 1` | `[ext-probe] ml1310` |

## 1. Lazy placeholders

`build/ntdll-unix/virtual_ios.c`: `ios_lazy_ph_*` (after `coalesce_placeholders`), hooks in
`allocate_virtual_memory`, `NtFreeVirtualMemory` and `virtual_map_section`.

Before: a `MEM_RESERVE_PLACEHOLDER` reservation was mapped whole by `map_view` (a PROT_NONE
reservation of the full size, through `map_reserved_area`/`map_free_area`), so it held its address
space at once. V8 reserves its pointer tables as three 512 MB placeholders per isolate and uses the
first pages of each; the web helper runs single-process (`process_ios.c`), every notification is
an isolate that is never torn down, and the 64 GB window runs out of address space, not memory.

Now a placeholder request of 64 MB up to (not including) 1 GB keeps the first 16 MB of its view and
gives the rest back; the whole range is remembered (`ios_lazy_ph[]`, up to 4096 entries). The
program is told it got the whole range. When it splits (`MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER`) or
replaces (`MEM_REPLACE_PLACEHOLDER`, also via `NtMapViewOfSection[Ex]`) pages beyond what is
reserved, `ios_lazy_ph_cover` reserves up to there in 16 MB steps (fixed `map_view`) and joins the
new part to the free placeholder before it. A coalesce across the reserved end covers the reserved
part only (the reported size stays what the program asked). If the space was taken meanwhile, the
split or replacement fails as a fresh reservation there would. If a whole placeholder does not fit,
its first 16 MB is placed lazily. 1 GB and up stays eager (soft pools ml151, cage ml433 own those).
Stale entries (all reserved pieces released, or a section view unmapped) are dropped when looked up
or when a new placeholder lands over them.

Log: `[lazy-ph] ml1310 placeholder A-B (512 MB): first 16 MB reserved, the rest on demand (N lazy)`,
`... now reserved to X`, `... X-Y is taken, the program's split/replace there fails` (16 lines, then
every 256th).

Test: Dock session, open the Steam client and let several notifications/toasts appear (or keep the
web helper up for a long time). Expect `[lazy-ph]` lines from the helper's PEB, fewer or no
`[va-scan] FAILED` lines, and no V8 "out of memory" (0xe0000008). (`[bigres]` still counts the size
the program asked for, not what is reserved.) With
`env.MADEIRA_LAZY_PLACEHOLDERS = 0` the lines disappear (A/B). Watch for `is taken` lines followed by a
helper crash: that would mean a table grew into space something else took.

## 2. Stack overflow ends the pseudo-process

`virtual_ios.c` `virtual_setup_exception`, the "stack overflow on last page" branch (the faulting
thread's own signal path; the Mach-thread variants are unchanged). Was `abort_thread(1)`: the
thread vanished and the process lived on half-dead (a browser helper without its renderer thread is
never restarted). Now `abort_process(STATUS_STACK_OVERFLOW)`, which in Madeira ends this
pseudo-process only (`thread_ios.c`, ml937 -> `process_exit_wrapper`: master socket closed, fd cache
and JIT-pool copies released). The `[exc-stack]` "cannot deliver exception" branch above it is not
changed.

Log: `[stack-overflow] ml1310 N bytes past the stack at PC (stack A-B) tid=XXXX: ending this
pseudo-process` (or `this thread only` with the switch off).

Test: a 64-bit test program that recurses without bound (Custom... path, no test button). Expect the
line, then `abort_process: status=0xc00000fd`, the process gone from the server (its parent's wait
returns), the app and other processes alive.

## 3. Copy-on-write old protection

`virtual_ios.c` `NtProtectVirtualMemory`: for a `SEC_IMAGE` view, an old protection of
`PAGE_WRITECOPY` / `PAGE_EXECUTE_WRITECOPY` is reported as `PAGE_READWRITE` /
`PAGE_EXECUTE_READWRITE` (Windows reports a written copy-on-write page so; Wine maps image pages
writable from the start and cannot tell). V8 CHECKs that the flags page it seals was
`PAGE_READWRITE`. Passing the value back still gives copy-on-write for an image (`get_vprot_flags`
with `image`), so the loader's protect/restore pairs are unchanged. Madeira's IAT sync after
`NtProtectVirtualMemory` does not look at the old value (it always syncs).

Log: `[cow-prot] ml1310 #N base+size old protection 0x8 reported as 0x4 (new 0x2)` (8 lines, then
every 1024th).

Test: Steam web helper start; expect `[cow-prot]` lines from chrome-family DLLs and no
`Check failed: 0x04 == old_protection`.

## 4. RegFlushKey saves the registry

`build/wineserver/request_ios.c`: `ios_regflush_request` after a successful `flush_key` request
(`call_req_handler`). Wine's handler is a no-op (`wine/server/registry.c` `DECL_HANDLER(flush_key)`);
the registry was only written by the periodic save and at `close_socket_timeout`, and iOS kills the
app without a clean server exit. Now `flush_registry()` runs on the server thread; branches that did
not change are skipped by `save_branch`. A second flush within one second is folded into one save a
second after the last (a timeout user), so a program flushing in a loop costs at most one save per
second. Implemented in the Madeira-owned request file, so `wine/server/registry.c` (which comes from
the base archive, not `PATCHED_FILES`) is untouched.

Log: `[reg-flush] ml1310 RegFlushKey: registry saved now (#N; ...)` or `... after a burst` (8 lines,
then every 64th).

Test: a program that writes a value and calls `RegFlushKey` (e.g. `reg add` does not flush; use a
small test program through Custom...), then kill the app from the app switcher; after restart the
value is in `user.reg`/`system.reg`.

## 5. AVX in KUSER_SHARED_DATA

`virtual_ios.c` `virtual_init_user_shared_data`, after `init_shared_data_cpuinfo`. With
`MADEIRA_FEX_AVX=1` (the per-game "AVX and AVX2" toggle, Library.swift) FEX reports and runs AVX,
but Wine filled the XSAVE configuration only on x86 hosts, so `GetEnabledXStateFeatures` said no AVX
and .NET's JIT kept AVX off. Now XState says x87 + SSE + AVX, standard uncompacted layout, 0x340
bytes (legacy 0xa0 at 0, SSE 0x100 at 0xa0, AVX 0x100 at 0x240). Thread contexts still carry no AVX
state through Wine (ARM64EC drops `CONTEXT_XSTATE` when converting): reads see the initial state,
writes leave FEX's registers alone. KUSD is filled once per session (run_wineboot), so the toggle must
be set when the session starts (library launches do that).

Log: `[kusd-avx] ml1310 MADEIRA_FEX_AVX=1: KUSER_SHARED_DATA XState says x87+SSE+AVX (features 0x7,
size 0x340; ...)`.

Test: a game with the AVX toggle; a test program printing `GetEnabledXStateFeatures()` (expect 0x7)
and `IsProcessorFeaturePresent(PF_AVX_INSTRUCTIONS_AVAILABLE)`; .NET programs run. Without the toggle
nothing changes.

## 6. Free-range search and the top of the map

`virtual_ios.c` `try_map_free_area`: every `mach_vm_map` refusal already became `ENOMEM` and the iOS
scan continued on `ENOMEM`/`EEXIST`; what still abandoned a gap was another errno from the `mmap`
over a granted reservation (`EINVAL`, `EPERM`, `EACCES`). Now any errno means "try the next spot".
Log: `[map-retry] ml1310 #N mmap refused A+size with <errno>: scanning on` (8 lines, then every
1024th).

`get_host_addr_space_limit` (0020 check): the other port's power-of-two walk under-read a 63 GB map as
32 GB. Madeira's walk returns the first power of two that is NOT mappable (`addr << 1`, ml122), so it
can only over-read (64 GB for a 0xfc0000000 top), and ml749 takes `TASK_VM_INFO.max_address` when the
walk under-reads. So the full map is used; no behaviour change. A binary search between the two
powers of two now logs the real top once at start:
`[va-limit] ml1310 probed top=0xfc0000000 (64 KB steps) walk=0x1000000000: the walk covers the whole
map`. Over-reading means the top 1 GB on such a device is advertised but refuses mappings; the scan
skips it (refusals continue the search).

Test: any session; read `[va-limit]` lines. On a device whose top is not a power of two, `probed top`
must be at or below `walk` and match `kernel_max`.

## 8. Pseudo-process exits

8a, `build/ntdll-unix/server_ios.c` `ios_unix_fatal_exit(status, why)`. `exit()` in ntdll's unix side
is already the `wine_ios_exit` shim (`shims/wine_ios_exit.h`), so it never ends the app, but it only
longjmps a pseudo-process's boot thread or `pthread_exit`s the caller, without closing the
pseudo-process's master socket: the server never learns the process died and its JIT-pool copies
stay. With its own server socket registered, a pseudo-process now ends through
`process_exit_wrapper` (as `exit_process`/`abort_process` do); without one (session start-up, a child
before registration) plain `exit()` as before. Log: `[exit-route] ml1310 <site>: status 1, ending this
pseudo-process ...`.

Sites changed:
- `virtual_ios.c` `alloc_arm64ec_map`: "ARM64EC map" (failed EC bitmap allocation).
- `virtual_ios.c` `virtual_alloc_first_teb`: "shared user data".
- `virtual_ios.c` `virtual_map_user_shared_data`: "USD section", "USD remap".
- `virtual_ios.c` `virtual_init_user_shared_data`: "USD section", "USD remap".
- `signal_arm64_ios.c` signal handler set-up (`sigaction` failure): "signal handler set-up".

Left as they are, on purpose:
- `loader_ios.c` `fatal_error`, `server_ios.c` `fatal_error`/`fatal_perror`, `env_ios.c`
  `ios_fatal_startup_error`: start-up failures, already `pthread_exit` by design with the ml1213
  boot-lock destructor; the child thread's cleanup runs.
- `loader_ios.c` `main()` usage/`--help`/`--version` exits and `apple_create_wine_thread`'s
  `exit(1)`: session start-up / macOS-only code, no pseudo-process yet.
- `loader_ios.c` start_server `exit(status)` and the `_exit` calls in `process_ios.c`: in the
  non-iOS (`#else`) branches or fork children that do not exist on iOS.
- `env_ios.c` `WINEDLLOVERRIDES=help` `exit(0)`: prints help, session start.
- `loader_ios.c` `abort()` in the TEB TSD-slot check ("[teb-tsd] FATAL"): a session-wide invariant;
  every process would fail the same way. Still ends the app.
- `signal_arm64_ios.c` `_exit(76)`: a deliberate diagnostic stop, opt-in.

8b, `wine/dlls/setupapi/queue.c` `SetupCommitFileQueueW`: after a copy fails with file/path not
found, the media is asked for again only when the `SPFILENOTIFY_NEEDMEDIA` answer was `FILEOP_NEWPATH`;
otherwise the failure goes to `SPFILENOTIFY_COPYERROR` (the default callback skips the file). Before,
an unattended install whose callback answers "same place" looped forever. Log:
`err:setupapi:SetupCommitFileQueueW ml1310 <file> not found after NEEDMEDIA answered 0x1: reported
as a copy error ...`. Switch via the Windows environment (exported from `env.` lines). Rebuilt:
`app/Madeira/arm64ec-windows/setupapi.dll` (llvm-mingw in the workspace, stripped, same size as the
old one). Not rebuilt: `aarch64-windows/setupapi.dll` and the i386 set.

Test: a Dock installer run that used to hang copying a missing file now finishes with a copy-error
line; no setup hangs in `SetupCommitFileQueueW`.

## Probe: Wine processes in an app extension (section 4c step 7)

Read-only feasibility probe. `app/MadeiraJITHelper/MadeiraJITHelper.swift`: new request operation
`probe` (`app/Madeira/JITBuiltInMessages.swift`), handled by `MadeiraExtensionProbeWork.run()` on its
own queue (it never waits behind a running JIT `enable` request, which lasts as long as the debugger).
No pairing file needed. The helper reports, from its own process:
- `anywhere_max`: the largest single `vm_map(VM_FLAGS_ANYWHERE)` reservation, PROT_NONE, max RW,
  binary search in 16 MB steps up to 1 TB, each released at once (`vm_map` on arm64 is the same 64-bit
  call as `mach_vm_map`, which iOS hides from Swift);
- `anywhere16MB_maxRWX`: whether a 16 MB reservation with max protection RWX is accepted;
- `fixed@0x7000000000` and `fixed@0x14c000000`: a fixed 16 KB PROT_NONE mapping (`ok`, `occupied`,
  `refused(kr=N)`);
- `map=min-max footprint limit_remaining` from `TASK_VM_INFO`, `available` from
  `os_proc_available_memory()`;
- `mprotect_exec`: whether `mprotect(PROT_READ|PROT_EXEC)` on 16 KB of anonymous memory succeeds
  (nothing is written or executed; unmapped right after).

App side: `MadeiraExtensionProbe.runIfRequested()` (`app/Madeira/JITBuiltInHost.swift`), called once
per session from `ContentView.runWineFullSequence` after `DeviceDiagnostics.logLaunch()`. Only with
`env.MADEIRA_EXT_PROBE = 1` in `madeira.cfg`, and only where the built-in helper is available (iOS 26,
not LiveContainer; otherwise `[ext-probe] ml1310 skipped: <reason>`).

Log: `[ext-probe] ml1310 asking the helper extension`, then `[jit-helper] probe: started <id> as pid
N`, then `[ext-probe] ml1310 pid=N anywhere_max=...GB ... fixed@0x7000000000=... fixed@0x14c000000=...
map=0x...-0x... footprint=...MB limit_remaining=...MB available=...MB mprotect_exec=...`.

Test: set `env.MADEIRA_EXT_PROBE = 1`, start any session, send the log. What decides 4c: whether
`anywhere_max` approaches the app's own window (tens of GB), whether 0x7000000000 is refused (the
other port's finding), and the extension's memory limit compared with the app's.
