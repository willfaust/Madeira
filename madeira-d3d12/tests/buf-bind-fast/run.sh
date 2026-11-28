#!/bin/bash
# buf-bind-fast host test: the real text of mad_resolve_bind (cut from madeira_d3d12.c) over a model of the
# address index. Random creates, releases, pending rebuilds and writers in mid-change; every answer must be
# the plain search's. Usage: run.sh [lookups per churn rate]
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)"
python3 - "$DIR/../../src/pe/madeira_d3d12.c" "$OUT/resolve_bind.inc" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('static struct mad_resource *mad_resolve_bind(struct mad_list *l, UINT64 addr, UINT64 *off) {')
b = s.index('static void STDMETHODCALLTYPE list_IASetIndexBuffer', a)
open(sys.argv[2], 'w').write(s[a:b])
PY
cc -O2 -Wall -Wextra -I"$OUT" -o "$OUT/bbtest" "$DIR/bbtest.c"
for churn in 1 20 400 5000; do "$OUT/bbtest" "${1:-20000000}" "$churn"; done
