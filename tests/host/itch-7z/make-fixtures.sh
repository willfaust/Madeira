#!/bin/sh
# Rebuilds the .7z fixtures of tests/host/check-itch-7z.py with 7-Zip (7zz or 7z, 23.01
# made the checked-in ones). The files inside come from check-itch-7z.py --tree.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
z=$(command -v 7zz || command -v 7z)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$here/../check-itch-7z.py" --tree "$work/game"
cd "$work"
make() { name=$1; shift; rm -f "$here/$name.7z"; "$z" a "$here/$name.7z" game "$@" >/dev/null; }
make default
make x86-lzma2 -m0=BCJ -m1=LZMA2
make x86-lzma -m0=BCJ -m1=LZMA
make x86-copy-plain-header -m0=BCJ -m1=Copy -mhc=off
make x86-deflate -m0=BCJ -m1=Deflate
make delta -m0=Delta:4 -m1=LZMA2
make arm64 -m0=ARM64 -m1=LZMA2
make nonsolid -ms=off
make bcj2-lzma -m0=BCJ2 -m1=LZMA:d20 -m2=LZMA:d16 -m3=LZMA:d16 -mb0:1 -mb0s1:2 -mb0s2:3
make bcj2-lzma2 -mx9 -m0=BCJ2 -m1=LZMA2:d20 -m2=LZMA:d16 -m3=LZMA:d16 -mb0:1 -mb0s1:2 -mb0s2:3
make ppmd -m0=PPMd
make encrypted -pmadeira -mhe=on
