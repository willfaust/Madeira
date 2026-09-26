#!/usr/bin/env python3
"""Exercise the production guest-window extension with a mock address map.

No Wine, emulator, guest executable, or device allocation runs on the host.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2]


code = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
typedef uintptr_t ULONG_PTR;
#define IOS_WOW_MAX_WINDOWS 8
#define IOS_WOW_WINDOW_SIZE 0x100000000ULL
#define IOS_CAGE_BASE 0x7200000000ULL
#define IOS_CAGE_REAL_SIZE 0x1ffff0000ULL
#define IOS_WOW_CEF_POOLS_START 0x7400000000ULL
#define IOS_WOW_FEX_BAND_END 0x8000000000ULL
#define IOS_WOW_SPILL_TOP 0x7b00000000ULL
static int ios_wow_spill_walk;
struct ios_wow_window { ULONG_PTR base; int dead, leaked; void *peb, *dead_peb; };
struct ios_wow_placeholder { ULONG_PTR base; unsigned guard_owned, adopted; };
static struct ios_wow_window slots[8];
static struct ios_wow_placeholder ios_wow_placeholders[8];
static unsigned ios_wow_placeholder_count;
static int ios_cage_holdback_live, ios_cage_window_tail_live;
struct region { ULONG_PTR base, size; };
static struct region regions[16];
static unsigned region_count, attempts, registrations;
static ULONG_PTR registered_base, registered_size;
static ULONG_PTR host_page_size = 0x4000;
static struct ios_wow_window *ios_wow_slot_at_base(ULONG_PTR base)
{
    for (unsigned i=0;i<8;i++) if (slots[i].base == base) return &slots[i];
    return NULL;
}
static struct ios_wow_placeholder *ios_wow_placeholder_find(ULONG_PTR base)
{
    for (unsigned i=0;i<ios_wow_placeholder_count;i++)
        if (ios_wow_placeholders[i].base == base) return &ios_wow_placeholders[i];
    return NULL;
}
static void *anon_mmap_tryfixed(void *p, size_t size, int prot, int flags)
{
    ULONG_PTR base=(ULONG_PTR)p;
    assert(prot==PROT_NONE && flags==MAP_NORESERVE);
    attempts++;
    for (unsigned i=0;i<region_count;i++)
        if (base < regions[i].base+regions[i].size && base+size > regions[i].base)
        { errno=EEXIST; return MAP_FAILED; }
    assert(region_count<16);
    regions[region_count++]=(struct region){base,size};
    return p;
}
static void mmap_add_reserved_area(void *p, size_t size)
{ registrations++; registered_base=(ULONG_PTR)p; registered_size=size; }
static int ios_wow_guard_neighbour_blocked(ULONG_PTR a, ULONG_PTR n)
{ (void)a; (void)n; return 0; }
static void ios_va_describe_range(void *p, size_t size, char *b, size_t n)
{ (void)p; (void)size; snprintf(b,n,"occupied mock region"); }
'''
for signature in ['static ULONG_PTR ios_wow_guard_size(', 'static int ios_wow_band_ok(', 'static int ios_wow_window_try(',
                  'static ULONG_PTR ios_wow_extend_holdback_tail(']:
    code += '\n' + function(signature) + '\n'
code += r'''
static void reset(void)
{
    memset(slots,0,sizeof(slots)); memset(ios_wow_placeholders,0,sizeof(ios_wow_placeholders));
    memset(regions,0,sizeof(regions));
    attempts=registrations=ios_wow_placeholder_count=0;
    ios_cage_holdback_live=0; ios_cage_window_tail_live=1;
    /* The first two windows plus the upper held remainder are occupied. */
    slots[0].base=0x7100000000ULL; slots[1].base=0x7200000000ULL;
    regions[0]=(struct region){0x7100000000ULL,0x2ffff0000ULL};
    region_count=1;
    unsetenv("MADEIRA_WOW_EXTRA_WINDOW");
}
int main(void)
{
    unsigned guard=0;
    const ULONG_PTR b=0x7300000000ULL, end=0x7400000000ULL;
    reset();
    assert(!ios_wow_window_try(slots[0].base,&guard));
    assert(!ios_wow_window_try(slots[1].base,&guard));
    assert(ios_wow_extend_holdback_tail(&guard)==b && guard==1);
    assert(attempts==1 && registrations==1);
    assert(regions[1].base==end-0x10000 && regions[1].size==0x14000);
    assert(registered_base==b && registered_size==IOS_WOW_WINDOW_SIZE);
    /* The guard is held by the host but is outside allocatable Wine space. */
    assert(registered_base+registered_size==end);
    assert(anon_mmap_tryfixed((void *)end,0x4000,PROT_NONE,MAP_NORESERVE)==MAP_FAILED);
    attempts--; /* the collision probe is not an extension attempt */
    assert(regions[0].base==0x7100000000ULL && regions[0].size==0x2ffff0000ULL);
    assert(!ios_cage_window_tail_live && !ios_cage_holdback_live);
    assert(!ios_wow_extend_holdback_tail(&guard)); /* no double adoption */
    slots[2].base=b;
    assert(!ios_wow_extend_holdback_tail(&guard)); /* active registry */
    slots[2].dead=1;
    assert(!ios_wow_extend_holdback_tail(&guard)); /* not yet reclaimed */
    slots[2].base=0; ios_wow_placeholders[0].adopted=0;
    assert(ios_wow_extend_holdback_tail(&guard)==b && guard==1);
    assert(attempts==1 && registrations==1); /* reclaimed placeholder reused */

    /* Occupancy at either missing tail or guard must not be overwritten. */
    for (unsigned offset=0;offset<0x14000;offset+=0x4000)
    {
        reset();
        regions[1]=(struct region){end-0x10000+offset,0x4000}; region_count=2;
        struct region before[16]; memcpy(before,regions,sizeof(before));
        assert(!ios_wow_extend_holdback_tail(&guard));
        assert(attempts==1 && !registrations && !ios_wow_placeholder_count);
        assert(!memcmp(before,regions,sizeof(before)) && ios_cage_window_tail_live);
    }
    reset(); setenv("MADEIRA_WOW_EXTRA_WINDOW","0",1);
    assert(!ios_wow_extend_holdback_tail(&guard) && !attempts && !registrations);
    reset(); ios_cage_window_tail_live=0;
    assert(!ios_wow_extend_holdback_tail(&guard) && !attempts);
    reset(); ios_cage_holdback_live=1;
    assert(!ios_wow_extend_holdback_tail(&guard) && !attempts);
    reset(); ios_wow_placeholder_count=IOS_WOW_MAX_WINDOWS;
    assert(!ios_wow_extend_holdback_tail(&guard) && !attempts);
    assert(ios_wow_band_ok(b,IOS_WOW_WINDOW_SIZE));
    assert(!ios_wow_band_ok(end,IOS_WOW_WINDOW_SIZE));
    puts("PASS: three-window chain, guard/tail collisions, retained owners, deferred reuse, ownership and rollback");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-extra-window-') as tmp:
    c = Path(tmp) / 'check.c'
    binary = Path(tmp) / 'check'
    c.write_text(code)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-g', '-O1',
                    '-fsanitize=address,undefined', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
