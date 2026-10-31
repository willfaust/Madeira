#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
state="$(mktemp -d)"
python3 "$ROOT/tools/build/stage-fex-compat.py" apply "$state"
trap 'build_status=$?; python3 "$ROOT/tools/build/stage-fex-compat.py" restore "$state" || exit 1; rm -rf "$state"; exit "$build_status"' EXIT
bash "$ROOT/build/fex-wow64/build.sh"
python3 - "$ROOT/app/Madeira/aarch64-windows/xtajit.dll" <<'PY'
from pathlib import Path
import struct, sys
p = Path(sys.argv[1]); data = p.read_bytes()
pe = struct.unpack_from('<I', data, 0x3c)[0]
assert struct.unpack_from('<H', data, pe + 4)[0] == 0xaa64, 'WOW64 FEX must be ARM64'
assert b'MadeiraBTCpuThreadInit' in data and b'[fex-thread-init-v1]' in data, 'stale FEX CPU producer'
assert b'MadeiraBTCpuWriteMemory' in data and b'[fex-guest-write-v1]' in data, 'stale FEX native-write producer'
size = struct.unpack_from('<I', data, pe + 24 + 56)[0]
if len(data) < size: p.write_bytes(data + bytes(size - len(data)))
print('PASS rebuilt ARM64 FEX CPU producer exports checked thread initialization')
PY
