#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fex="${1:?Pass the pinned FEX source}"
fex_build="${2:?Pass its matching host build}"
tools="${3:?Pass llvm-mingw bin}"
wine="${4:?Pass the matching Wine source}"
native="${5:?Pass the prepared macOS ntdll binary}"
out="$root/build/signed-pe/out"
prepare=(python3 "$root/build/signed-fex/prepare.py" --fex-source "$fex" --fex-build "$fex_build" --toolchain "$tools")
bundle=(python3 "$root/build/signed-fex/bundle.py" --sdk macosx --toolchain "$tools")
"${prepare[@]}" --workload "$root/build/signed-pe/workload.c" --wine-imports \
    --import-definition "$root/build/signed-pe/workload.def" --output "$out/fex"
"${prepare[@]}" --workload "$root/build/signed-fex/context.c" --output "$out/context"
"${prepare[@]}" --workload "$root/build/signed-fex/vector.c" --output "$out/vector"
mkdir -p "$out/cross"
"$tools/x86_64-w64-mingw32-clang" "$root/build/signed-fex/cross.c" -shared -nostdlib -O2 \
    -ffreestanding -fno-builtin -fno-stack-protector -mno-stack-arg-probe \
    -Wl,--entry,guest_compare -Wl,--export-all-symbols -Wl,--section-alignment,16384 \
    -lntdll -o "$out/cross/cross.dll"
"${prepare[@]}" --pe "$out/cross/cross.dll" --wine-imports --output "$out/cross"
"${prepare[@]}" --workload "$root/build/signed-fex/cross-main.c" --wine-imports \
    --import-definition "$root/build/signed-pe/workload.def" --import-definition "$root/build/signed-fex/cross.def" \
    --output "$out/cross-main"
for name in fex context cross-main vector; do "${bundle[@]}" --output "$out/$name"; done
"${bundle[@]}" --output "$out/cross" --name MadeiraSignedFEXCross
"$tools/x86_64-w64-mingw32-clang" -I "$wine/include" -I "$root/app/Madeira" \
    -Wall -Wextra -Werror -c "$root/build/signed-fex/check-context-layout.c" -o "$out/context-layout.o"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -Werror \
    -I "$root/app/Madeira" -I "$root/build/ntdll-unix" -I "$root/build/signed-pe" \
    "$root/build/signed-fex/host-context.c" "$root/app/Madeira/SignedFEX.c" \
    "$root/app/Madeira/SignedCodeProbe.m" "$root/build/ntdll-unix/signed_pe_ios.c" \
    -framework Foundation -o "$out/host-context"
python3 - "$out" "$native" <<'PY'
from pathlib import Path
import subprocess, sys
out, native = Path(sys.argv[1]), sys.argv[2]
args = [out/'host-context', out/'fex/macosx/MadeiraSignedFEX.framework/MadeiraSignedFEX', out/'fex/guest-image.bin', native]
for name, bundle in [('context','MadeiraSignedFEX'),('cross-main','MadeiraSignedFEX'),('cross','MadeiraSignedFEXCross'),('vector','MadeiraSignedFEX')]:
    args += [out/name/'macosx'/(bundle+'.framework')/bundle, out/name/'guest-image.bin']
result = subprocess.run(args, capture_output=True, text=True, timeout=30)
(out/'host-context.txt').write_text(result.stdout + result.stderr)
assert result.returncode == 0, result.stdout + result.stderr
print(result.stdout)
result = subprocess.run([*args, '--native-refusal'], capture_output=True, text=True, timeout=15)
(out/'native-first-refusal.txt').write_text(result.stdout + result.stderr)
assert result.returncode == 0 and "caller's fatal-error handler" in result.stderr and 'unbound on its original stack' in result.stdout, result.stdout + result.stderr
print(result.stdout + result.stderr)
PY
