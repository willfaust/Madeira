#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""A fatal guest fault logs the faulting code and its callers (ml1291); no Wine runs.

Grounded's (Steam 962130) browser GPU process died on build 48 inside the game's
own ~120 MB libcef.dll (`cmp [r9], dil`, r9 = 0x30, libcef+0x8a6140), too big to
upload, so build/ntdll-unix/signal_arm64_ios.c's ios_guest_fault_context now
writes the image, RVA and code bytes for the RIP and for each return address on
the guest stack. Compiles it (with ios_guest_ctx_read, ios_guest_ctx_image,
ios_guest_ctx_hex and ios_guest_ctx_is_call, from the source) against a fake
guest: an image at a 64 KB boundary, a stack holding a real return address
(after an E8 call), one after an FF /2 [rip+d32] call, one after no call, and
a pointer past SizeOfImage. Checks:
  - the RIP line names the image and RVA, and dumps 0x200 bytes of code;
  - only the two call sites are reported as return addresses, with their RVAs;
  - an address outside every image is not reported;
  - the saved RSP is used when the live one cannot be read;
  - only the first 4 faults are described, and MADEIRA_GUEST_CTX=0 turns it off;
and textually that the segv handler calls it after the ml885 exact-RIP line
with the live SRA RSP (x23) and the saved one.
Needs python3 and a C compiler (Linux).
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()


def function(signature):
    start = src.index(signature + '\n{')
    return src[start:src.index('\n}\n', start) + 3]


code = (function('static int ios_guest_ctx_read( uint64_t va, void *buf, size_t len )') +
        function('static uint64_t ios_guest_ctx_image( uint64_t va, uint32_t *size )') +
        function('static void ios_guest_ctx_hex( const char *what, uint64_t base, uint64_t from, int len )') +
        function('static int ios_guest_ctx_is_call( uint64_t ret )') +
        function('static void ios_guest_fault_context( uint64_t rip, uint64_t rsp, uint64_t gregs_rsp )'))

