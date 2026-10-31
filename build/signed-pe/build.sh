#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fex="${1:?Pass the clean pinned FEX source}"
fex_build="${2:?Pass the existing matching macOS FEX build}"
toolchain="${3:?Pass the existing llvm-mingw bin directory}"
runtime="${4:?Pass an existing Madeira checkout with its pinned Wine and PE libraries}"
delivery="${5:?Pass the output IPA path}"
out="$root/build/signed-pe/out"
farm="$runtime/app/Madeira/arm64ec-windows"
[[ -f "$fex_build/compile_commands.json" && -f "$runtime/wine/COPYING.LIB" ]]
expected="$(git -C "$root" ls-tree HEAD wine | awk '{print $3}')"
[[ "$(git -C "$runtime/wine" rev-parse HEAD)" == "$expected" ]]
git -C "$runtime" diff --quiet HEAD -- app/Madeira/arm64ec-windows/ntdll.dll \
    app/Madeira/arm64ec-windows/kernelbase.dll app/Madeira/arm64ec-windows/kernel32.dll
mkdir -p "$out"
for sdk in macosx iphoneos; do
    python3 "$root/build/signed-pe/prepare.py" --sdk "$sdk" --thread-state --toolchain "$toolchain" --output "$out/$sdk-runtime" \
        "$farm/ntdll.dll" "$farm/kernelbase.dll" "$farm/kernel32.dll" > "$out/$sdk-preparation.jsonl"
done
native="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["framework"])' "$out/macosx-preparation.jsonl")"
native_ios="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["framework"])' "$out/iphoneos-preparation.jsonl")"
bash "$root/build/signed-fex/check-runtime.sh" "$fex" "$fex_build" "$toolchain" "$runtime/wine" \
    "$native/$(basename "$native" .framework)"
python3 "$root/build/signed-fex/bundle.py" --sdk iphoneos --toolchain "$toolchain" --output "$out/fex"
"$toolchain/llvm-dlltool" -m arm64 -d "$root/build/signed-pe/workload.def" -l "$out/imports-arm64.lib"
"$toolchain/aarch64-w64-mingw32-clang" -shared -nostdlib -O2 -ffreestanding -fno-builtin \
    -fno-stack-protector -mno-stack-arg-probe -ffp-contract=off -Wl,--entry,guest_workload \
    -Wl,--export-all-symbols -Wl,--section-alignment,65536 \
    "$root/build/signed-pe/workload.c" "$out/imports-arm64.lib" -lntdll -o "$out/native-workload.dll"
python3 "$root/build/signed-pe/prepare.py" --sdk macosx --output "$out/macosx" \
    "$out/native-workload.dll" > "$out/native-workload.json"
program="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["framework"])' "$out/native-workload.json")"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -Werror -I "$root/build/ntdll-unix" \
    "$root/build/signed-pe/host.c" "$root/build/signed-pe/workload.c" \
    "$root/build/ntdll-unix/signed_pe_ios.c" -o "$out/host"
"$out/host" "$native/$(basename "$native" .framework)" --thread-state \
    --program "$program/$(basename "$program" .framework)" \
    --wine-map "$farm/ntdll.dll" "$out/macosx-runtime" > "$out/host-native.txt"
xcrun clang -target arm64-apple-macos13.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
    -I "$root/app/Madeira" -I "$root/build/ntdll-unix" -I "$root/build/signed-pe" \
    "$root/build/signed-pe/host-wine.m" "$root/app/Madeira/SignedWine.m" \
    "$root/build/ntdll-unix/signed_pe_ios.c" "$root/app/Madeira/SignedFEX.c" \
    "$root/app/Madeira/SignedCodeProbe.m" -framework Foundation -o "$out/host-wine"
"$out/host-wine" "$out/fex/macosx/MadeiraSignedFEX.framework/MadeiraSignedFEX" \
    "$out/fex/guest-image.bin" "$native/$(basename "$native" .framework)" > "$out/host-wine.txt"
for name in refusal refusal-external; do
    python3 "$root/build/signed-fex/prepare.py" --fex-source "$fex" --fex-build "$fex_build" \
        --toolchain "$toolchain" --workload "$root/build/signed-pe/$name.c" --wine-imports \
        --import-definition "$root/build/signed-pe/workload.def" --output "$out/$name"
    python3 "$root/build/signed-fex/bundle.py" --sdk macosx --toolchain "$toolchain" --output "$out/$name"
done
python3 - "$out" "$native" <<'PY'
from pathlib import Path
import subprocess, sys
out, native = map(Path, sys.argv[1:])
for name, rip in [('refusal', '0x130010000'), ('refusal-external', '0x12345678')]:
    run = subprocess.run([out/'host-wine', out/name/'macosx/MadeiraSignedFEX.framework/MadeiraSignedFEX',
        out/name/'guest-image.bin', native/native.stem], capture_output=True, text=True, timeout=15)
    (out/(name+'-runtime.txt')).write_text(run.stdout + run.stderr)
    assert run.returncode == 1 and 'missing pretranslated RIP='+rip in run.stdout
    assert 'callback dispatch refused' in run.stdout and 'Wine signed DLL code=unchanged' in run.stdout
PY
python3 "$root/build/signed-fex/package.py" --output "$delivery" --prepared "$out/fex" \
    --wine-framework "$native_ios" --wine-license "$runtime/wine/COPYING.LIB"
cat "$out/host-native.txt" "$out/host-wine.txt"
