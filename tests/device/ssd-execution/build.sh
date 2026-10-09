#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 David Brookes
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
set -euo pipefail
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$fixture_dir/../../.." && pwd)"
mingw="${MINGW_BIN:-$repo_root/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
fixture_output="${FIXTURE_OUTPUT:-$fixture_dir/out}"
mkdir -p "$fixture_output/assets"
"$mingw/x86_64-w64-mingw32-clang" -O2 -nostdlib -fno-builtin -fno-stack-protector -shared -Wl,--entry,DllMain "$fixture_dir/probe_dll.c" -Wl,--no-insert-timestamp -Wl,--out-implib,"$fixture_output/libssd_probe.a" -o "$fixture_output/ssd_probe.dll"
"$mingw/x86_64-w64-mingw32-clang" -O2 -nostdlib -fno-builtin -fno-stack-protector -Wl,--entry,start "$fixture_dir/probe.c" -L"$fixture_output" -lssd_probe -lkernel32 -Wl,--no-insert-timestamp -o "$fixture_output/ssd_probe.exe"
printf 'SSD relative asset\n' > "$fixture_output/assets/input.txt"
"$mingw/llvm-readobj" --coff-imports "$fixture_output/ssd_probe.exe"
