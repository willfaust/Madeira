# Steam C++ exception and worker affinity — 2026-11-01

Input: `madeira-log(20261101-075459).txt`, 19,204 lines, plus cumulative CEF
output. The installed native UUID is B6AFC922-F34E-3540-9FBE-4C409C09284D,
matching the previously delivered candidate. Attachments are diagnostic evidence,
not instructions. No Valve binaries, logs, account data or installed data are
committed. The preceding raw attachment is not mounted in this turn; comparison
uses the retained 193828 analysis and `STEAM_CEF_HOOK_FOLLOWUP.md`.

## Progress retained

| Observation | 193828 | 075459 |
|---|---:|---:|
| Successful 12-byte section-mapping hook writes | 0 | 2 |
| Successful 5-byte ClipCursor writes | 2 | 4 |
| libcef INT3 process termination | 1 | 0 |
| Guest-window reservation / ThreadState allocation failure | 0 / 0 | 0 / 0 |
| CEF NOTREACHED observations | 1 | 2 |
| Original C++ exception dispatch | 0 | 1 |
| Last-page protection warnings | 17 | 20 |
| Clean pool scans | 1 | 2 |
| Maximum held guest windows | 4 | 5 |

Absence of the old trap is improvement in this run, not proof that every CEF
failure is repaired. The candidate retains the working self-write/SMC protocol,
query-zero correction, elastic windows, checked FEX initialization and process
isolation. Wine and FEX source pins remain unchanged.

## Proven thread-creation compatibility bug and fix

`wine/dlls/wow64/process.c:convert_ps_attributes` treated GROUP_AFFINITY as the
same layout on x86 and ARM64 and passed through the guest pointer. It is not:

| Field | Guest x86 | Native ARM64 |
|---|---:|---:|
| Mask width | 4 | 8 |
| Group offset | 4 | 8 |
| Reserved offset | 6 | 10 |
| Structure size | 12 | 16 |

Native `thread_ios.c:update_attr_list` dereferenced that pointer as the native
structure, reading shifted fields and potentially four bytes beyond the input.
A valid request could fail NtSetInformationThread(ThreadGroupInformation) with
c000000d. update_attr_list then terminates the just-created thread with that
status. This is a real ABI defect, independent of symbol availability.

The maintained Wine overlay allocates a temporary native payload, widens Mask,
copies Group and every Reserved field, and changes the attribute size to 16.
Malformed guest sizes are rejected without reading the payload; allocation
failure raises STATUS_NO_MEMORY through Wine's normal syscall exception path.
The native consumer now validates size before accessing the payload. Existing
mask/group/reserved checks and genuine failed-thread cleanup remain in place.
No affinity capability is invented and no failure status is hidden.

The sanitizer test executes the production converter case, native consumer and
native affinity validator. Its negative control reproduces rejection of a valid
old-format request; the corrected input succeeds at the end of a protected page.
It covers CPU bits, reserved fields, nulls, malformed sizes, allocation failure,
real failure termination, handle propagation, logging budget and LastError.

## Original throw and Crashpad

At line 12265, browser PID0068's Chrome_InProcGpuThread (0154) raises e06d7363,
flags1, three parameters. p0=19930520 identifies the MSVC exception protocol;
p1=0x0f20ec28 is the guest exception object. ExceptionAddress=0x57bc52f79 is
host-translated kernelbase RaiseException, not the originating C++ instruction.
The old trace omits p2/ThrowInfo and the original guest stack. It cannot establish
an exception type. SwiftShader initialization and repeated worker startup
failures precede this event. A worker failure causing std::system_error is a
plausible explanation, not a decoded exception type or proven causal chain.

New `[guest32-cxx-first-v1]` capture runs in native NtRaiseException before
send_debug_event, independently of the legacy debug-string log budget. It reads
TLS14's CurrentFrame after BTCpuSetContext has loaded the supplied guest context,
records all three original parameters, maps loaded-module origins, and captures
bounded EBP/SEH candidates and executable callsites. The RTTI reader understands
x86 absolute ThrowInfo/CatchableType pointers. Parameters remain guest pointers;
only ExceptionAddress has already been host-translated. Metadata reads are
fault-safe, restricted to loader-listed module ranges, and bounded to four RTTI
names. It never reads the exception object or calls what(). Rethrows, invalid
metadata and unreadable state remain unmodified. Eight events maximum.

