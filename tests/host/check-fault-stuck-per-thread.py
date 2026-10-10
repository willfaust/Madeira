#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""The [fault-stuck] loop breaker counts per thread (build/ntdll-unix/signal_arm64_ios.c).

The Mach exception handler diverts a thread to abort_thread when the same (page, pc,
address) fault is declined 50 times in a row. That count was one app-wide counter, never
restarted when the exception reached the guest: 25 threads each faulting once at the same
instruction (each fault is declined from the thread port and then the task port) were
counted as one stuck thread and the next was diverted, and one thread whose handler
continued past int3 or single-step exceptions at one instruction was diverted after about
50 of them. No exception reached the program for the diverted thread; Windows delivers
every one. The state now lives in 16 slots chosen by thread, and every exception delivered
to the guest (setup_raise_exception, or the Mach-path delivery) starts that thread's count
again.

Compiles the breaker block verbatim from ios_mach_exception_thread, with the delivery
counter it reads, against stand-ins for the Mach thread-state calls, under AddressSanitizer
and UBSan, and checks:
  * one thread, 100 delivered exceptions at one instruction: none diverted;
  * 100 threads one after another, and 300 alive at once, one fault each at one
    instruction and address: none diverted;
  * a thread re-faulting at one address with no delivery is still diverted, on its 51st
    decline, also while other threads fault in between;
  * the page storm ceiling (same page and pc, addresses advancing, no delivery) still
    diverts after 20000;
  * both delivery paths restart the count, the Mach one only after the frame is written.
Synthetic thread ids and addresses only: no Wine, iOS or device.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text().replace('\r\n', '\n')
CC = os.environ.get('CC') or shutil.which('cc') or 'cc'
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def function(head):
    start = src.index(head)
    return src[start:src.index('\n}\n', start) + 3]


def before(text, first, second):
    return first in text and second in text and text.index(first) < text.index(second)


def braced(start):
    """the brace-balanced block opening at src[start], skipping comments and literals"""
    depth, i = 0, start
    while True:
        if src.startswith('/*', i):
            i = src.index('*/', i) + 2
            continue
        if src.startswith('//', i):
            i = src.index('\n', i)
            continue
        c = src[i]
        if c in '"\'':
            j = i + 1
            while src[j] != c:
                j += 2 if src[j] == '\\' else 1
            i = j + 1
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if not depth:
                return src[start:i + 1]
        i += 1


helpers = src[src.index('static volatile unsigned ios_guest_deliv_seq[16];'):]
helpers = helpers[:helpers.index('\n}\n', helpers.index('static inline void ios_note_guest_delivery( uint64_t thread )')) + 3]
marker = src.index('LIVELOCK BREAKER, keyed on the faulting PAGE.')
breaker = braced(src.index('{', src.index('*/', marker)))
raise_fn = function('static void setup_raise_exception( ucontext_t *sigcontext, EXCEPTION_RECORD *rec, CONTEXT *context )')
deliver_fn = function('static int ios_mach_deliver_guest_exception_inner( thread_t thread, arm_thread_state64_t *state,')

# ------------------------------------------------------------------ static
require('static volatile uint64_t stuck_page;' not in src and 'stuck_n' not in breaker,
        'no app-wide breaker state is left')
require(breaker.startswith('{\n                        static struct { uint64_t thread, page, pc, addr; uint32_t n, page_n; unsigned seq; } stk[16];')
        and 'const int ss = ios_fault_slot( (uint64_t)thread );' in breaker,
        'the breaker state is chosen by the faulting thread')
require(before(raise_fn, 'ios_note_guest_delivery( (uint64_t)pthread_mach_thread_np( pthread_self() ) );',
               'send_debug_event( rec, context, TRUE, TRUE );'),
        'setup_raise_exception restarts the count of the thread it raises on')
