#!/usr/bin/env python3
"""Check native/guest allocation bounds using production allocator decisions.

Runs only a mock address-range harness, never Wine or an emulator.
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
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uintptr_t ULONG_PTR;
#define IOS_WOW_WINDOW_SIZE 0x100000000ULL
static ULONG_PTR current_base;
static ULONG_PTR ios_wow_base(void) { return current_base; }
struct window { ULONG_PTR base; unsigned guard_owned; };
struct placeholder { ULONG_PTR base; unsigned guard_owned, adopted; };
static struct window ios_wow_windows[3];
static struct placeholder ios_wow_placeholders[3];
static unsigned ios_wow_window_count, ios_wow_placeholder_count;
static ULONG_PTR ios_wow_guard_size(void) { return 0x4000; }
static ULONG_PTR ios_wow_slot_reservation(const struct window *w)
{ return IOS_WOW_WINDOW_SIZE + (w->guard_owned ? ios_wow_guard_size() : 0); }
'''
for signature in ['int ios_wow_in_window(', 'static int ios_wow_limits_in_window(',
                  'static void ios_wow_exclude_range(', 'static void ios_wow_exclude_windows(']:
    code += '\n' + function(signature) + '\n'
start = source.index('        if (!ios_wow_limits_in_window( limit_low, limit_high ))')
block = source[start:source.index('        /* Keep the one remaining', start)]
code += '''
static void placement(ULONG_PTR limit_low, ULONG_PTR limit_high, ULONG_PTR *lo, ULONG_PTR *hi)
{
    void *start=(void *)limit_low, *end=(void *)(limit_high+1);
''' + block + '''
    *lo=(ULONG_PTR)start; *hi=(ULONG_PTR)end;
}
'''
start = source.index('        if (ios_wow_laa_synth && ios_wow_laa_low_first() && !base &&')
condition = source[start:source.index('\n        {', start)]
code += '''
static int low_first(ULONG_PTR limit_low, ULONG_PTR limit_high)
{
    int ios_wow_laa_synth=1; void *base=NULL;
#define ios_wow_laa_low_first() 1
''' + condition + ''' return 1;
    return 0;
}
'''
code += r'''
int main(int argc, char **argv)
{
    assert(argc==2);
    int fixed=atoi(argv[1]);
    setenv("MADEIRA_WOW_STRICT_LIMITS",argv[1],1);
    const ULONG_PTR host_low=0x100010000ULL, host_high=0x73fffeffffULL;
    ULONG_PTR lo, hi;
    for (unsigned i=0;i<3;i++) ios_wow_windows[i].base=0x7100000000ULL+i*IOS_WOW_WINDOW_SIZE;
    ios_wow_window_count=3;
    ios_wow_windows[2].guard_owned=1;
    for (unsigned i=0;i<3;i++)
    {
        current_base=ios_wow_windows[i].base;
        placement(host_low,host_high,&lo,&hi);
        assert(lo==host_low);
        if (!fixed && i==2)
        {
            /* Reproduce the logged native DLL allocation inside slot three. */
            assert(hi==host_high+1 && hi-0x70000>=current_base);
            assert(low_first(host_low,host_high));
        }
        else
        {
            assert(hi==ios_wow_windows[0].base);
            assert(!low_first(host_low,host_high));
        }
        /* Normal and high-half guest requests keep their entire range. */
        for (unsigned half=0;half<2;half++)
        {
            ULONG_PTR gl=current_base+(half ? 0x80000000ULL : 0x110000ULL);
            ULONG_PTR gh=current_base+0xfffeffffULL;
            assert(ios_wow_limits_in_window(gl,gh));
            placement(gl,gh,&lo,&hi); assert(lo==gl && hi==gh+1);
            assert(low_first(gl,gh));
        }
        assert(!ios_wow_limits_in_window(current_base,0));
        assert(!ios_wow_limits_in_window(current_base,current_base+IOS_WOW_WINDOW_SIZE));
        if (fixed)
        {
            assert(!ios_wow_limits_in_window(0,current_base+0x7fffffff));
            assert(!ios_wow_limits_in_window(current_base+0x80000000,current_base+0x70000000));
        }
    }
    /* Real translated low-band requests on smaller VA devices are unchanged. */
    current_base=0x400000000ULL;
    assert(ios_wow_limits_in_window(current_base+0x110000,current_base+0x7fffffff));
    assert(!ios_wow_limits_in_window(host_low,host_high));
    current_base=0;
    assert(!ios_wow_limits_in_window(host_low,host_high));
    puts(fixed ? "PASS: native exclusion in all three windows, guest bounds, low-first policy and low VA" :
                 "PASS: rollback reproduces native DLL placement inside third guest window");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-window-placement-') as tmp:
    c = Path(tmp) / 'check.c'
    binary = Path(tmp) / 'check'
    c.write_text(code)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-g', '-O1',
                    '-fsanitize=address,undefined', str(c), '-o', str(binary)], check=True)
    for enabled in ['0', '1']:
        subprocess.run([str(binary), enabled], check=True)