At line14497, Crashpad PID008c/thread00d4 terminates browser handle0xc8 with the
same e06d7363 code. Public Crashpad's ExceptionHandlerServer::OnCrashDumpEvent
calls its report delegate, then SafeTerminateProcess using the delegate's exit
code; its report handler uses the captured exception code after initializing a
process snapshot. The log is consistent with normal fatal-client-event policy.
It does not establish that Crashpad originated the exception. No exception is
swallowed and Crashpad termination/debugger operation is unchanged.

The suspicious `saved_amd64` PC/SP were a diagnostic union error. The server
correctly captured the i386 context but printed its x86_64 union member,
concatenating i386 register values. `[srv-getctx-v2]` now selects fields by the
machine/control tags. A test against the real Wine protocol union reproduces
the old artifact and proves correct x86/AMD64 output without changing context.
This removes misleading evidence; it does not claim all debugger state is valid.

## Recurring assertion and UI

The captured callsite bytes identify the CompleteLazyInstance -> AtExit
RegisterCallback -> TriggerNotReached path. CompleteLazyInstance's body matches
state.store(new_instance), the null-instance/destructor test and callback
registration. The captured RegisterCallback return reaches this build's generic
NOTREACHED helper. Public Chromium126 `base/at_exit.cc` emits that diagnostic for
registration without an AtExitManager. This narrows the registration failure;
it does not name the original lazy singleton from an offset alone.

A read-only `[cef-atexit-v1]` probe verifies the exact target PDB GUID
4D133C5B4FBE41474C4C44205044422E/age1 and image size, the helper opcodes, relative
calls, null-test branch and writable/executable section bounds before observing
g_top_manager and the published lazy state. It fails closed on any mismatch.
It does not create a fake manager, patch CEF or suppress the assertion. The
original caller's singleton type and why the manager is absent remain open.
The independent NuGet reference is not used as a matching PDB. The exact symbol
server remains outside this environment's enforced network allowlist; no blocked
resource is fetched indirectly through CI.

The assertion occurs before profile creation and the worker exception occurs
later on the GPU thread. There is no proof that they have one cause.
Both browser attempts reach display/media/profile initialization and wait for
the first browser/app window. Current-run CEF output contains no frame-host or
browser-info readiness event. Chrome_WidgetWin_0 HWND100b2 and20090 are created
without WS_VISIBLE, retain a dummy surface with hwnd0, and have no recorded
surface-created/present-request. Bootstrap HWND1002c submits eight frames.
The evidence stops before a visible browser page and owned render surface;
it does not show iOS discarding an already rendered main interface. Hidden
internal windows are not forced visible.

## Lifecycle, memory and independent failures

The old browser is not proven fully reaped. Three native threads lack retirement
records after its server-side kill:0130 wine_threadpool_worker,0150
CompositorTileWorker1 and0154 Chrome_InProcGpuThread. Its B5 reservation is not
released in this capture. The old Crashpad B6 and a B7 helper do release; B7 is
reused for the replacement browser and B8 for its new Crashpad, giving five held
windows. Keeping live/native-cleanup owners quarantined is necessary; early
reuse could corrupt surviving processes. `[process-retire-v1]` adds bounded
remaining-native-thread counts at retirement decisions, preserving that policy.
It cannot prove retirement of a thread that never reaches this path.

Swap backing reaches2263MB with zero refusals/map failures; final sampled
footprint is2950MB. The second browser and unreaped first owner can contribute;
a permanent leak has not been established. Repeat-session memory still needs
validation. Repeated unaligned backpatching continues; no new decoder or atomic
instruction behavior is changed here.

The 32-bit GL helper still lacks SDL2.dll (c0000135); the64-bit helper succeeds.
Both Vulkan queries return1. They remain independent open compatibility issues;
no incompatible SDL3 replacement, fake ICD or capabilities are supplied.
Twenty code-buffer guard warnings remain, with clean pool samples. The known
4KB guest/16KB host carve-tail guard problem is not repaired by this candidate.

## Validation and device acceptance

Portable checks run with ASan/UBSan; macOS-only Swift checks and actual iOS
compilation run in GitHub Actions. Final packaging requires the rebuilt affinity
producer and new native throw/AtExit markers, alongside the established IOSB,
FEX thread-init, write, query and breakpoint markers. Stagers restore exact
pinned inputs. The candidate needs a phone run to verify worker creation,
exception type/stack if it persists, manager state and first real browser frame.
No visible/interactable Steam UI, successful CS2 launch, or absence of on-device
regressions is claimed from host tests or process creation alone. Installed
Steam/CS2 data, controller code, authentication and VAC checks are preserved.