require(deliver_fn.count('ios_note_guest_delivery(') == 1
        and '*state = mc.__ss;\n    ios_note_guest_delivery( (uint64_t)thread );' in deliver_fn
        and before(deliver_fn, 'mach_vm_write( mach_task_self()', 'ios_note_guest_delivery('),
        'the Mach-path delivery restarts the count only once the dispatch frame is written')
require(src.count('ios_note_guest_delivery(') == 3, 'two delivery points, and no other caller')

harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* stand-ins for the Mach calls and types the block uses, renamed so that no system
 * header can collide with them */
#define thread_t                       t_thread_t
#define thread_state_t                 t_thread_state_t
#define arm_thread_state64_t           t_arm_thread_state64_t
#define mach_msg_type_number_t         t_mach_msg_type_number_t
#define mach_port_t                    t_mach_port_t
#define mach_vm_address_t              t_mach_vm_address_t
#define mach_vm_size_t                 t_mach_vm_size_t
#define vm_region_basic_info_data_64_t t_vm_region_basic_info_data_64_t
#define vm_region_info_t               t_vm_region_info_t
#define thread_set_state               t_thread_set_state
#define mach_task_self                 t_mach_task_self
#define mach_vm_region                 t_mach_vm_region
#undef __darwin_arm_thread_state64_get_sp
#undef __darwin_arm_thread_state64_set_sp
#undef __darwin_arm_thread_state64_set_pc_fptr
#define __darwin_arm_thread_state64_get_sp(ts)         ((ts).__sp)
#define __darwin_arm_thread_state64_set_sp(ts, v)      ((ts).__sp = (v))
#define __darwin_arm_thread_state64_set_pc_fptr(ts, f) ((ts).__pc = (uint64_t)(uintptr_t)(f))
#define ARM_THREAD_STATE64             6
#define VM_REGION_BASIC_INFO_64        9
#define VM_REGION_BASIC_INFO_COUNT_64  9
#define MACH_PORT_NULL                 0
#define KERN_SUCCESS                   0
typedef uint32_t thread_t;
typedef uint32_t mach_port_t;
typedef void *thread_state_t;
typedef unsigned int mach_msg_type_number_t;
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef int *vm_region_info_t;
typedef struct { uint64_t __x[29], __fp, __lr, __sp, __pc; } arm_thread_state64_t;
typedef struct { int protection, max_protection; } vm_region_basic_info_data_64_t;

static int set_state_calls;
static arm_thread_state64_t last_set;
static int thread_set_state( thread_t t, int flavor, thread_state_t s, mach_msg_type_number_t c )
{
    set_state_calls++;
    last_set = *(arm_thread_state64_t *)s;
    return 0;
}
static mach_port_t mach_task_self( void ) { return 0; }
static int mach_vm_region( mach_port_t task, mach_vm_address_t *a, mach_vm_size_t *s, int flavor,
                           vm_region_info_t info, mach_msg_type_number_t *c, mach_port_t *o )
{
    return 1;   /* no region: the map dump stops at once */
}
void abort_thread( int status ) { }
'''

harness_main = r'''
static int diverted;

/* the Mach handler declining one fault of `thread` (nothing else claimed it) */
static void decline( thread_t thread, uintptr_t fault_addr, uint64_t fault_pc_check )
{
    arm_thread_state64_t state;
    mach_msg_type_number_t count = 68;
    int handled = 0;

    memset( &state, 0, sizeof(state) );
    state.__sp = 0x70000ff238;
BREAKER
    if (handled) diverted++;
}

/* one guest fault: declined from the thread port, then from the task port; then the
 * exception reaches the guest (setup_raise_exception) when `delivered` */
static void fault( thread_t thread, uintptr_t addr, uint64_t pc, int delivered )
{
    decline( thread, addr, pc );
    decline( thread, addr, pc );
    if (delivered) ios_note_guest_delivery( thread );
}

static thread_t other_slot( thread_t t )
{
    thread_t u = t + 0x100;
    while (ios_fault_slot( u ) == ios_fault_slot( t )) u += 0x100;
    return u;
}

static int check( int ok, const char *label ) { printf( "%s: %s\n", ok ? "PASS" : "FAIL", label ); return !ok; }

