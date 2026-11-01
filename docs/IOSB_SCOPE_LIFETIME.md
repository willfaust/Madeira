# Native Steam IOSB scope lifetime — 2026-11-01

This follow-up targets the fatal native fault at about 38 seconds in
madeira-log(20261101-213058).txt. Native Steam authentication and UI rendering
remain established progress; Library loading and CS2 launching remain device
acceptance checks, not conclusions from process creation.

## What the captured fault proves

The latest installed native image is UUID
48DC13B4-6D1D-3F79-8F61-91698C978B24, the previous c35da5b candidate.
TID0254 in Steam PID0020 faults at ios_io_status_control+0x154 on
`ldr x8,[x8]`, with x8=0x19efef30. The retained earlier native capture has
UUID E1CA4E18 and the same fault address, guest RSP0x19efe928 and syscall
bridge RIP0x2a0000; its thread is0248. That retained capture corresponds to
the earlier19:51 CEF session. The exact20:57 native attachment is not retained;
the cumulative CEF file includes its20:56 startup, but cannot establish its
native pointer provenance by itself.

The instruction is the ancestor-cycle loop in MADEIRA_IO_ENTER. It walks
`io_scope->previous`; it is not a write through an IO_STATUS_BLOCK pointer.
The current scope cookie is x19=0x17dcfefd0, inside the native TEB stack.
The bad low address comes from an older chain link. The compiler preloads
STATUS_INVALID_PARAMETER before the cycle test: x0=0xc000000d does not prove
an earlier I/O operation returned that error.

Captured guest RAX is0x37. The checked Wine syscall table identifies this as
NtOpenSection, not NtWriteFile. The write-thread name is insufficient to
identify its API. FEX passes the syscall argument block through
GuestWindow::ToHost(ReturnRSP+4); wow64.dll converts embedded guest pointers
with its layout-specific helpers. The current private control packet is
already a native32-byte structure with64-bit host pointers. The guest IOSB
itself is8bytes; the native IOSB is16bytes.

A low32-bit guest RSP is expected in this WoW64 state. The bridge RIP is FEX's
registered syscall trampoline. Neither alone proves truncated native state.
Although 0x19efef30 equals guest RSP+0x608, adding the window base does not
repair a native scope link. The possible host address0x419efef30 was not
proven to be an IOSB, or to have a live allocation, by the old log.

## Source error and focused fix

The old overlay entered a caller-stack IOSB scope around every WoW64 syscall.
NtCallbackReturn can longjmp; NtContinueEx can restore another context. Those
transfers can bypass the C finally block and leave a native TLS pointer into
an abandoned PE stack frame. Later stack reuse can change its link fields.
The exact earlier transfer that corrupted this run's chain was not logged;
this unsafe lifetime mechanism is demonstrated by source and host fixtures.

The version2 overlay scopes only the29 thunks which actually use IOSB
conversion helpers. It selects thunk function pointers, with automatic test
coverage against the real source, rather than special-casing syscall0x37.
NtOpenSection and nonreturning context/callback syscalls create no scope.

Native-owned, bounded TLS records now own all scope links and bindings. The
producer stack address is only an opaque cookie; its fields are never read,
followed or zeroed. Records carry TEB/PEB ownership and monotonic generation.
Input packets use fault-safe native copies. Buffer-rights queries do not touch
memory, allocate mappings or add a guest base. They check complete ranges,
process/window ownership, dead reservations, each Wine VAD/4KB protection,
guards and quarantined stacks. Valid write-copy pages retain normal Wine COW
handling. Native buffers outside Wine VADs require writable Mach mappings.

The private producer and consumer version are both2. Packaging rejects an
old producer, old consumer or mismatched staged/bundled DLL. Existing IOSB
layout capture for delayed completion remains: it survives scope retirement
and does not depend on a producer stack cookie remaining mapped.

Bounded diagnostics record control input, cookie, API, status, native-record
generation, TEB/PEB/PID/TID, CPU-area guest EIP/ESP, stack bounds, window owner
and generation, Wine VAD/protection/quarantine and Mach mapping rights. A
low-pointer candidate is inspected only as diagnostic metadata; it never
changes an execution pointer. Wine views have no separate allocation-generation
field, so the trace reports actual window and native-record generations rather
than inventing a VAD generation.

## Crash artifacts and Library diagnostics

The default crash artifact is fex-jit-crash.txt, under40KB, with native
registers and at most8960 sampled bytes. Invalid pointers use safe Mach copies.
Only MADEIRA_JIT_DUMP=1 or full requests the legacy full sparse pool dump;
0 disables artifacts. Exception delivery and one-shot guards remain unchanged.
Old full dump files are not deleted.

The old Library watcher measured destination-buffer contiguity. Reusing a64KB
buffer for a609050-byte file is normal; off=-1 means current-position I/O.
The replacement records known file-offset interval coverage separately from
unknown current-position bytes, with process/handle/file generations. Neither
byte sums nor reused buffers establish whole-file coverage or corruption.

The previous CEF observer was disabled by an unintended default: the generic
configuration flag fallback is true, including the trace-off flag. The new
observer explicitly defaults that off flag to false and reports startup errors.
It uses passive Runtime/Page/Log/Network events and read-only AppStore queries
with Chromium's throwOnSideEffect enabled. No Steam scripts, native API methods,
callbacks or Promise handlers are patched. Output, inspector buffers and
sampling are bounded; credentials, headers, bodies and raw RPC payloads are
excluded. Opaque SteamClient RPC arguments/results remain unavailable to this
passive observer; console stacks and transport errors must identify the first
failing stage rather than fabricated responses.

The latest21:29 CEF session has no captured Library route or AppStore failure
before shutdown following the native crash. Older08:39–08:41 errors in the
cumulative file are historical evidence, not a new Library reproduction.

## Validation and device acceptance

Host fixtures compile the actual staged dispatcher, controller, completion
publisher and pointer probes. They cover nonlocal continuation/callback return
followed by NtOpenSection, every IOSB thunk, invalid control/cookies, poisoned
links, ownership/generation/depth, raw versus translated guest IOSBs, read-only
memory,4KB rights inside16KB host pages, and delayed completion after a producer
scope is protected/unmapped. Crash and watcher helpers run under ASan/UBSan.
The macOS workflow additionally compiles the actual Swift observer and tests
passive CEF events, configuration defaults and bounded error capture.

On the phone, require Steam to remain alive beyond the original38-second point
with no ios_io_status_control faults, then open the actual Library tab and
export the new native/CEF diagnostics. The existing Steam-client Play option
uses normal steam.exe -applaunch730 with the existing manifest/library checks;
Steam remains responsible for authentication, ownership and game launch.
Neither Library success nor an interactive CS2 session is claimed by host tests.
The changes do not reinstall Steam/CS2, clear authentication or edit game data.
