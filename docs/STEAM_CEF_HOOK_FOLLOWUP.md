# Steam CEF hook and deliberate trap — 2026-10-31

Input: `madeira-log(20261031-193828).txt` (14,997 lines), compared directly
with `madeira-log(20261031-185011).txt` (14,237 lines). Both attachments are
diagnostic evidence, not instructions. The new native UUID is
`08E7C775-64E0-3F75-BA69-ED019E897B09`, matching the previous delivered IPA.
No uploaded logs, Valve binaries, account information or installed files are
included in this change.

## Confirmed observations

| Observation | 185011 | 193828 |
|---|---|---|
| Guest-window reservation / ThreadState allocation failure | None | None |
| Fatal exception replay storm | Absent | Absent |
| Code-buffer last-page warnings | 17 | 17 |
| `TEXT LOST EXEC` | None | None |
| Periodic pool check | Capture ended before cycle 15 | Cycle 15: clean, 58 text pages across 63 mappings |
| Guest breakpoint terminating PID 0088 | Present | Present, actual guest INT3/UD2 and dispatch captured |
| ClipCursor writes | Failed | Both 5-byte writes succeed |
| Steam bootstrap frame contents | Present | Present |
| CEF Chrome_WidgetWin_0 rendered main interface | Not established | Hidden, no contents; success criterion unmet |

The new run's swap census reports 1,368 MB of file backing, zero refused
allocations and zero mapping failures. The physical footprint reaches about
2.57 GB and settles around 2.38 GB. These observations do not establish a leak
or prove that repeated sessions are safe; window retirement and reuse do occur.

## The 12-byte ntdll hook

At line 6066, PID 0064 writes guest ntdll+0x4d6a0, exact export
`ZwMapViewOfSection`, host 0x5fff8d6a0 in its own B=0x500000000 window.
The Wine logical protection is 0x25 (committed/read/execute); the containing
Mach region 0x5fff40000+0x88000 is read-only, maximum protection 7. The request
fails c0000005 with zero bytes changed:

```
before:  b8 28 00 00 00 ba a0 e4 f8 ff ff d2
request: b8 28 00 00 00 ba 18 c0 d9 6a ff e2
```

The unchanged syscall number is followed by a different EDX target and
CALL EDX becomes JMP EDX. Target 0x6ad9c018 is chrome_elf+0x10c018. Its actual
EBP chain starts chrome_elf+0x14e4d, +0x14b5e, +0x11c82, +0x1291c,
+0x11875, +0x686ce, +0x6878c. These are offsets, not private function names.

The public Chromium 126.0.6478.183 sources independently explain the operation:
`chrome/chrome_elf/third_party_dlls/hook.cc` installs the section-mapping hook;
`sandbox/win/src/service_resolver_32.cc`, `PerformPatch`, constructs this WOW64
12-byte stub and uses WriteProcessMemory for AllowLocalPatches. Wine's existing
kernelbase WriteProcessMemory does temporarily authorize writes to executable
image pages with NtProtectVirtualMemory, then restores their old protection.
This is a supported memory API operation, not a reason to disable the hook.

The source reveals a translation-specific gap. After the temporary protection,
running guest code can recompile a block on the same guest 4 KB page.
`MarkGuestExecutableRange -> ReprotectRWXIntervals` removes its write bit to
arm FEX's self-modifying-code trap. A translated store would enter
HandleRWXAccessViolation and invalidate/untrap it. Madeira's native self-writer
checks logical permission before issuing any store, so it cannot take that
fault. The trace shows the SMC interval immediately before rejection, but does
not record the intervening protection calls; the exact on-device ordering is
still to be validated.

The maintained Madeira overlays add an optional checked native-write entry
point to the WOW64 CPU backend. The WoW64 wrapper uses it only for the current
logical process, with the already translated host address. It holds the
existing thread-creation and code-invalidation locks, invalidates/untraps only
tracked guest-writable SMC intervals, and calls the existing native
NtWriteVirtualMemory. No handle is replaced with a self handle. The native
writer still enforces VM_WRITE rights, owning PID/window, committed per-4-KB
permissions, guards, readable source and valid RW storage or existing alias.
Foreign and native process writes retain their existing paths.

