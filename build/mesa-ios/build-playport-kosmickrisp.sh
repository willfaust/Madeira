#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The experimental geometry/transform-feedback/cache stack, independent of BCD.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${KK_WORK:=$HERE/.work-playport}"
export KK_WORK
export KK_PROFILE=playport
export KK_SHADER_CACHE="${KK_SHADER_CACHE:-enabled}"
export KK_MESA_SRC="$KK_WORK/mesa-b39d173ca9369c19fda2635be6655d308067e52d"
python3 "$HERE/fetch-playport.py" "$KK_WORK"
exec bash "$HERE/build-kosmickrisp.sh"
