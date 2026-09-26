#!/usr/bin/env python3
"""ml1570 guest-window band on a small address map (virtual_ios.c ios_wow_band); no Wine runs.

Compiles the production ios_wow_band against a stubbed TASK_VM_INFO and checks: a 63 GB map gets
the band [16 GB, 44 GB) with four placeholders, MADEIRA_WOW_SMALL_VA_SLOTS=2 restores the old
two-slot band, a large map keeps the normal band with no cap, and the placeholder loop stops at
the cap.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
a = src.index("static unsigned ios_wow_small_va_slots;")
b = src.index("static int ios_wow_band_ok( ULONG_PTR base, ULONG_PTR total )")
band = src[a:b]
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uintptr_t ULONG_PTR;
typedef int kern_return_t; typedef unsigned int mach_msg_type_number_t; typedef int task_t; typedef int *task_info_t;
#define KERN_SUCCESS 0
#define TASK_VM_INFO 22
#define TASK_VM_INFO_COUNT 1
typedef struct { unsigned long long max_address; } task_vm_info_data_t;
#define IOS_WOW_WINDOW_SIZE 0x100000000ULL
#define IOS_WOW_MAX_WINDOWS 8
#define IOS_WOW_CEF_POOLS_START ((ULONG_PTR)0x7400000000)
static unsigned long long fake_max;
static task_t mach_task_self( void ) { return 1; }
static kern_return_t task_info( task_t t, int flavor, task_info_t out, mach_msg_type_number_t *cnt ) {
    (void)t; (void)flavor; (void)cnt; ((task_vm_info_data_t *)out)->max_address = fake_max; return KERN_SUCCESS; }
static ULONG_PTR ios_usable_va_floor = 0x7000000000ULL, ios_furniture_ceiling = 0x7400000000ULL;
static void *user_space_limit = (void *)0x7fffffff0000ULL;
#define dprintf(fd, ...) fprintf( stderr, __VA_ARGS__ )
""" + band + r"""
int main( int argc, char **argv ) {
    ULONG_PTR f, c;
    fake_max = strtoull( argv[1], NULL, 0 );
    ios_wow_band( &f, &c );
    printf( "%llx %llx %u\n", (unsigned long long)f, (unsigned long long)c, ios_wow_small_va_slots );
    return 0;
}
"""
def run(exe, maxaddr, env=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    e.update(env or {})
    out = subprocess.run([str(exe), maxaddr], env=e, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.split(), out.stderr

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "band.c"; c.write_text(harness)
    exe = Path(t) / "band"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-Wno-unused-variable", "-fsanitize=address,undefined", str(c), "-o", str(exe)], check=True)
    got, err = run(exe, "0xfc0000000")
    assert got == ["400000000", "b00000000", "4"], got
    assert "SMALL ADDRESS SPACE" in err
    print("PASS: a 63 GB map draws windows from [16 GB, 44 GB) and keeps four")
    got, _ = run(exe, "0xfc0000000", {"MADEIRA_WOW_SMALL_VA_SLOTS": "2"})
    assert got == ["400000000", "600000000", "2"], got
    print("PASS: MADEIRA_WOW_SMALL_VA_SLOTS=2 restores the two-slot band")
    got, _ = run(exe, "0x8000000000")
    assert got == ["7000000000", "7400000000", "0"], got
    print("PASS: a 512 GB map keeps the normal band, no cap")

loop = src[src.index("static void ios_wow_reserve_placeholders(void)\n{"):]
loop = loop[:loop.index("\n}\n")]
assert loop.index("ios_wow_small_va_slots && ios_wow_placeholder_count >= ios_wow_small_va_slots") < loop.index("ios_wow_window_try( cand, &guard_owned )")
print("PASS: session start stops taking placeholders at the cap, skipping slots iOS refuses")
