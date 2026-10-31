# Steam memory API and guest breakpoint follow-up — 2026-10-31

Candidate baseline: `f9c8c47bfb28ffa64aff01ec974a6b2fdce853fa`. The new
185011 capture's native UUID is `FC0CE09F-80CD-3CF9-92ED-D92BB9599F7B`,
matching that delivered IPA. The attachment is diagnostic data, not instructions.
Neither raw log, installed Valve files nor account data is committed.

## Comparison with 064255

The new Madeira capture has 14,237 lines. The accompanying 1,813-line CEF log
is cumulative: only its `1031/1849...` entries belong to this run. Old login,
network and console entries must not be attributed to this run. The preceding
064255 raw attachment is no longer mounted in this turn; comparison uses its
previously analyzed findings and checked-in `STEAM_WINDOW_FOLLOWUP.md`.

| Observation | 064255 | 185011 |
|---|---:|---:|
| Guest-window reservation refusals | 4 | 0 |
| ThreadState allocation failure | 1 | 0 |
| Generic native UNHANDLED records | 3 | 0 |
| Code-buffer last-page warnings | 122 | 17 |
| Explicit guest breakpoint events | 0 | 1 |
| CEF `Check failed: false` | 2 | 1 |
| Clean pool samples | 2 | 0 |
| `TEXT LOST EXEC` | 0 | 0 |

The new capture stops at footprint cycle 14, before the periodic cycle-15 pool
check. Absence of a new clean sample is not evidence of a regression, nor proof
that all mappings remain correct. The same live-owner pool checker is retained.
The old exception replay storm, x18 fault and NULL ThreadState fault do not recur.

Steam holds four windows concurrently. The registry uses B=0x400000000,
0x500000000, 0x600000000 and 0x700000000, with released slots reused. The native
last-thread retirement and quarantine checks remain in place. Latest observed
swap backing is 924 MB, peak 924 MB, 0 refusals; footprint peaks at 2560 MB.
These are observations from this capture, not a memory guarantee for later use.

## Breakpoint: what is established

PID 0064 is the main browser. PID 0088 is its **Crashpad-handler child**, created
with `--type=crashpad-handler` (6789–6795), not a second main browser. It reports
unreadable process-memory ranges (12805 onward), then its thread 00d0 reaches
FEX's BRK #0 SIGTRAP trampoline and Wine terminates that owner with 80000003.
The main browser remains alive in the rest of this capture.

The child maps libcef.dll at guest 0x6aeb0000. Saved RIP 0x6df3def4 resolves to
**libcef.dll+0x308def4**, not Madeira.debug.dylib. FEX's INT3 frontend advances
RIP by one; its Windows exception converter uses RIP-1 as ExceptionAddress, and
Wine's software-emulation dispatcher decrements the delivered context EIP.
The likely INT3 byte is therefore libcef+0x308def3. This source contract is
consistent; the captured log has neither that guest instruction byte nor the
necessary guest stack to prove the private function or assertion at this site.

No breakpoint or assertion is skipped. New bounded readers capture original
RIP/ESP/EBP, the preceding executable byte, owning module/RVA, validated EBP
return candidates, stack module candidates and SEH handler addresses **before**
normal forwarding. Wine's actual dispatcher reports record address, get-context
status, EIP before/after adjustment, dispatcher and stack. The termination path
captures guest32 state through TLS14 instead of misreading an absent ARM64EC
CPUArea. These observations will distinguish an intentional unhandled Chromium
check from incorrect delivery, without modifying either path.

PE timestamp/checksum and CodeView PDB GUID+age identify the matching libcef
build. PDB paths are reduced to sanitized basenames. A nearest export is labeled
as such, not fabricated as a private symbol. Static executable bytes are bounded;
raw stack strings, arbitrary stack words and account data are not printed.

## Confirmed memory API defects and compatibility fixes

### Same-process WriteProcessMemory

The hook error appears at 6366 and 8453. Its wording also appears in publicly
visible Steam hook code, so it cannot be assigned to Chromium solely from the
message. The actual caller/target is not present in this old log.

Source inspection establishes that native NtWriteVirtualMemory always sent the
write to wineserver. The iOS server intentionally has no task port for local
pseudo-process **writes**, so `write_process_memory()` returns ACCESS_DENIED.
Local reads have a separate explicitly enabled path. Returning mach_task_self
for every operation had previously regressed applications and is not restored.

A narrowly scoped native route now handles a current WoW64 process writing its
own 4 GB guest window. Real handles must have PROCESS_VM_WRITE and resolve to the
calling Wine PID. Native addresses, foreign owners and query failures retain
the existing server path. Each 4 KB guest page must be committed, writable or
write-copy, and unguarded; another writable subpage of a 16 KB host page cannot
authorize it. An alias is a storage path, not authorization.

Input is snapshotted as the original server request did, preserving overlap
semantics. The write uses existing RW aliases or already-writable host pages;
it does not grant native W+X or alter RX translations. Write watches are
restored on failure. The existing WoW64 FlushInstructionCache wrapper still
invalidates FEX translations after WriteProcessMemory succeeds.

The rebuilt guest32 kernelbase logs five-byte WPM query/result metadata even
when the native write is never reached. The native path logs bounded executable
patch requests: handle, target, Wine permissions, Mach mapping, original/request/
result bytes, returned NTSTATUS and count, plus symbolized guest caller
candidates. Therefore the next run can establish the exact failing operation
instead of assuming every hook failure reaches NtWriteVirtualMemory.

