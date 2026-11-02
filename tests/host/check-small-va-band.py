#!/usr/bin/env python3
"""Guest-window band and small-map rule (virtual_ios.c ios_wow_band / ios_wow_map_allows_window); no Wine runs.

Compiles the production band and small-map code against a stubbed TASK_VM_INFO / mach_vm_region
and checks: a 63 GB map draws windows from [16 GB, 44 GB) with at most two alive at once,
MADEIRA_WOW_SMALL_VA_SLOTS raises that maximum, a 512 GB map keeps the normal band with no cap,
a 40 GB map is refused, and a map with too little free VA left over is refused.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
a = src.index("static ULONG_PTR ios_wow_map_end(void)")
b = src.index("/* One slot below the FEX band's start")
band = src[a:b]
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef uintptr_t ULONG_PTR;
typedef int kern_return_t; typedef unsigned int mach_msg_type_number_t; typedef int task_t; typedef int *task_info_t;
typedef uint64_t mach_vm_address_t, mach_vm_size_t; typedef int mach_port_t; typedef int *vm_region_info_t;
typedef struct { int protection; } vm_region_basic_info_data_64_t;
#define KERN_SUCCESS 0
#define TASK_VM_INFO 22
#define TASK_VM_INFO_COUNT 1
#define VM_REGION_BASIC_INFO_64 9
#define VM_REGION_BASIC_INFO_COUNT_64 1
#define MACH_PORT_NULL 0
typedef struct { unsigned long long max_address; } task_vm_info_data_t;
#define IOS_WOW_WINDOW_SIZE 0x100000000ULL
#define IOS_WOW_MAX_WINDOWS 8
#define IOS_WOW_CEF_POOLS_START ((ULONG_PTR)0x7400000000)
static unsigned long long fake_max;
static ULONG_PTR used_lo, used_hi;   /* one occupied region [used_lo, used_hi) */
static task_t mach_task_self( void ) { return 1; }
static kern_return_t task_info( task_t t, int flavor, task_info_t out, mach_msg_type_number_t *cnt ) {
    (void)t; (void)flavor; (void)cnt; ((task_vm_info_data_t *)out)->max_address = fake_max; return KERN_SUCCESS; }
static kern_return_t mach_vm_region( task_t t, mach_vm_address_t *a, mach_vm_size_t *s, int f, vm_region_info_t i,
                                     mach_msg_type_number_t *c, mach_port_t *o ) {
    (void)t; (void)f; (void)i; (void)c; (void)o;
    if (!used_hi || *a >= used_hi) return 1;
    if (*a < used_lo) *a = used_lo;
    *s = used_hi - *a; return KERN_SUCCESS; }
static ULONG_PTR ios_usable_va_floor = 0x7038000000ULL, ios_furniture_ceiling = 0x73ffff0000ULL;
static void *user_space_limit = (void *)0x7fffffff0000ULL;
unsigned long long ios_layerkit_lo, ios_layerkit_hi;   /* no CoreAnimation range measured */
#define dprintf(fd, ...) fprintf( stderr, __VA_ARGS__ )
""" + band + r"""
int main( int argc, char **argv ) {
    ULONG_PTR f, c;
    fake_max = strtoull( argv[1], NULL, 0 );
    if (argc > 3) { used_lo = strtoull( argv[2], NULL, 0 ); used_hi = strtoull( argv[3], NULL, 0 ); }
    ios_wow_band( &f, &c );
    printf( "%llx %llx %u %d\n", (unsigned long long)f, (unsigned long long)c, ios_wow_small_va_slots,
            ios_wow_map_allows_window() );
    return 0;
}
"""
def run(exe, *args, env=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    e.update(env or {})
    out = subprocess.run([str(exe), *args], env=e, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.split(), out.stderr

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "band.c"; c.write_text(harness)
    exe = Path(t) / "band"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-Wno-unused-variable", "-fsanitize=address,undefined", str(c), "-o", str(exe)], check=True)
    got, err = run(exe, "0xfc0000000")
    assert got == ["400000000", "b00000000", "2", "1"], got
    assert "small address map" in err
    print("PASS: a 63 GB map draws windows from [16 GB, 44 GB), at most two at once, and allows a window")
    got, _ = run(exe, "0xfc0000000", env={"MADEIRA_WOW_SMALL_VA_SLOTS": "4"})
    assert got == ["400000000", "b00000000", "4", "1"], got
    print("PASS: MADEIRA_WOW_SMALL_VA_SLOTS=4 raises the maximum")
    got, _ = run(exe, "0x8000000000")
    assert got == ["7038000000", "73ffff0000", "0", "1"], got
    print("PASS: a 512 GB map keeps the normal band, no cap")
    got, err = run(exe, "0xa00000000")
    assert got[3] == "0" and "refused: map too small" in err, (got, err)
    print("PASS: a 40 GB map refuses a window (MADEIRA_WOW_MIN_MAP_GB default 48)")
    got, err = run(exe, "0xa00000000", env={"MADEIRA_WOW_MIN_MAP_GB": "32"})
    assert got[3] == "1", (got, err)
    print("PASS: MADEIRA_WOW_MIN_MAP_GB lowers the floor")
    # 63 GB map with [4 GB, 54 GB) occupied: 9 GB free, less than 4 GB + 8 GB
    got, err = run(exe, "0xfc0000000", "0x100000000", "0xd80000000")
    assert got[3] == "0" and "refused: map too small" in err, (got, err)
    print("PASS: a map with less than 4 GB + MADEIRA_WOW_MIN_FREE_GB of free VA refuses")
    # [4 GB, 40 GB) occupied: 23 GB free
    got, err = run(exe, "0xfc0000000", "0x100000000", "0xa00000000")
    assert got[3] == "1", (got, err)
    print("PASS: enough free VA outside the window allows it")

pick = src[src.index("static void ios_wow_reserve_placeholders( unsigned max )\n{"):]
pick = pick[:pick.index("\n}\n")]
assert "ios_wow_small_va_slots && max > ios_wow_small_va_slots" in pick
print("PASS: placeholders (opt-in / 32-bit main image only) never exceed the small-map maximum")