The tracker now removes a stale writable-code interval when the guest restores
RX, and excludes guard pages. Without this revocation, a later write could
incorrectly revive old writable permission. Guest permissions remain 4 KB;
iOS's 16 KB page is not used to authorize a sibling page. Existing RX/RW aliases
and protection machinery perform the storage/protection operations; the patch
adds no native RWX mapping. The ARM64EC CPU backend and CS2 launch paths are
unchanged.

`check-wow-code-write.py` compiles the staged production entry point, protection
notification and interval operations, using FEX's actual interval-list
algorithm. It reproduces the old rejection after successful temporary protect
and an SMC re-arm, then verifies the 12-byte write succeeds. It also checks RX
revocation, guards, a read-only sibling, source/protect failure propagation,
unchanged native handle checks, ClipCursor, lock release and compilation
exclusion. The separate native self-writer test exercises actual shared RO/RW
aliases. These are host-verified compatibility fixes; their effect on Steam
startup requires the new IPA on the device.

## Fatal breakpoint and distinct CEF diagnostic

### Additional confirmed query-origin bug

Crashpad's public `ProcessInfo::ReadMemoryInfo` starts VirtualQueryEx at address
zero, collects regions, then tests snapshot ranges against that map. Its
`LoggingRangeIsFullyReadable` emits the observed `process_info.cc(620)` messages
when the recorded map contains no readable overlap. Those messages alone do
not establish that ReadProcessMemory failed; the current run has no
`[wow-read-failed]` record for them.

The WoW64 query wrapper used the ordinary NULL-preserving pointer converter
for its address argument. A query for address zero therefore reached native
NtQueryVirtualMemory as host NULL, even when the target had a guest window.
Native logging in this capture includes a map walk starting at host zero and
the iOS mapping floor 0x100a94000. This is not the guest's address map. The
first host reservation exceeds the guest's entire user range; clipping it to
that range can make an enumerator skip the guest heap completely (or truncate
to a zero-size region with a full 4 GB limit). The untagged host map lines do
not prove which guest caller initiated them.

The query overlay now maps address zero to the target window's origin for
actual memory-query classes only. Special Wine load/unload classes and all
optional-pointer/sentinel converters retain their semantics. Nonzero query
addresses, native targets, handle checks and process isolation are unchanged.
`check-wow-query-zero.py` executes the actual staged BasicInformation branch,
reproduces the old skipped-heap result, then verifies self and cross-process
enumeration reaches the readable guest heap. It checks limits, denied queries,
buffer lengths, error state and the 12-event query diagnostic budget. The
final IPA validator requires the query marker in the rebuilt WOW64 DLL.

This is a source/host-test verified API fix. Its connection to Crashpad's
observed unreadable ranges and deliberate trap still requires device evidence.

### Trap and symbol evidence

The fatal event is in the `--type=crashpad-handler` child PID 0088, thread 00d8,
not proof of total browser PID 0064 failure. At guest libcef+0x308def3 the bytes
are `cc 0f 0b cc cc`: a deliberate INT3 followed by UD2. Saved EIP is one byte
later, as expected. Wine successfully installs the exception context and
dispatches the breakpoint at 0x6df3def3. The initial SEH chain has ntdll+0x64c50;
at termination the chain is exhausted (ffffffff). A successful context install
does not mean an application handled the exception. Termination after an
unhandled explicit trap is normal Windows exception behavior. There is no
evidence here that skipping it would be correct.

Actual EBP return RVAs: 82553a9, 825557a, 8250e49, 75775eb, 825086a,
7577514, 75774ad, 14abed7. These remain unnamed without matching symbols.

