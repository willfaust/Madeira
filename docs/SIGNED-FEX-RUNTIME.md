# Signed FEX runtime API

ABI 4 adds a reusable ahead-of-time (AOT) runtime. A CPU context is a saved set
of registers and flags. This API accepts Wine's x64 context layout, an existing
Windows image, its thread context, and its stack. It does not create a Wine
process. Normal Madeira game startup still uses JIT.

## Current evidence

These results are from an ARM64 Mac. The ABI 4 changes have no phone execution
proof. The earlier ABI 3 LiveContainer results in `SIGNED-WINE.md` remain
separate.

- Six Windows workloads passed with real Wine imports and callbacks from
  caller-owned contexts and stacks. macOS chose the image address. One input
  stopped and resumed 18 times and still matched its reference result.
- A separate EXE and DLL passed six more inputs. Wine called the DLL's x64
  comparator, and the comparator called Wine again. Both modules had separate
  mappings. Their signed instructions stayed unchanged.
- Native Wine also initiated x64 DLL callbacks before any FEX frame was
  active. Four bound host threads completed 2,048 inserts, duplicate lookups,
  ordered enumeration and deletes. The x64 comparator called Wine again.
- The CPU-state checks passed 256 flag combinations, x87 register retention,
  XMM register retention, four SSE rounding modes, forward and backward string
  copies, NaN payload retention, floating-point status, and flags across a stop
  and continuation. Host rounding and NaN settings were restored.
- The x64 CPUID instruction returned the 21 nonzero query records exported
  from the pinned FEX CPU model. XGETBV used the same model's XCR0 value.
- Seven indexed vector tables are included as signed read-only data. All 256
  controls passed for each of PSHUFLW, PSHUFHW, PSHUFD, SHUFPS, PBLENDW, DPPS
  and DPPD: 1,792 vector results matched.
- Four host threads used separate contexts and stacks. Adding a module during
  another thread's run passed. Closing an active runtime was refused.
- Missing guest dependencies failed before execution. Guest traps and unbound
  runtime helpers returned explicit errors. These are refusals, not Windows
  exception delivery.
- Ordinary unaligned 16-, 32- and 64-bit accesses passed at 16 offsets, including
  page crossings. Two guest threads completed 10,000 ordered message exchanges.
- An unknown native-first callback reached the caller's fatal-error handler.
  It did not execute the unprepared target or return a false result to Wine.
  The caller left the failed operation and removed the binding on its original
  stack. Removing an emulator stack still in use was refused.

These host threads are not Wine's Windows thread lifecycle. The workloads
still use the standalone TEB/PEB fixture where Wine functions need one.

## Prepare code before signing

`build/signed-fex/prepare.py` can compile a reference workload or accept an
existing pure x64 PE with `--pe`. It uses Madeira's exact, unmodified FEX pin.
It rejects ARM64EC mixed-code images, writable executable sections, native
thunks without a binding, and guest text relocations. Use `signed-pe` for
native ARM64EC libraries. It also rejects overlapping sections and guest code
that shares a 16-KiB page with writable data. Such images need another offline
layout step. An existing PE that prepares successfully is not process-boot proof.

The exporter enables FEX's padded relocation sequences. It replaces guest
address moves with a load of the current module base and relative additions.
Direct exit records hold relative addresses. All rewrites happen before
signing. No signed instruction changes when its guest address changes.

FEX prepares integer, vector and string memory operations with its software
x64 memory-ordering options enabled. Before signing, the bundler converts
padded ordinary acquire/release accesses to plain loads/stores and barriers.
This uses FEX's reserved instruction slots and removes runtime code repair for
those unaligned accesses. The current import workload has 204 such rewrites.
Locked or split atomic operations and arbitrary hardware faults still need the
Wine fault adapter; these checks do not establish a complete x64 memory model.

`bundle.py --name Name` gives each module its own framework identity. The
framework includes a hash of guest code and a fingerprint of the frame layout
and CPU profile, public ABI, and bridge implementation. Modules with different
fingerprints cannot share a runtime.
The fingerprint also includes the 20,800 bytes of indexed vector constants.
The exporter is built once in `build/signed-fex/out`. Its cache checks source,
compiler, generated headers, build flags, and static-library hashes.
Preparation publishes a hash manifest only after all outputs succeed. Bundling
refuses missing, changed or mixed outputs after a failed preparation.

The current limits are 16 MiB per guest image, 32 MiB of translated code per
framework, 100,000 prepared entry points, and 64 attached guest images. An
address rewrite must fit a signed 24-bit relative offset. Undiscovered or
dynamic instruction starts fail without a JIT fallback.

## Use the existing Windows mappings

`madeira_signed_fex_open()` attaches the first module. It checks signed RX
code, the mapped image size, read-only/NX guest code, and the guest code hash.
It does not map the image or allocate its stack. Wine must finish data
relocations and import binding first.