int main( void )
{
    const uintptr_t addr = 0x7ff0001000;      /* a PAGE_NOACCESS guest page */
    const uint64_t pc = 0x1400012a4;
    thread_t t, stuck, other;
    int bad = 0, i;

    for (i = 0; i < 100; i++) fault( 0x1503, addr, pc, 1 );
    bad |= check( !diverted, "one thread, 100 delivered exceptions at one instruction: none diverted" );

    diverted = 0;
    for (i = 0; i < 100; i++) fault( 0x2003 + 0x100 * i, addr, pc, 1 );
    bad |= check( !diverted, "100 threads one after another, one fault each at one instruction: none diverted" );

    diverted = 0;
    for (i = 0; i < 300; i++) decline( 0x9003 + 0x100 * i, addr, pc );
    for (i = 0; i < 300; i++) decline( 0x9003 + 0x100 * i, addr, pc );
    for (i = 0; i < 300; i++) ios_note_guest_delivery( 0x9003 + 0x100 * i );
    bad |= check( !diverted, "300 threads at once, one fault each at one instruction: none diverted" );

    diverted = 0;
    stuck = 0x40003;
    for (i = 0; i < 50; i++) decline( stuck, addr, pc );
    bad |= check( !diverted, "a thread re-faulting with no delivery: not diverted after 50 declines" );
    set_state_calls = 0;
    decline( stuck, addr, pc );
    bad |= check( diverted == 1 && set_state_calls == 1 && last_set.__pc == (uint64_t)(uintptr_t)abort_thread
                  && last_set.__x[0] == 1 && !(last_set.__sp & 0xf),
                  "... diverted to abort_thread(1) on the 51st, with an aligned stack" );

    diverted = 0;
    stuck = 0x50003;
    other = other_slot( stuck );
    for (i = 0; i < 50; i++)
    {
        decline( stuck, addr, pc );
        fault( other, addr + 0x40, pc + 8, 1 );
    }
    bad |= check( !diverted, "a stuck thread with another thread faulting in between: not diverted after 50 declines" );
    decline( stuck, addr, pc );
    bad |= check( diverted == 1, "... diverted on its 51st decline, the other thread never" );

    diverted = 0;
    t = 0x60003;
    for (i = 0; i < 49; i++) decline( t, addr, pc );
    ios_note_guest_delivery( t );
    for (i = 0; i < 49; i++) decline( t, addr, pc );
    bad |= check( !diverted, "an exception delivered to the thread starts its count again" );

    diverted = 0;
    t = 0x70003;
    for (i = 0; i < 20000; i++) decline( t, addr + (i & 1) * 8, pc );
    bad |= check( !diverted, "same page and pc, addresses advancing, no delivery: not diverted after 20000" );
    decline( t, addr + 16, pc );
    bad |= check( diverted == 1, "... the storm ceiling diverts on the next one" );
    return bad;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'fault_stuck.c'
    exe = Path(tmp) / 'fault_stuck'
    c.write_text(harness + helpers + harness_main.replace('BREAKER', breaker))
    build = subprocess.run([CC, '-std=gnu11', '-g', '-O1', '-Wall', '-Wno-unused-function', '-Wno-unused-variable',
                            '-Werror=implicit-function-declaration',
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined', str(c), '-o', str(exe)],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'harness compiles (ASan + UBSan)')
    if build.returncode:
        print(build.stderr[-4000:])
    else:
        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), timeout=120)
        print(run.stdout, end='')
        require(run.returncode == 0, 'every case passed, no sanitizer report')
        if run.returncode:
            print(run.stderr[-4000:])
        breaks = [l for l in run.stderr.splitlines() if l.startswith('[fault-stuck] BREAKING LOOP')]
        require(len(breaks) == 3, f'the log names each of the 3 diversions (got {len(breaks)})')

print('PASS' if not failures else f'FAILED ({failures})')
sys.exit(1 if failures else 0)
