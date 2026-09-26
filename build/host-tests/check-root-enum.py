#!/usr/bin/env python3
"""Production-source regression for the shared host-root enumeration; no Wine or guest runs.

Device failure (log 169): the first pseudo-process to import roots consumed the shared
list, the next import saw none, and rootstore deleted the imported roots from the registry.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "build/crypto-unix/crypt32_unixlib_ios.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
a = src.index("/* iOS-Madeira ml1400: PER-CALLER ENUMERATION")
block = src[a:src.index("static NTSTATUS enum_root_certs(", a)]
block = block.replace("#include <pthread.h>", "").replace("#include <stdint.h>", "").replace("#include <time.h>", "")
code = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <assert.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include "wine/list.h"
typedef int NTSTATUS; typedef unsigned char BYTE; typedef unsigned int DWORD; typedef size_t SIZE_T; typedef int BOOL;
#define TRUE 1
#define STATUS_SUCCESS 0
#define STATUS_NO_MORE_ENTRIES ((NTSTATUS)0x8000001a)
struct enum_root_certs_params { void *buffer; DWORD size; DWORD *needed; };
static unsigned long long fake_ms = 1000;
static int fake_clock_gettime(int id, struct timespec *ts) { (void)id; ts->tv_sec = fake_ms / 1000; ts->tv_nsec = (fake_ms % 1000) * 1000000; return 0; }
#define clock_gettime fake_clock_gettime
""" + src[src.index("struct root_cert\n"):src.index("struct DynamicBuffer")] + r"""
static int loads;
static void load_root_certs(void) {
    loads++;
    for (int i = 0; i < 121; i++) {           /* varied sizes; some exceed the 2048-byte first buffer */
        SIZE_T size = 900 + (i * 37) % 2400;
        BYTE *d = add_cert(size); memset(d, i, size);
    }
}
""" + block + function(src, "static NTSTATUS enum_root_certs(") + r"""
/* the rootstore.c loop: 2048-byte buffer, grow when needed > size, stop at NO_MORE_ENTRIES */
static int import_roots_from(int limit, int start) {
    DWORD needed; struct enum_root_certs_params p = { malloc(2048), 2048, &needed };
    int n = 0;
    while (!enum_root_certs(&p)) {
        if (needed > p.size) { free(p.buffer); p.buffer = malloc(needed); p.size = needed; continue; }
        assert(((BYTE *)p.buffer)[0] == (BYTE)(start + n));   /* in order, none skipped */
        if (++n == limit) break;
    }
    free(p.buffer);
    return n;
}
static int import_roots(int limit) { return import_roots_from(limit, 0); }
static int result;
static void *thread_import(void *arg) { result = import_roots(*(int *)arg); return NULL; }
static int in_thread(int limit) { pthread_t t; pthread_create(&t, NULL, thread_import, &limit); pthread_join(t, NULL); return result; }
int main(int argc, char **argv) {
    if (argc > 1) {
        setenv("MADEIRA_ROOT_ENUM_SHARED", "0", 1);
        assert(in_thread(0) == 121);
        assert(in_thread(0) == 0);                  /* the device failure: a later process sees no roots */
        puts("PASS: rollback reproduces the consumed root list"); return 0;
    }
    assert(in_thread(0) == 121);                    /* first process */
    assert(in_thread(0) == 121);                    /* second process: the fix */
    assert(import_roots(0) == 121 && import_roots(0) == 121);   /* same thread twice */
    assert(import_roots(5) == 5);                   /* interrupted enumeration ... */
    fake_ms += 11000;                               /* ... idle longer than 10 s restarts */
    assert(import_roots(0) == 121);
    assert(import_roots(7) == 7);                   /* a quick continuation resumes where it stopped */
    fake_ms += 100;
    assert(import_roots_from(0, 7) == 121 - 7);
    assert(loads == 1);
    puts("PASS: every caller enumerates all 121 host roots in order, with buffer growth, restarts and one load");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", "-pthread", "-I", str(root / "wine/include"), str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
    subprocess.run([str(exe), "rollback"], check=True)
