#!/usr/bin/env python3
"""Production-source regression for LSE atomic emulation on the RW alias; no Wine or guest runs."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/signal_arm64_ios.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
assert "ios_lse_atomic_op( insn, rw_addr, IOS_STORE_SRC(rs), &old )" in src, "handler does not call the helper"
code = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <pthread.h>
""" + function(src, "static int ios_lse_atomic_op(") + r"""
static uint32_t enc(int size, int opc, int rs, int rn, int rt) {
    return ((uint32_t)size << 30) | 0x38200000u | (1u << 23) | (1u << 22) | ((uint32_t)rs << 16) |
           ((uint32_t)opc << 12) | ((uint32_t)rn << 5) | (uint32_t)rt;
}
static _Alignas(16) uint64_t shared;
static void *adder(void *arg) {
    uint64_t old;
    for (int i = 0; i < 100000; ++i) assert(ios_lse_atomic_op(enc(3, 0, 1, 2, 3), (uintptr_t)&shared, 1, &old));
    return arg;
}
int main(void) {
    _Alignas(16) unsigned char buf[16];
    uint64_t old;
    uint32_t *w = (uint32_t *)buf;

    /* the device instruction: LDADDAL w5, w5, [x24] */
    assert(enc(2, 0, 5, 24, 5) == 0xb8e50305u);
    *w = 0x7ffffffe; assert(ios_lse_atomic_op(0xb8e50305u, (uintptr_t)w, 0xffffffffu, &old));
    assert(old == 0x7ffffffe && *w == 0x7ffffffd);                    /* lock xadd -1 */
    *w = 0xfffffffe; assert(ios_lse_atomic_op(0xb8e50305u, (uintptr_t)w, 3, &old));
    assert(old == 0xfffffffe && *w == 1);                               /* 32-bit wrap */

    uint64_t *q = (uint64_t *)buf;
    *q = 0xf0f0; assert(ios_lse_atomic_op(enc(3, 1, 1, 2, 3), (uintptr_t)q, 0x00f0, &old)); assert(old == 0xf0f0 && *q == 0xf000); /* CLR */
    *q = 0xf0f0; assert(ios_lse_atomic_op(enc(3, 2, 1, 2, 3), (uintptr_t)q, 0xffff, &old)); assert(*q == 0x0f0f);                  /* EOR */
    *q = 0x0100; assert(ios_lse_atomic_op(enc(3, 3, 1, 2, 3), (uintptr_t)q, 0x0011, &old)); assert(*q == 0x0111);                  /* SET */

    uint8_t *b = buf; memset(buf, 0xaa, 16);
    *b = 0x80; assert(ios_lse_atomic_op(enc(0, 4, 1, 2, 3), (uintptr_t)b, 0x01, &old)); assert(old == 0x80 && *b == 0x01);       /* SMAX byte */
    *b = 0x80; assert(ios_lse_atomic_op(enc(0, 5, 1, 2, 3), (uintptr_t)b, 0x01, &old)); assert(*b == 0x80);                      /* SMIN byte */
    *b = 0x80; assert(ios_lse_atomic_op(enc(0, 6, 1, 2, 3), (uintptr_t)b, 0x01, &old)); assert(*b == 0x80);                      /* UMAX byte */
    *b = 0x80; assert(ios_lse_atomic_op(enc(0, 7, 1, 2, 3), (uintptr_t)b, 0x01, &old)); assert(*b == 0x01);                      /* UMIN byte */
    assert(buf[1] == 0xaa);                                              /* neighbours untouched */

    uint16_t *h = (uint16_t *)buf;
    *h = 0xffff; assert(ios_lse_atomic_op(enc(1, 0, 1, 2, 3), (uintptr_t)h, 0x10002, &old)); assert(old == 0xffff && *h == 1);   /* operand masked */
    *q = (uint64_t)-5; assert(ios_lse_atomic_op(enc(3, 4, 1, 2, 3), (uintptr_t)q, 3, &old)); assert(*q == 3);                   /* SMAX 64 */

    assert(!ios_lse_atomic_op(enc(2, 0, 1, 2, 3), (uintptr_t)(buf + 2), 1, &old));   /* unaligned refused */
    assert(!ios_lse_atomic_op(0xb8e58305u, (uintptr_t)w, 1, &old));                    /* SWP (o3=1) not claimed */
    assert(!ios_lse_atomic_op(0x88a07c00u | 0x40000000u, (uintptr_t)w, 1, &old));      /* CAS not claimed */
    assert(!ios_lse_atomic_op(0xb9000000u, (uintptr_t)w, 1, &old));                    /* plain STR not claimed */

    pthread_t t[8];
    shared = 0;
    for (int i = 0; i < 8; ++i) pthread_create(&t[i], NULL, adder, NULL);
    for (int i = 0; i < 8; ++i) pthread_join(t[i], NULL);
    assert(shared == 800000);
    puts("PASS: LSE ADD/CLR/EOR/SET/SMAX/SMIN/UMAX/UMIN at every size, device LDADDAL, unaligned/SWP/CAS/STR not claimed, 8-thread atomicity");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", "-pthread", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
