#!/usr/bin/env python3
"""Production-source regression for 32-bit winproc handles in win32u; no Wine or guest runs.

Chain under test: a 32-bit CallWindowProc/RegisterClass passes a winproc handle 0xffffNNNN,
the WoW64 thunk converts it with guest_ptr32 (adds the window base), and win32u's
get_winproc_ptr must still resolve it.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
cls = (root / "build/win32u-unix/class_ios.c").read_text()
wow = (root / "wine/dlls/wow64win/wow64win_private.h").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
guest = function(wow, "static inline void *guest_ptr32(").replace("wow64win_guest_base()", "caller_base")
code = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
typedef uintptr_t ULONG_PTR;
typedef uint32_t ULONG, UINT;
typedef void *WNDPROC;
#define LOWORD(x) ((unsigned short)((ULONG_PTR)(x) & 0xffff))
#define WINPROC_HANDLE (~0u >> 16)
#define MAX_WINPROCS 4096
#define NTUSER_NB_PROCS 18
#define WINPROC_PROC16 ((void *)1)
typedef struct { WNDPROC procA, procW; } WINDOWPROC;
static WINDOWPROC winproc_array[MAX_WINPROCS];
static UINT winproc_used = 64;
static ULONG_PTR caller_base;
ULONG_PTR ios_wow_base(void) { return caller_base; }
""" + guest + "\n" + function(cls, "static WNDPROC ios_winproc_handle_arg(").replace("extern ULONG_PTR ios_wow_base(void);", "") \
    + "\n" + function(cls, "static WINDOWPROC *get_winproc_ptr(") + r"""
int main(int argc, char **argv) {
    if (argc > 1) {
        setenv("MADEIRA_WINPROC_HANDLE", "0", 1);
        caller_base = 0x7200000000ull;
        assert(get_winproc_ptr(guest_ptr32(0xffff0036)) == NULL);   /* device failure: handle not recognised */
        puts("PASS: rollback reproduces the unrecognised winproc handle"); return 0;
    }
    for (int w = 0; w < 4; ++w) {
        caller_base = 0x7100000000ull + (ULONG_PTR)w * 0x100000000ull;
        assert(get_winproc_ptr(guest_ptr32(0xffff0036)) == &winproc_array[0x36]);   /* CallWindowProc path */
        assert(get_winproc_ptr((WNDPROC)(ULONG_PTR)0xffff0012) == &winproc_array[0x12]); /* unconverted handle */
        assert(get_winproc_ptr(guest_ptr32(0xffff0100)) == NULL);                   /* beyond winproc_used */
        assert(get_winproc_ptr(guest_ptr32(0xffff1000)) == WINPROC_PROC16);         /* 16-bit range kept */
        assert(get_winproc_ptr(guest_ptr32(0x00401000)) == NULL);                   /* real guest procedure */
        assert(get_winproc_ptr(guest_ptr32(0xfffeffff)) == NULL);                   /* just below the handle range */
        assert(get_winproc_ptr((WNDPROC)(caller_base + 0x100000000ull + 0xffff0036)) == NULL); /* next window */
        assert(get_winproc_ptr((WNDPROC)(caller_base - 0x10000 + 0x36)) == NULL);  /* below the window */
    }
    caller_base = 0;                                                               /* native 64-bit caller */
    assert(get_winproc_ptr((WNDPROC)0x72ffff0036ull) == NULL);
    assert(get_winproc_ptr((WNDPROC)(ULONG_PTR)0xffff0036) == &winproc_array[0x36]);
    assert(get_winproc_ptr(NULL) == NULL);
    puts("PASS: offset 32-bit winproc handles resolve in four windows; real procedures, other windows and native callers unchanged");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
    subprocess.run([str(exe), "rollback"], check=True)
