#!/usr/bin/env python3
"""Production-source regression for the ml1420 fast JIT reverse lookup; no Wine or guest runs.

Device log: ios_jit_reverse_translate_addr was 41-46% of all CPU while a thread unwound in a
loop. The fast path must return exactly what the plain scan returns for every live mapping,
return addresses outside the pool unchanged, and never match a freed slot (pe_base NULL).
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
struct = src[src.index("struct ios_jit_mapping {"):src.index("static struct ios_jit_mapping ios_jit_mappings[")]
a = src.index("static int ios_jit_rev_fast = 1;")
block = src[a:src.index("void *ios_jit_reverse_translate_addr(", a)] + function(src, "void *ios_jit_reverse_translate_addr(")
assert src.count("ios_jit_rev_read_switch();") == 2, "switch read at both registration sites"
code = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>
#define IOS_JIT_MAX_MAPPINGS 512
""" + struct + r"""
static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];
static int ios_jit_mapping_count;
void *ios_jit_rx_base_global;
size_t ios_jit_pool_size_global;
#undef dprintf
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)
""" + block + r"""
static void *plain(const void *addr) {   /* the pre-ml1420 scan, minus freed slots */
    uintptr_t a = (uintptr_t)addr;
    for (int i = 0; i < ios_jit_mapping_count; i++) {
        uintptr_t j = (uintptr_t)ios_jit_mappings[i].jit_base;
        if (ios_jit_mappings[i].pe_base && a >= j && a < j + ios_jit_mappings[i].size)
            return (void *)((uintptr_t)ios_jit_mappings[i].pe_base + (a - j));
    }
    return (void *)addr;
}
int main(int argc, char **argv) {
    if (argc > 1) setenv("MADEIRA_JIT_REV_FAST", "0", 1);
    uintptr_t rx = 0x119800000, size = 0x38000000;
    assert(ios_jit_reverse_translate_addr((void *)0x7000) == (void *)0x7000);   /* no pool yet */
    ios_jit_rx_base_global = (void *)rx; ios_jit_pool_size_global = size;
    unsigned seed = 7;
    for (int i = 0; i < 300; i++) {
        seed = seed * 1103515245 + 12345;
        ios_jit_mappings[i].jit_base = (void *)(rx + (uintptr_t)i * 0x100000);
        ios_jit_mappings[i].size = 0x10000 + (seed % 0xf0000);
        ios_jit_mappings[i].pe_base = (void *)(0x7100000000 + (uintptr_t)i * 0x1000000);
    }
    ios_jit_mapping_count = 300;
    ios_jit_rev_read_switch();
    ios_jit_mappings[17].pe_base = NULL;                                       /* freed slot */
    uintptr_t freed = (uintptr_t)ios_jit_mappings[17].jit_base + 0x40;
    assert(ios_jit_reverse_translate_addr((void *)freed) == (void *)freed);
    assert(ios_jit_reverse_translate_addr((void *)(rx - 4)) == (void *)(rx - 4));
    assert(ios_jit_reverse_translate_addr((void *)(rx + size)) == (void *)(rx + size));
    assert(ios_jit_reverse_translate_addr((void *)0x7100001234) == (void *)0x7100001234);
    for (int k = 0; k < 200000; k++) {                                         /* random + repeated lookups */
        seed = seed * 1103515245 + 12345;
        uintptr_t a = rx + ((uintptr_t)seed % (300 * 0x100000 + 0x1000));
        assert(ios_jit_reverse_translate_addr((void *)a) == plain((void *)a));
        assert(ios_jit_reverse_translate_addr((void *)a) == plain((void *)a));   /* hint hit */
    }
    ios_jit_mappings[5].pe_base = NULL;                                        /* the hinted slot dies */
    ios_jit_rev_hint = 5;
    uintptr_t in5 = (uintptr_t)ios_jit_mappings[5].jit_base + 8;
    assert(ios_jit_reverse_translate_addr((void *)in5) == (void *)in5);
    printf("fast=%d\n", ios_jit_rev_fast);
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], check=True, capture_output=True, text=True)
    assert "fast=1" in out.stdout and "[jit-rev] ml1420 fast=1" in out.stderr, out.stderr
    off = subprocess.run([str(exe), "rollback"], capture_output=True, text=True)
    # The plain scan matches a freed slot's stale range, which is the behaviour the fast path fixes.
    assert off.returncode != 0 and "[jit-rev] ml1420 fast=0" in off.stderr, off.stderr[-800:]
    print("PASS: fast reverse lookup equals the scan for live mappings, rejects out-of-pool and freed slots; rollback restores the plain scan")