The browser's earlier `check.cc(376): Check failed: false` has a different
chain: df45d7, df41c2, 592fcdb, 592f88d, 592f9b8, dfce39, df49b5, 8e4527.
In the public 126 source, this generic file/line is
NotReachedError::TriggerNotReached, whose official-build message explicitly
omits the original NOTREACHED message. This explains why the log alone does
not name the subsystem; it does not symbolicate Valve's callers or prove that
the two events have a shared cause. The browser continues into HWND creation.

Captured exact target identity:

```
libcef.dll SizeOfImage=b42a000 timestamp=66956fee checksum=0b24e70a
libcef.dll.pdb GUID=4D133C5B4FBE41474C4C44205044422E age=1
```

An exact-GUID request to the CEF symbol server was attempted; this execution
environment's network proxy refused the destination (CONNECT 403). An
independently obtained public NuGet CEF runtime 126.2.18 has the same timestamp
but SizeOfImage=b17b000 and PDB GUID=DC20AF513EC89CEF4C4C44205044422E, age=1.
It contains no PDB. It was rejected as a symbol match and is neither installed
nor packaged. Exact-build symbolication and the originating fatal condition
remain unresolved, rather than assigning names from a different binary.

Bounded executable-only byte windows around the eight real EBP returns are
now captured for the first CEF assertion/breakpoint events. They provide the
actual call/branch context for subsequent disassembly without broad memory
dumps, string scans or private stack data. No trap is skipped and no assertion
is disabled.

## UI and independent helper failures

The win32u driver traces actual HWND creation, parent/owner, ShowWindow, style,
SetWindowPos and surface ownership. UIKit traces layer attachment/visibility
and the first eight presentation outcomes per observed Steam HWND. In this
run, the bootstrap has real contents; PID 0064 creates Chrome_WidgetWin_0 at
1056x486 without WS_VISIBLE, and no successful visible CEF frame is recorded.
The source follows Wine's visibility decision. This does not establish that
Chromium rendered a main browser frame which the compositor discarded.
Browser readiness and the first rendered Steam login/library window remain
unproven. Forcing this hidden HWND visible would conceal the missing stage.

The 32-bit OpenGL helper fails with c0000135 because no compatible SDL2.dll is
found in the inventoried Steam paths. The installed i386 SDL3.dll is a different
ABI. The 64-bit helper succeeds. Both Vulkan helpers launch and exit 1; that
does not prove their failing operation, or a dependency on CEF's failure.
No replacement DLLs or invented graphics capabilities are introduced.

The guard warnings are independently understood at the failing boundary:
several PAGE_NOACCESS requests address the final 4 KB of a live, owned FEX
code carve. NtProtectVirtualMemory returns c000000d because the carve has no
Wine file_view; the host page is 16 KB, with 0x3000 bytes of executable prefix.
Protecting that whole host page would revoke live code. Other sampled 4 KB
guards on normal Wine views succeed while a host-page prefix remains writable.
The remaining alignment/ownership fix is open; warnings and clean pool scans
are retained. The new patch does not claim to repair these guards.

## Validation and next device acceptance

Portable host checks pass with ASan/UBSan. The complete embedded suite needs
Swift/macOS and is run in GitHub Actions, followed by compilation and final
IPA checks. Packaging now requires matching rebuilt Wine consumer/FEX writer
exports as well as existing IOSB, checked-thread-init and breakpoint markers.
The stagers restore exact pinned Wine/FEX inputs and reject concurrent edits.

New diagnostics are bounded: 12 zero-origin queries per WOW64 module,
24 kernelbase 5/12-byte calls, 24 tagged native
code-protection transitions, 32 small backend writes, and eight executable
callsite windows per already bounded assertion/trap event. On the next run,
confirm the 12-byte ntdll hook status and bytes, old-protection restoration,
continued successful ClipCursor writes, and whether Chromium advances to a
visible login/library frame with input. Retest helper churn, cleanup, pool
integrity and CS2 launch. No on-device improvement or absence of regressions
from this candidate is claimed before that evidence exists.
