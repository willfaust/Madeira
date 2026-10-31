# Signed FEX program execution

For the later signed Wine DLL loader and Windows import workload, see
[SIGNED-WINE.md](SIGNED-WINE.md). It records separate host and device results.

This builds and runs a complete, freestanding x86-64 Windows PE program using
FEX-generated ARM64 code in a signed Mach-O library. All translation happens
on the Mac. The device package contains no FEX compiler and has no JIT fallback.

This is an experimental execution path. The original test program described
here has no Windows imports. The later Wine workload uses ARM64EC entry thunks
and callbacks. Neither path runs a normal Windows game yet. The regular Madeira
game path still uses JIT.

## Included work

- A host exporter uses Madeira's exact, unmodified FEX pin. It maps the guest
  image and compiles every decoded instruction start before packaging. Its
  allocation hook removes execute permission because the exporter never runs
  generated code.
- The preparer replaces FEX's runtime linker-pointer loads with loads from the
  writable CPU frame. Direct exits read immutable exit records. Indirect exits
  use a sorted guest-to-native table. Neither path patches signed instructions.
- An ARM64 bridge transfers general registers, SSE registers, flags and stack
  state between the host and translated blocks. The optional platform register
  pass remaps x18 to unused x25 before signing and checks assembler round trips.
  A conflicting x25 use fails preparation.
- The loader checks the bundle format, entry table and native code permissions.
  It reserves its guest mapping without replacing any existing mapping. Guest
  text becomes read-only. Guest data and stack have no execute permission.
  An untranslated address stops the run with an error.
- Six runs compare complete program results with native builds of the same C
  source. They cover recursive quicksort, two CRC passes, 4,096 indirect calls
  per run, integer arithmetic, stack/memory access and floating-point matrices.
  The loader compares all translated bytes after every run and checks signing
  and debugger state before and after the group.
- The device guest uses the same production loader as Madeira. It writes a
  report, shows it in a native text view, and records a hash of the source set.

## Build

Use an ARM64 Mac with Xcode, CMake, Ninja, the FEX dependencies and llvm-mingw
already present. Use a dedicated host build directory. Do not point this at an
active iOS or Windows FEX build directory. The script does not clone or download
dependencies. The FEX source must be clean and match Madeira's submodule pin.

```sh
bash build/signed-fex/build.sh \
  /path/to/pinned/FEX \
  /path/to/dedicated-fex-macos-build \
  /path/to/llvm-mingw/bin \
  /path/to/Madeira-Signed-FEX.ipa
```

The host build disables the call-return predictor and telemetry. No FEX source
is changed. The script builds only the required FEX libraries, exports the PE,
runs the full workload on the Mac, and packages the iPhone guest. The host tools
currently use the existing Homebrew xxHash library at `/opt/homebrew/lib`.

The output IPA is ad hoc signed for preparation. Import it into a configured
LiveContainer, which must sign the app and its framework. Launch **Madeira
Signed FEX** with JIT disabled. The result is in its `Documents/signed-fex.txt`.
Its `source-info.json` records source and translation hashes. A host pass is
not a device pass.

Verified on 2026-10-30: all six runs passed on an iPhone 15 Pro, iOS 27.0.1
(24A446), inside LiveContainer 3.8.11 with JIT disabled. The bundle contained
443 native entry mappings and a 119,276-byte translated buffer, including
block metadata. It completed 202,439 block transitions and matched all native
results. The code buffer stayed unchanged. Before and after execution,
`cs-flags=0x22003305` had `CS_DEBUGGED` clear and `traced=0`.

The tested source-set ID was
`a85a23401e3261943cd82110ca3de80f1fa063220ddb10044a8a9b1d19e447c8`.
Reported times cover translated dispatch only. They exclude preparation,
signing, app startup and the native reference calculation. They are not game
performance measurements. The full Madeira app build remains untested.

## Madeira integration

The optional startup flag `MADEIRA_SIGNED_FEX=1` runs the same loader in Madeira.
First include the prepared `MadeiraSignedFEX.framework` in the built app's
`Frameworks` folder and sign the nested framework with the containing app.
The report is `Documents/signed-fex.txt`. Without the flag, this path does
nothing. No game is started and no debugger is requested by this path.

The current guest base is `0x130000000`, below Madeira's reserved main-image
window. A collision fails without releasing or replacing the existing region.

## Boundaries for the next runtime change

The original bundle has a fixed program, ABI, image base and set of native
helpers. It supports precompiled basic blocks and refuses missing translations.
It does not support dynamic code generation, self-modifying code, signals,
exception delivery, threads, runtime DLL loading or Wine calls. The ELF/Mach-O
host compiler build also differs from Wine's ARM64EC FEX build. Its generated
blocks cannot be substituted into that module without an ABI adapter.

Wine integration must handle those interfaces and load additional code through
signed images. A successful workload run does not establish game compatibility,
standalone iOS signing support, or production performance.