harness = r'''
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
#define KERN_SUCCESS 0
#define mach_task_self() 0
static char out[1 << 16];
static size_t outlen;
#define ERR(...) (outlen += snprintf(out + outlen, sizeof(out) - outlen, __VA_ARGS__))
#define GUEST 0x7000000000ull
#define GUEST_SIZE 0x80000ull
static int mach_vm_read_overwrite( int task, mach_vm_address_t a, mach_vm_size_t n, mach_vm_address_t to, mach_vm_size_t *got )
{
    (void)task;
    if (a < GUEST || a + n > GUEST + GUEST_SIZE) return 1;
    memcpy( (void *)(uintptr_t)to, (void *)(uintptr_t)a, n );
    *got = n;
    return KERN_SUCCESS;
}
''' + code + r'''
static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: " __VA_ARGS__); printf("\n"); fails++; } } while (0)

int main(void)
{
    uint8_t *g = mmap( (void *)GUEST, GUEST_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0 );
    uint64_t img = GUEST + 0x20000, stk = GUEST + 0x70000, *s = (uint64_t *)(uintptr_t)stk;
    if (g != (void *)GUEST) { printf("mmap failed\n"); return 1; }

    /* the image: MZ, e_lfanew = 0x80, PE, SizeOfImage = 0x30000 (ends at GUEST + 0x50000) */
    memcpy( (void *)(uintptr_t)img, "MZ", 2 );
    *(uint32_t *)(uintptr_t)(img + 0x3c) = 0x80;
    *(uint32_t *)(uintptr_t)(img + 0x80) = 0x4550;
    *(uint32_t *)(uintptr_t)(img + 0x80 + 0x50) = 0x30000;
    /* the fault, at rva 0x18140: cmp [r9], dil */
    memcpy( (void *)(uintptr_t)(img + 0x18140), "\x41\x38\x39", 3 );
    /* call rel32 ending at rva 0x12345, call [rip+d32] ending at rva 0x22000 */
    memcpy( (void *)(uintptr_t)(img + 0x12340), "\xe8\x11\x22\x33\x44", 5 );
    memcpy( (void *)(uintptr_t)(img + 0x21ffa), "\xff\x15\x10\x20\x30\x40", 6 );

    s[2] = img + 0x9999;        /* inside the image, but no call before it */
    s[5] = img + 0x12345;       /* ret #1 */
    s[9] = GUEST + 0x60008;     /* past SizeOfImage */
    s[11] = 0x30;               /* not an address */
    s[40] = img + 0x22000;      /* ret #2 */

    ios_guest_fault_context( img + 0x18140, stk, stk );
    CHECK( strstr( out, "rip=0x7000038140 image=0x7000020000 size=0x30000 rva=0x18140 rsp=0x7000070000" ), "rip line:\n%s", out );
    CHECK( strstr( out, "[guest-ctx] rip rva 0x18140: 41 38 39 " ), "fault bytes not dumped at rva 0x18140:\n%s", out );
    CHECK( strstr( out, "rip rva 0x17fc0:" ) && strstr( out, "rip rva 0x181a0:" ) && !strstr( out, "rip rva 0x181c0:" ), "rip window is not 0x200 bytes" );
    CHECK( strstr( out, "ret #1 [rsp+0x28]=0x7000032345 image=0x7000020000 rva=0x12345" ), "E8 caller missing:\n%s", out );
    CHECK( strstr( out, "ret #2 [rsp+0x140]=0x7000042000 image=0x7000020000 rva=0x22000" ), "FF /2 caller missing:\n%s", out );
    CHECK( !strstr( out, "ret #3" ), "a non-call was reported:\n%s", out );
    CHECK( strstr( out, "ret rva 0x12325: " ) && strstr( out, "e8 11 22 33 44 \n" ), "caller bytes not dumped" );

    /* live rsp unreadable: the saved one is used */
    outlen = 0; out[0] = 0;
    ios_guest_fault_context( img + 0x18140, 0x30, stk );
    CHECK( strstr( out, "using saved rsp=0x7000070000" ) && strstr( out, "ret #2" ), "saved rsp not used:\n%s", out );

    /* a fault outside every image: no image, no code dump */
    outlen = 0; out[0] = 0;
    ios_guest_fault_context( GUEST + 0x60008, 0x30, 0x30 );
    CHECK( strstr( out, "image=(nil)" ) || strstr( out, "image=0x0" ), "unmapped rip got an image:\n%s", out );
    CHECK( !strstr( out, "rip rva" ), "unmapped rip got a dump" );

    /* only 4: the 4th is described, the 5th is not */
    outlen = 0; out[0] = 0;
    ios_guest_fault_context( img + 0x18140, stk, stk );
    CHECK( outlen, "the 4th fault was not described" );
    outlen = 0; out[0] = 0;
    ios_guest_fault_context( img + 0x18140, stk, stk );
    CHECK( !outlen, "a 5th fault was described" );

    if (fails) return 1;
    printf("ok\n");
    return 0;
}
'''

off = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
#define KERN_SUCCESS 0
#define mach_task_self() 0
static int n;
#define ERR(...) (n++)
static int mach_vm_read_overwrite( int t, mach_vm_address_t a, mach_vm_size_t s, mach_vm_address_t to, mach_vm_size_t *g ) { (void)t; (void)a; (void)s; (void)to; *g = 0; return 1; }
''' + code + r'''
int main(void) { setenv( "MADEIRA_GUEST_CTX", "0", 1 ); ios_guest_fault_context( 0x7000038140, 0, 0 ); printf(n ? "FAIL: logged with MADEIRA_GUEST_CTX=0\n" : "ok\n"); return n != 0; }
'''

with tempfile.TemporaryDirectory() as d:
    for name, text in (('t', harness), ('off', off)):
        c = Path(d) / (name + '.c')
        exe = Path(d) / name
        c.write_text(text)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-o', str(exe), str(c)], check=True)
        res = subprocess.run([str(exe)], capture_output=True, text=True)
        print(res.stdout, end='')
        assert res.returncode == 0, name + ' checks failed'

# the call site: after the ml885 exact-RIP line, inside the resolved-RIP branch, live RSP first
site = src[src.index('[guest-exact] ml885 block=%p rip=%p x86='):]
site = site[:site.index('unresolved: %s')]
assert '(bytes unreadable)' in site and site.index('(bytes unreadable)') < site.index('ios_guest_fault_context('), 'the call sits inside the if/else'
assert 'ios_guest_fault_context( xrip, REGn_sig(23, context), cs[5] );' in site, 'not called with the live SRA RSP and the saved one'
print('check-guest-ctx: ok')
