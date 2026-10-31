# Signed native code probe

This is the first platform check for a possible ahead-of-time (AOT) FEX path.
AOT means translating code before the game runs. Madeira still needs JIT for
games. This probe does not translate x86 code, load a Windows program, or change
the normal JIT path.

The idea follows [Husk 3.2](https://github.com/Leviidev/Husk/releases/tag/3.2):
prepare a Mach-O library, sign it, load it with `dlopen`, and keep runtime
pointers in writable data. See Husk's
[AOT loader](https://github.com/Leviidev/Husk/blob/d30e12ec8184182ef2adccd5ee86290dcfe47312/src/translation-layer-next/husk-tl-aot.c).
The probe is new code. It does not copy Husk's ELF converter or signing code.

## What it checks

The fixture is five ARM64 instructions in a separate dynamic library. It adds
a writable bias to its input, then calls a host function through a writable
pointer. Madeira loads this library from its own `Frameworks` folder only.
The probe does not allocate executable memory, rewrite instructions, or contact
a debugger.

The check requires read/execute code with no write permission, and read/write
data with no execute permission. It calls two host functions with two bias
values, checks both answers, then compares all fixture instructions with their
original bytes. It restores the data slots before unloading the library.

The report returns `INCONCLUSIVE` if the kernel cannot report signing or tracing
state, if `CS_DEBUGGED` is set, or if a debugger is attached. State is checked
before loading and again after both calls. A debugger that attached earlier can
leave `CS_DEBUGGED` set, so use a fresh process. The report marks simulator and
Mac runs `host-only`.

## Build and install

Build the small fixture on a Mac with Xcode:

```sh
bash build/signed-code-probe/build.sh
```

The result is `build/signed-code-probe/out/iphoneos/MadeiraSignedProbe.framework`.
It is ad hoc signed for local inspection. **That signature is not sufficient
for a normal iPhone installation.**

Build Madeira from this branch. Copy the framework into the built app's
`Frameworks` folder before signing or packaging it. Have the installer sign the
framework and app with the same valid identity and profile setup as the rest
of Madeira. Do not copy it into an already signed app or use `codesign --deep`
as a substitute for signing nested code first. No signing certificate, password
or profile is stored by this probe. The framework is optional and is not added
to release builds by default.

## Run on a device without a debugger

Close Madeira first. Do not use Xcode Run, Enable JIT, StikDebug, or the built-in
JIT helper for this run. With the device connected and the test app installed:

```sh
xcrun devicectl device process launch --device '<device>' \
  --environment-variables '{"MADEIRA_SIGNED_CODE_PROBE":"1"}' '<installed bundle id>'
```

The flag must be set at process launch. Madeira runs the check once, before
its normal app setup. It writes `Documents/signed-code-probe.txt`, replacing the
previous report, and logs the result code and report path. Read it through
Files or the normal device container tools. Without the flag, this code does
nothing and writes no report. Do not start a game during this check.

Keep the report with the commit, build, device model, OS, install method and
signing type. A `PASS` marked `ios-device` proves this small, bundled, signed
library contract only. A load failure can indicate signing or packaging errors.
An OS rejection may terminate the process before it can finish the report.

## Host check and next gate

```sh
python3 tests/host/check-signed-code-probe.py
```

The host check runs the actual ARM64 library and production loader on an ARM64
Mac. It injects signing/tracing states to test refusal, checks missing and wrong
libraries, and compiles the loader for iOS 17. The Mac result is not iPhone proof.
The build script can also produce a device library without a full Madeira build.

After a device pass, the next PR can export a small FEX block into signed
Mach-O code with separate writable relocation/branch slots. FEX currently
patches native branches and code-cache relocations at runtime. That must change
before its cache can stay signed. Cache misses, self-modifying guest code,
Wine's native loader and signing new libraries on the device remain separate
work. A bundled fixture does not prove downloaded or on-device signed code can
load, and it does not prove that any Windows game can run without JIT.