The import resolver returns 0 for a native target and its ARM64EC entry thunk,
1 for a guest target, or -1 on failure. The runtime records the bound IAT
addresses. A resolver must use already loaded dependencies. It must not call
back into module attachment.

`madeira_signed_fex_add()` attaches another module. The first module supplies
the shared native bridge. Added module records and address ranges are
published with release/acquire atomics. Existing executions can see added
modules. Before a new execution starts, each declared guest import must have a
prepared entry in the attached set.

`madeira_signed_fex_execute()` takes a `MadeiraFEXContext`, the TEB address, the
caller-owned RW/NX stack, a stop address, and a block budget. The context is
binary-compatible with Wine's 1,232-byte `AMD64_CONTEXT` and
`ARM64EC_NT_CONTEXT`. The build checks both Wine layouts.

- Return 0: execution reached the stop address.
- Return 1: execution returned at a block boundary after the budget.
- Return -1: execution was refused. Do not resume that failed Windows process.

Successful and yielded calls update the context. Refusals leave that context
buffer unchanged, but do not undo guest or native memory writes. The budget
does not interrupt a loop inside one compiled block or a running native call.
An active callback may finish past the soft budget, with a separate limit of
20 million further transitions. Callback depth is limited to 64.

Native callbacks use child frames. Each child retains the same thread context
and can enter any attached guest module. Native call checks accept known guest
ranges and verify that other native targets have immutable executable memory.
An unknown non-executable callback returns through the dispatcher and fails.

`madeira_signed_fex_bind_thread()` enables native-first callbacks on the current
host thread. Pass its actual TEB, RW/NX guest stack range and fatal-error
callback. The binding allocates a separate 1-MiB RW/NX emulator stack. The
call checker reads thread-local state instead of assuming x28 holds an active
CPU frame. Calls during execution use that frame; native-first calls use the
bound emulator stack and create a Windows context from the ARM64EC registers.
Nested calls restore the preceding binding, including refusal paths.

Call `madeira_signed_fex_unbind_thread()` on the same thread before it exits.
A second binding on that thread is refused. Its fatal-error callback must stop
the failed Windows thread and must not return. If it returns, the runtime
aborts. Native-first callbacks cannot yield an incomplete result to Wine.
The fatal-error callback receives the incoming callback context. It is not a
resumable Windows fault context.
Unbinding while still on the emulator stack is refused. A fatal-error handler
that uses a nonlocal exit must leave that stack before removing the binding.

The caller must keep all guest mappings and native dependencies alive until
the runtime closes. Keep guest code and its read-only/NX protections unchanged.
Module removal and IAT rebinding after attachment are not
implemented. Serialize final close against new API calls.
`madeira_signed_fex_close()` returns -1 while a run or thread binding is active.

## State and helper limits

The runtime transfers integer registers, instruction and stack pointers,
arithmetic and direction flags, segment selectors, x87 register data and
control fields, XMM registers, and SSE rounding control. It restores the host
floating-point state after each transition.

Hardware debugging and extended XSTATE contexts are refused. Denormal-input
flush mode, unmasked floating-point exceptions, trap flags, and privileged
flag settings are also refused. x87 register transport does not imply x87
arithmetic support: operations that need an unbound helper fail explicitly.

CPUID and XGETBV use the fixed CPU profile from preparation. They do not probe
the iPhone or report its live topology. CPU-model transport is not proof that
every advertised FEX instruction helper is available in this partial backend.

## Wine startup still needs an adapter

Wine's emulator entry, process bootstrap, syscalls, Windows threads, exceptions,
module unload, and process teardown are not connected to this API yet. The
native-first bridge now handles entry without an active FEX frame. The startup
adapter must bind actual Wine threads before installing the global dispatcher,
attach the full prepared dependency set, and connect teardown and errors.

Native Wine libraries still allow only one writable instance per signed
library. The new guest-module API does not remove that native-library limit.
Forwarded and ordinal imports, guest text relocations, dynamic code, arbitrary
hardware faults, and complete unwind metadata still need work. No game or
full Wine process has run through ABI 4.
Native addresses returned dynamically also need a binding if they are absent
from the registered import tables. Native-first entry currently starts with
default x87 control state; Wine's CPU-area state still needs to be connected.

Frameworks include the pinned FEX license notices. The diagnostic IPA also
records FEX and Wine source revisions and includes Madeira's and Wine's licenses.

## Host check

Reuse the pinned sources, toolchain and prepared ntdll from `SIGNED-WINE.md`:

```sh
bash build/signed-fex/check-runtime.sh \
  /path/to/pinned/FEX \
  /path/to/matching-fex-macos-build \
  /path/to/llvm-mingw/bin \
  /path/to/pinned/Wine \
  /path/to/prepared/ntdll.framework/ntdll
```

The check keeps its active outputs in `build/signed-pe/out` and its concise
result in `host-context.txt`. It does not use a phone.
