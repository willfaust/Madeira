# Signed Wine libraries and translated PE imports

This adds a signed native-library path to the earlier fixed-program FEX runner.
It prepares real Wine ARM64EC PE libraries as Mach-O frameworks. An x86-64
Windows PE can call selected exports in those frameworks without a runtime
compiler. It does not yet boot a complete Wine process or run a game.

## What runs

The Windows workload imports `RtlComputeCrc32`, `RtlCompareMemory`, and
`RtlMoveMemory` from `ntdll.dll`. It fills and checks buffers, copies memory,
checks deliberately changed bytes, and accumulates CRC results. The native
reference uses separate portable C implementations.

The translated x86-64 program passed six input cases on an ARM64 Mac. It made
3,072 calls into the actual Wine DLL across 9,996 translated block/import
transitions. All six results matched. Both the translated code and native Wine
code stayed unchanged. The signing/debugger checks passed before and after.

A separately compiled ARM64 Windows PE also passed eight complete runs with
its import table bound to the same signed Wine library. Eight additional
one-MiB copy/compare/CRC passes checked Wine's native exports directly.

The host loaded signed wrappers for `ntdll.dll`, `kernelbase.dll`, and
`kernel32.dll`. Their 459, 1,116, and 1,878 absolute data pointers were prepared
for dyld rebasing. No native instruction bytes were changed. Loading the latter
two libraries is not proof that their imports or Windows initialization work.

The translated x86-64 workload also passed on an iPhone 15 Pro running iOS
27.0.1 in LiveContainer 3.8.11 on 2026-10-31, launched with `jit=false`. All six
results matched across 9,996 block/import transitions and 3,072 calls into real
Wine ntdll. The signed Wine image reported 459 data fixups, RX native code and
RW/NX data. Both translated and Wine instruction bytes stayed unchanged.
Before and after, `cs-flags=0x22003305` had `CS_DEBUGGED` clear and tracing was
known with `traced=0`. This run did not attach a debugger or enable JIT.

The tested package targets iOS 17. Its source-set ID is
`b52dc65c5dce1bb7768e70d74d8165b95fb4178b7e580be9f3df128360ca30a8`.
Physical proof covers this workload through LiveContainer's signing/loading
path. The native ARM64 Windows PE, Wine image lifecycle check, and kernelbase
and kernel32 loading results above remain host-only. Earlier physical proof in
`SIGNED-FEX.md` applies to the earlier import-free workload.

## Native library preparation

`build/signed-pe/prepare.py` maps PE sections to their original relative virtual
addresses inside a Mach-O library. Executable sections are RX. Non-executable
sections are RW and never executable. DIR64 pointers in data are expressed as
Mach-O rebases, which dyld resolves without changing signed instructions.

Preparation rejects unsupported machines, plain x86-64 images, overlapping or
invalid sections, writable executable sections, executable sections after data,
unaligned code/data boundaries, external absolute relocations, and relocations
inside native code. The last two restrictions require offline rewriting rather
than runtime patching. In particular, the existing 4-KiB-aligned FEX DLL cannot
be wrapped unchanged by this preparer.

The loader validates the descriptor, code hashes, section bounds, and actual VM
permissions. Export resolution applies ARM64EC redirects and checks that the
target belongs to a native ARM64EC code range. The optional native import-table
binder refuses missing exports, forwarding exports, and delay imports.

## Wine integration

The new code is part of `libntdll_unix.a`. Before Wine starts, set
`MADEIRA_SIGNED_PE_DIR` to the directory that contains its prepared frameworks.
The option is off by default and is captured at the first image load.

In that mode, Wine's original PE views remain non-executable data. After an
image is mapped, the loader finds its signed counterpart by executable content
hash and registers an alias. Existing address translation and data-update paths
use that alias. Relocated data and import addresses are translated into the
signed image. Code-write requests fail. Missing or incompatible prepared native
libraries fail the image load. Unmapping an image removes its alias.

Address translation and code-range checks use published atomic values, without
locks, allocations, or environment reads in fault handling. Data updates run in
the normal loader path. Protection changes from Mach fault handling are refused
in signed mode. The host lifecycle check covers map, pointer rebasing, data
update, immutable code, duplicate-instance refusal, and unmap.

This does not replace Wine's FEX module. Enabling the native-library option alone
does not make the normal Madeira game path JIT-less. The translated program's
three typed import bridges are not a general ARM64EC call adapter.

`MADEIRA_SIGNED_WINE=1` runs the same combined workload from Madeira's startup
path. Include the two prepared frameworks and set the app's
`MadeiraWineFramework` Info.plist value to the native Wine framework's directory
name. The option runs the workload only; it does not start Wine or a game.

## Build and prepare

Reuse a clean FEX source at Madeira's pin, the matching host FEX build described
in `SIGNED-FEX.md`, an existing llvm-mingw toolchain, and an existing Madeira
checkout with its pinned Wine and tracked native DLLs. No download or clone is
performed. The script checks the Wine pin and refuses changed DLL inputs.

```sh
bash build/signed-pe/build.sh \
  /path/to/pinned/FEX \
  /path/to/matching-fex-macos-build \
  /path/to/llvm-mingw/bin \
  /path/to/existing-Madeira-runtime-checkout \
  /path/to/Madeira-Signed-Wine.ipa
```

Outputs stay in `build/signed-pe/out`. The script builds both host workloads,
checks their results, prepares iOS libraries, and packages the same runtime
sources into an IPA. It does not install or launch anything on a device.

The package includes Wine's LGPL license and its source provenance notice.
LiveContainer still needs to sign the guest and both nested frameworks before
execution. The report remains `Documents/signed-fex.txt` and records the source
set. A prepared or signed package is not runtime proof.

## Remaining work

- Full Wine bootstrap, syscall dispatch, thread-local state, and library init.
- A general x86/ARM64EC transition adapter, callbacks, exceptions, and threads.
- Multiple prepared guest modules, relocatable guest addresses, and missing-code
  handling. The translated workload still uses the earlier fixed image base.
- Independent writable library instances for concurrent Windows pseudo-processes.
  The current loader rejects a second live instance of the same signed library.
- Forwarding and delay exports/imports where the standalone binder is used.
- The full Madeira app build, standalone iOS installation, game support, and
  sustained performance measurements.