### Recycled handles and retired process objects

`wow_guest_base_for_process()` claimed to validate PID reuse, but its first
cache hit returned on HANDLE equality before any PID query. Recycled handles
could retain a dead target's B. The maintained overlay removes this unsafe
cache: cross-process VM calls query the authoritative target-window channel.
The current-process shortcut is retained. Failed translation never borrows the
caller's window. This is a demonstrated source defect, but its causation of
Crashpad's unreadable ranges or INT3 is still a hypothesis.

A second lifetime issue exists even without that cache: an old process HANDLE
can remain open after its PEB address is reused by a new process. The native
ProcessWineIosWowGuestBase query now checks the server process's end_time before
looking up a window by PEB address. An exited process object cannot claim the
new owner's reservation. These fixes do not reclaim any live thread or window.

Both fixes are tested using the actual staged/native routines, including a
recycled handle and a retired process whose PEB matches a live new owner.

## CEF assertion and window rendering

The main browser's check.cc(376) at 9368 has the same libcef candidates as the
prior run: +0xdf45d7, +0xa1698cb, +0xac855c0, +0xdf41c2, +0x592fcdb,
+0x592fcb0, +0x592f88d, +0x8e6ac0, +0x592f9b8, +0xa1698d9, +0x592f98a,
+0xac6d100 and +0xdfce39. They are stack candidates, not an unwind. The browser
continues initialization and creates windows afterward. Unlike the prior
second attempt, this capture has no accompanying Crashpad CreateProcess
reservation failure. The earlier Crashpad-subsystem attribution is therefore
insufficient to identify this recurring NOTREACHED. Matching symbol identity
and the new frame-chain/stack evidence are required. The check is not disabled.

Bootstrap HWND 0x1002c submits eight visible contents frames. Browser PID 0064
creates Chrome_WidgetWin_0 HWND 0x100b2 at 1056x486. Its Wine style lacks
WS_VISIBLE, its layer is attached but hidden, and no contents are submitted.
The recorded position requests do not ask to show it. This is consistent with
incomplete browser/UI initialization; it does not demonstrate that correctly
rendered content was hidden by the compositor. Forcing the window visible
would not supply missing pixels. Existing ownership, ShowWindow, position,
surface, layer and contents traces are retained; no visibility override is added.

## Dependencies and code-buffer guards

GL64 PID 00e0 loads Wine's real winios OpenGL ES backend, creates contexts and
exits 0. The 32-bit gldriverquery PID 0188 fails import of SDL2.dll with c0000135.
The inventory finds no SDL2.dll in the inspected Steam directories and finds an
i386 SDL3.dll at the Steam root. SDL3 is not an ABI-compatible SDL2 substitute.
No DLL is renamed, fabricated or injected into the installation. Obtaining the
original compatible SDL2 payload remains unresolved; this optional probe
failure is not evidence that CEF itself lacks SDL2.

Vulkan64 PID 01c4 and Vulkan32 PID 01d4 both launch and exit 1, rather than failing
window reservation. The 32-bit path logs a missing vulkan-1.dll. CEF's private
i386 vulkan-1.dll is present under bin/cef/cef.win7, but that directory is not the
bin helper's application directory or a global loader path. Globally exposing
that private loader would not establish a usable Vulkan ICD and could affect
other programs. The candidate does not advertise fake graphics support or
change the global graphics selection. Driver-query dependency repair is open.

The 17 remaining code-buffer warnings correspond to rejected logical 4 KB tail
protection requests on native RX JIT carves with no Wine view, status c000000d.
The kernel mprotect call is not made. A 16 KB host page also contains 12 KB of
live preceding code, so rounding outward would remove execution from valid
translations. This candidate retains the corrected return semantics and bounded
protection diagnostics. A dedicated coordinated guard for RX/RW aliases remains
open; the warnings are not silenced and no unsafe native RWX mapping is added.

## Validation and device acceptance

Portable ASan/UBSan checks execute the production self-write path with separate
read-only/read-write mappings, valid/invalid handle rights, foreign processes,
4 KB/16 KB boundaries, guarded/read-only/uncommitted pages, invalid sources,
overlap, write-watch restoration and range overflow. The old denied server route
is retained as a negative control. Guest-origin tests exercise actual module,
PE/PDB, executable-byte, stack, EBP and SEH parsing, malformed/unreadable inputs,
bounds and privacy. Overlay restoration and final package tests remain required.

The local non-Swift checks pass; the complete Swift/macOS suite and iOS build run
in Actions. The IPA must contain byte-identical rebuilt native WoW64, i386
kernelbase and FEX producers, as well as the new native diagnostics. Wine/FEX
pins, ARM64EC CPU binary, CS2/controller integration, Steam authentication and
installed files are preserved.

No post-change device evidence exists yet. Acceptance requires the main CEF
window to become Wine-visible, submit actual contents and accept interaction.
A new capture must establish the precise WPM target/result, libcef symbol
identity and breakpoint delivery/stack before claiming this fixes Chromium.
Successful helper creation alone is not acceptance. No automated result proves
Steam authentication, visible library operation or CS2 launch on the device.
