#!/usr/bin/env bash
# MADEIRA ml1010: build and run the fastsync SEMAPHORE host model.
#
# It compiles against the REAL build/ntdll-unix/shims/ios_fastsync.h, so the
# packing, the accessors, the struct layout and the sign handling under test
# are the shipping ones. Exit 0 means: every token produced was consumed at
# most once and none was lost, no consumer proceeded without a token behind
# it, no timed-out waiter dropped one, an overflowing release changed nothing,
# and a recycled cell rejected the stale generation.
#
# ml1060 adds the case the device actually runs: every waiter on the modelled
# SERVER path, every releaser on the client fast path, bursts of 1..8 tokens,
# and a producer that waits for its batch -- checked with a LIVENESS bound
# rather than only with accounting, because the failure being looked for loses
# no token, it only fails to wake.  The same model then runs once with the
# releaser's two operations in the wrong order, and that run MUST stall;
# a liveness check that cannot fail is decoration.
#
# Pass --tsan to build it under ThreadSanitizer as well (slower, fewer
# iterations' worth of wall clock, but it checks the memory ordering rather
# than only the outcomes).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHIMS="$HERE/../ntdll-unix/shims"
OUT="$HERE/fastsync-semrace"

${CC:-cc} -O2 -g -Wall -Wextra -Wno-unused-parameter -I"$SHIMS" \
    -o "$OUT" "$HERE/fastsync-semrace.c" -lpthread
"$OUT"
echo "SEMRACE EXIT STATUS: $? (0 = passed)"

if [ "${1:-}" = "--tsan" ]; then
    echo ""
    echo "=== rebuilding under -fsanitize=thread ==="
    ${CC:-cc} -O1 -g -Wall -fsanitize=thread -I"$SHIMS" \
        -o "$OUT-tsan" "$HERE/fastsync-semrace.c" -lpthread
    "$OUT-tsan"
    echo "SEMRACE TSAN EXIT STATUS: $? (0 = passed, and no race report above)"
fi
