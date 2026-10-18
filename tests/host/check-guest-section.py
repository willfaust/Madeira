#!/usr/bin/env python3
"""Compile and exercise the real section policy and notification helpers.

This runs on the build host. It does not emulate FEX or prove iPhone execution;
launch tests/x64/shared-section-x64.exe for the end-to-end regression.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
wine = (root / 'wine/dlls/ntdll/signal_arm64ec.c').read_text()


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2] + '\n'


flags = '\n'.join(re.findall(r'^#define VPROT_\w+\s+0x[0-9a-fA-F]+', native, re.M))
policy = function(native, 'static int ios_guest_section_is_host_data(')
covers = function(native, 'static int ios_x64_image_view_covers(')
notify = function(wine, 'static void notify_mapped_section_protection(')
map_notify = function(wine, 'static void notify_map_view_of_section(')
program = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#define WINE_IOS 1
#define SEC_FILE 0x800000
#define SEC_IMAGE 0x1000000
#define SEC_RESERVE 0x4000000
#define SEC_COMMIT 0x8000000
#define IOS_X64_IMAGE_HOST_PAGE 0x4000u
struct file_view { void *base; size_t size; unsigned int protect; };
static struct file_view view = {(void *)0x10000, 0x11000, SEC_COMMIT};
static int arm64ec_view = 1, ios_alloc_ec_code, wow, found = 1;
static int ios_wow_in_window(const void *p) { (void)p; return wow; }
static struct file_view *find_view(const void *p, size_t s)
{ (void)p; (void)s; return found ? &view : NULL; }
''' + flags + '\n' + covers + policy + r'''
typedef size_t SIZE_T;
typedef unsigned int ULONG;
typedef int NTSTATUS;
typedef int HANDLE;
typedef struct { char *BaseAddress; SIZE_T RegionSize; ULONG State, Protect; } MEMORY_BASIC_INFORMATION;
typedef struct { ULONG Attributes; } SECTION_BASIC_INFORMATION;
typedef struct { int unused; } SECTION_IMAGE_INFORMATION;
#define MEM_COMMIT 0x1000
#define MemoryBasicInformation 0
#define SectionBasicInformation 0
#define SectionImageInformation 1
#define FALSE 0
#define TRUE 1
#define STATUS_SUCCESS 0
#define NT_SUCCESS(s) ((s) >= 0)
#define min(a,b) ((a)<(b)?(a):(b))
#define ERR(...) ((void)0)
static struct { struct { void *ArbitraryUserPointer; } Tib; } teb;
#define NtCurrentTeb() (&teb)
#define GetCurrentProcess() 1
static char memory[0x8000];
static unsigned int queries, calls, image_calls, unmapped;
static int query_fail, basic_fail, image_fail, image_result;
static ULONG attributes;
static MEMORY_BASIC_INFORMATION regions[4];
static struct { void *addr; SIZE_T size; ULONG prot; int after; NTSTATUS status; } events[8];
static int NtQueryVirtualMemory(int process, void *addr, int kind, MEMORY_BASIC_INFORMATION *out,
                                SIZE_T size, void *ret)
{
    (void)process; (void)addr; (void)kind; (void)size; (void)ret;
    if (query_fail || queries >= 4) return -1;
    *out = regions[queries++]; return 0;
}
static int NtQuerySection(HANDLE h, int kind, void *out, SIZE_T size, void *ret)
{
    (void)h; (void)size; (void)ret;
    if (kind == SectionBasicInformation)
    { ((SECTION_BASIC_INFORMATION *)out)->Attributes = attributes; return basic_fail; }
    return image_fail;
}
static void record(void *addr, SIZE_T size, ULONG prot, int after, NTSTATUS status)
{
    assert(calls < 8);
    events[calls].addr = addr; events[calls].size = size; events[calls].prot = prot;
    events[calls].after = after; events[calls++].status = status;
}
static void (*pNotifyMemoryProtect)(void *,SIZE_T,ULONG,int,NTSTATUS) = record;
static NTSTATUS image(void *a,void *b,void *c,SIZE_T s,ULONG al,ULONG p)
{ (void)a; (void)b; (void)c; (void)s; (void)al; (void)p; image_calls++; return image_result; }
static NTSTATUS (*pNotifyMapViewOfSection)(void *,void *,void *,SIZE_T,ULONG,ULONG) = image;
static void ios_note_big_image(void *p, SIZE_T s) { (void)p; (void)s; }
static int NtUnmapViewOfSection(int p, void *a) { (void)p; (void)a; unmapped++; return 0; }
''' + notify + map_notify + r'''
int main(void)
{
    NTSTATUS status = 0;
    assert(ios_guest_section_is_host_data((void *)0x10000, 0x14000));
    assert(!ios_guest_section_is_host_data((void *)0x10000, 0x18000));
    assert(!ios_guest_section_is_host_data((void *)0xf000, 0x1000));
    assert(!ios_guest_section_is_host_data((void *)0x10000, (SIZE_T)-1));
    unsigned int exclusions[] = {SEC_FILE, SEC_IMAGE, VPROT_ARM64EC, VPROT_SYSTEM};
    for (unsigned int i=0; i<sizeof(exclusions)/sizeof(*exclusions); i++)
    { view.protect = SEC_COMMIT | exclusions[i]; assert(!ios_guest_section_is_host_data(view.base, 0x1000)); }
    view.protect = VPROT_READ | VPROT_WRITE | VPROT_EXEC;
    assert(!ios_guest_section_is_host_data(view.base, 0x1000)); /* native allocation */
    view.protect = SEC_RESERVE;
    assert(ios_guest_section_is_host_data(view.base, 0x1000));
    ios_alloc_ec_code = 1; assert(!ios_guest_section_is_host_data(view.base, 0x1000)); ios_alloc_ec_code = 0;
    arm64ec_view = 0; assert(!ios_guest_section_is_host_data(view.base, 0x1000)); arm64ec_view = 1;
    wow = 1; assert(!ios_guest_section_is_host_data(view.base, 0x1000)); wow = 0;
    found = 0; assert(!ios_guest_section_is_host_data(view.base, 0x1000));
    puts("PASS: pagefile section policy, native/image/file exclusions, rounded boundaries");

    regions[0] = (MEMORY_BASIC_INFORMATION){memory, 0x1000, MEM_COMMIT, 0x20};
    regions[1] = (MEMORY_BASIC_INFORMATION){memory+0x1000, 0x1000, 0x2000, 0}; /* reserved */
    regions[2] = (MEMORY_BASIC_INFORMATION){memory+0x2000, 0x4000, MEM_COMMIT, 4};
    /* No loader name, and no image callback: non-image sections must still notify. */
    pNotifyMapViewOfSection = NULL;
    notify_map_view_of_section(1, memory, 0x4000, 0, 0x20, &status);
    assert(status == 0 && calls == 4 && image_calls == 0 && queries == 3);
    assert(events[0].addr == memory && events[0].size == 0x1000 && events[0].prot == 0x20);
    assert(!events[0].after && events[1].after && !events[1].status);
    assert(events[2].addr == memory+0x2000 && events[2].size == 0x2000 && events[2].prot == 4);
    assert(!events[2].after && events[3].after);
    calls = queries = 0; query_fail = 1;
    notify_mapped_section_protection(memory, sizeof(memory)); assert(!calls);
    query_fail = 0; regions[0].RegionSize = 0;
    notify_mapped_section_protection(memory, sizeof(memory)); assert(!calls);
    pNotifyMemoryProtect = NULL; queries = 0;
    notify_mapped_section_protection(memory, sizeof(memory)); assert(!queries);
    puts("PASS: non-image notifications, reserved holes, range clipping, callback pairing and query failures");

    pNotifyMapViewOfSection = image; attributes = SEC_IMAGE;
    notify_map_view_of_section(1, memory, sizeof(memory), 0, 0x20, &status);
    assert(!image_calls); /* original loader gate retained */
    teb.Tib.ArbitraryUserPointer = memory;
    notify_map_view_of_section(1, memory, sizeof(memory), 0, 0x20, &status);
    assert(image_calls == 1 && !calls);
    image_result = -1;
    notify_map_view_of_section(1, memory, sizeof(memory), 0, 0x20, &status);
    assert(status == -1 && unmapped == 1);
    puts("PASS: image path and image-callback failure handling unchanged");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'section.c'
    binary = Path(tmp) / 'section-test'
    source.write_text(program)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
