#!/usr/bin/env python3
"""[cef-cmdline]: libcef.dll's cef_initialize goes through a thunk that lets CEF read the command line; no Wine runs.

BeamNG.drive (build 70, 2026-11-02/03): every CEF process needs its own two
32 GB-aligned PartitionAlloc pools and the 64 GB band holds one set, so the
game's gpu/network/storage/renderer processes died (80000003). --single-process
on the game's command line (env.MADEIRA_CHILD_ARGS) never reached Chromium:
CEF drops the process command line when cef_settings_t.command_line_args_disabled
is set. build/ntdll-unix/virtual_ios.c's ios_cef_cmdline_patch (opt-in,
env.MADEIRA_CEF_CMDLINE = 1, only in programs named by env.MADEIRA_CEF_PA_EXES)
points the cef_initialize export at a 38-byte x64 thunk in its section's zero
tail; the thunk clears the field at +0x64 when it is 1 and the struct size is
0x68..0x1000, then jumps to the real function.

Compiles ios_cef_cmdline_site / ios_cef_cmdline_apply against a synthetic PE
image and checks: the export slot moves to the cave and the cave holds the
thunk with the right rel32; refusals (no export, forwarded export, non-zero
tail, no room, 32-bit image). On an x86-64 host it also RUNS the patched export
(ms_abi) in an executable copy of the image, with a stand-in cef_initialize
that returns the field: the flag is cleared only for a CEF 128+-shaped struct
and the call always reaches the real function with its arguments intact.
Textually: the patch is opt-in, libcef.dll-only, listed-process-only, and is
called beside [sc-rph] before the [x64-image] early return.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(src, sig):
    start = src.index(sig)
    return src[start:src.index('\n}\n', start) + 3]


patch = function(native, 'static void ios_cef_cmdline_patch(')
assert "enabled = e && e[0] == '1';" in patch, 'opt-in'
assert '"libcef.dll"' in patch and 'ios_cef_pa_listed( pp->ImagePathName.Buffer' in patch
call = native.index('    ios_cef_cmdline_patch( ptr, total_size, nt, sec, nt_name );')
assert native.index('    ios_sc_render_handler_patch( ptr, total_size, nt, sec, nt_name );') < call
assert call < native.index('if (ios_x64_image_nocopy_enabled() && !ios_map_resource_view', call), \
    'before the [x64-image] early return'
print('PASS: [cef-cmdline] is opt-in, libcef.dll in a listed program only, applied before protections')

thunk = native[native.index('static const unsigned char ios_cef_cmdline_thunk[38]'):]
thunk = thunk[:thunk.index('};') + 2] + '\n#define IOS_CEF_CMDLINE_JMP 33\n'
code = thunk + function(native, 'static const char *ios_cef_cmdline_site(') + \
    function(native, 'static void ios_cef_cmdline_apply(') + \
    function(native, 'static void ios_cef_cmdline_grow_section(')

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
typedef uint32_t DWORD; typedef uint16_t WORD; typedef uint8_t BYTE; typedef uint64_t ULONGLONG;
typedef size_t SIZE_T;
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_NT_OPTIONAL_HDR64_MAGIC 0x20b
#define IMAGE_DIRECTORY_ENTRY_EXPORT 0
#define IMAGE_SCN_MEM_EXECUTE 0x20000000
typedef struct { DWORD VirtualAddress, Size; } IMAGE_DATA_DIRECTORY;
typedef struct { WORD Machine, NumberOfSections; DWORD TimeDateStamp, PointerToSymbolTable, NumberOfSymbols;
                 WORD SizeOfOptionalHeader, Characteristics; } IMAGE_FILE_HEADER;
typedef struct { WORD Magic; DWORD SectionAlignment, NumberOfRvaAndSizes; IMAGE_DATA_DIRECTORY DataDirectory[16]; }
    IMAGE_OPTIONAL_HEADER64;
typedef struct { DWORD Signature; IMAGE_FILE_HEADER FileHeader; IMAGE_OPTIONAL_HEADER64 OptionalHeader; }
    IMAGE_NT_HEADERS64;
typedef struct { BYTE Name[8]; union { DWORD VirtualSize; } Misc; DWORD VirtualAddress, SizeOfRawData,
                 PointerToRawData, PointerToRelocations, PointerToLinenumbers; WORD NumberOfRelocations,
                 NumberOfLinenumbers; DWORD Characteristics; } IMAGE_SECTION_HEADER;
typedef struct { DWORD Characteristics, TimeDateStamp; WORD MajorVersion, MinorVersion; DWORD Name, Base,
                 NumberOfFunctions, NumberOfNames, AddressOfFunctions, AddressOfNames, AddressOfNameOrdinals; }
    IMAGE_EXPORT_DIRECTORY;
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)
''' + code + r'''
#define SIZE 0x4000
#define TEXT 0x1000
#define FN   0x1100      /* cef_initialize */
#define OTHER 0x1000     /* another export */
#define TEXT_VS 0x200    /* text ends at 0x1200; tail to 0x2000 is zero */
#define EDATA 0x2000

static unsigned char *img;
static IMAGE_NT_HEADERS64 nt;
static IMAGE_SECTION_HEADER sec[2];

static void build( WORD machine, int forwarded, int dirty_tail, DWORD text_vs, int with_export )
{
    IMAGE_EXPORT_DIRECTORY *e;
    DWORD *funcs, *names; WORD *ords;
    memset( img, 0, SIZE );
    memset( &nt, 0, sizeof(nt) ); memset( sec, 0, sizeof(sec) );
    nt.FileHeader.Machine = machine; nt.FileHeader.NumberOfSections = 2;
    nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC; nt.OptionalHeader.SectionAlignment = 0x1000;
    nt.OptionalHeader.NumberOfRvaAndSizes = 16;
    sec[0].VirtualAddress = TEXT; sec[0].Misc.VirtualSize = text_vs; sec[0].Characteristics = IMAGE_SCN_MEM_EXECUTE;
    sec[1].VirtualAddress = EDATA; sec[1].Misc.VirtualSize = 0x1000;
    /* stand-in cef_initialize: return dword [rdx+0x64] + 0x100 * (rcx == 0x1234) */
    {
        static const unsigned char fn[] = { 0x8b,0x42,0x64,                   /* mov eax,[rdx+0x64] */
                                            0x48,0x81,0xf9,0x34,0x12,0,0,      /* cmp rcx,0x1234 */
                                            0x75,0x05,                         /* jne +5 */
                                            0x05,0x00,0x01,0,0,                /* add eax,0x100 */
                                            0xc3 };                            /* ret */
        memcpy( img + FN, fn, sizeof(fn) );
        img[OTHER] = 0xc3;
    }
    if (dirty_tail == 1) img[TEXT + text_vs + 20] = 0x90;
    if (dirty_tail == 2) memset( img + TEXT + text_vs, 0xcc, 0x200 );   /* lld-link int3 padding */
    if (!with_export) return;
    nt.OptionalHeader.DataDirectory[0].VirtualAddress = EDATA;
    nt.OptionalHeader.DataDirectory[0].Size = 0x200;
    e = (IMAGE_EXPORT_DIRECTORY *)(img + EDATA);
    e->NumberOfFunctions = 2; e->NumberOfNames = 2;
    e->AddressOfFunctions = EDATA + 0x40; e->AddressOfNames = EDATA + 0x60; e->AddressOfNameOrdinals = EDATA + 0x80;
    funcs = (DWORD *)(img + EDATA + 0x40); names = (DWORD *)(img + EDATA + 0x60); ords = (WORD *)(img + EDATA + 0x80);
    strcpy( (char *)img + EDATA + 0xa0, "cef_get_version" ); strcpy( (char *)img + EDATA + 0xc0, "cef_initialize" );
    names[0] = EDATA + 0xa0; ords[0] = 0; funcs[0] = OTHER;
    names[1] = EDATA + 0xc0; ords[1] = 1; funcs[1] = forwarded ? EDATA + 0x100 : FN;
}

static const char *site( DWORD **eat, DWORD *cave )
{
    return ios_cef_cmdline_site( img, SIZE, &nt, sec, eat, cave );
}

typedef int (__attribute__((ms_abi)) *cef_init_fn)( void *args, void *settings, void *app, void *sandbox );

int main( int argc, char **argv )
{
    DWORD *eat = NULL, cave = 0;
    const char *why;
    int run = argc > 1 && !strcmp( argv[1], "run" );

    img = mmap( NULL, SIZE, PROT_READ | PROT_WRITE | (run ? PROT_EXEC : 0), MAP_PRIVATE | MAP_ANONYMOUS, -1, 0 );
    if (img == MAP_FAILED) FAIL("mmap\n");

    build( IMAGE_FILE_MACHINE_AMD64, 0, 0, TEXT_VS, 1 );
    if ((why = site( &eat, &cave ))) FAIL("refused a good image: %s\n", why);
    if (cave != TEXT + TEXT_VS || eat != (DWORD *)(img + EDATA + 0x44)) FAIL("site 0x%x\n", cave);
    ios_cef_cmdline_apply( img, eat, cave );
    if (*eat != cave || memcmp( img + cave, ios_cef_cmdline_thunk, 33 ) || img[cave + 33] != 0xe9) FAIL("apply\n");
    { int32_t d; memcpy( &d, img + cave + 34, 4 ); if (cave + 38 + d != FN) FAIL("rel32 does not reach cef_initialize\n"); }
    if (((DWORD *)(img + EDATA + 0x40))[0] != OTHER) FAIL("other export moved\n");
    {   /* FEX marks only [va, va+VirtualSize) as code: the section must grow over the thunk */
        IMAGE_SECTION_HEADER copy[2];
        memcpy( copy, sec, sizeof(copy) );
        ios_cef_cmdline_grow_section( copy, sec, 2, cave, 38 );
        if (copy[0].Misc.VirtualSize != TEXT_VS + 38 || sec[0].Misc.VirtualSize != TEXT_VS)
            FAIL("copy not grown, or mapped table written through a copy: 0x%x/0x%x\n", copy[0].Misc.VirtualSize, sec[0].Misc.VirtualSize);
        if (sec[1].Misc.VirtualSize != 0x1000) FAIL("other section changed\n");
        ios_cef_cmdline_grow_section( sec, sec, 2, cave, 38 );
        if (sec[0].Misc.VirtualSize != TEXT_VS + 38) FAIL("grow not idempotent\n");
        printf("PASS: cef_initialize's section grows to cover the thunk (mapped table not touched through a copy)\n");
    }

    if (run)
    {
        cef_init_fn f = (cef_init_fn)(img + *eat);
        unsigned char st[0x200];
        uint64_t sz;
        int r;
        /* CEF 128+-shaped struct with the flag set: cleared, call reaches cef_initialize */
        memset( st, 0, sizeof(st) ); sz = 0x180; memcpy( st, &sz, 8 ); *(uint32_t *)(st + 0x64) = 1;
        r = f( (void *)0x1234, st, NULL, NULL );
        if (r != 0x100 || *(uint32_t *)(st + 0x64)) FAIL("flag not cleared or args lost (r=0x%x)\n", r);
        /* flag already 0: untouched */
        r = f( (void *)0x1234, st, NULL, NULL );
        if (r != 0x100) FAIL("second call r=0x%x\n", r);
        /* another value there (older layout's cache_path pointer half): untouched */
        *(uint32_t *)(st + 0x64) = 0xdeadbeef;
        r = f( (void *)0x1234, st, NULL, NULL );
        if ((unsigned)r != 0xdeadbeef + 0x100) FAIL("non-1 field changed (r=0x%x)\n", r);
        /* too small / implausible size: untouched */
        *(uint32_t *)(st + 0x64) = 1; sz = 0x60; memcpy( st, &sz, 8 );
        if (f( (void *)0x1234, st, NULL, NULL ) != 0x101) FAIL("small struct changed\n");
        sz = 0x10000; memcpy( st, &sz, 8 );
        if (f( (void *)0x1234, st, NULL, NULL ) != 0x101) FAIL("huge size changed\n");
        printf("PASS: the patched export runs: flag 1 -> 0 for a 0x68..0x1000 struct, anything else untouched, "
               "arguments reach cef_initialize\n");
    }

    build( IMAGE_FILE_MACHINE_AMD64, 0, 1, TEXT_VS, 1 );
    if (!(why = site( &eat, &cave )) || strcmp( why, "section tail not free (not 0x00/0xcc padding)" )) FAIL("dirty tail: %s\n", why);
    build( IMAGE_FILE_MACHINE_AMD64, 0, 2, TEXT_VS, 1 );
    if ((why = site( &eat, &cave ))) FAIL("int3 padding refused: %s\n", why);
    build( IMAGE_FILE_MACHINE_AMD64, 0, 0, 0xffe, 1 );
    if (!(why = site( &eat, &cave )) || strcmp( why, "no room after cef_initialize's section" )) FAIL("room: %s\n", why);
    build( IMAGE_FILE_MACHINE_AMD64, 1, 0, TEXT_VS, 1 );
    if (!(why = site( &eat, &cave )) || strcmp( why, "cef_initialize is forwarded" )) FAIL("forward: %s\n", why);
    build( IMAGE_FILE_MACHINE_AMD64, 0, 0, TEXT_VS, 0 );
    if (!(why = site( &eat, &cave )) || strcmp( why, "no export directory" )) FAIL("no export: %s\n", why);
    build( IMAGE_FILE_MACHINE_I386, 0, 0, TEXT_VS, 1 );
    if (!(why = site( &eat, &cave ))) FAIL("32-bit image taken\n");
    printf("PASS: export slot -> 16-byte-aligned cave after cef_initialize's section, rel32 back to it; "
           "int3 padding taken; dirty tail, no room, forwarded, no exports and 32-bit images refused\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as t:
    c = Path(t) / 'cef.c'
    c.write_text(harness)
    exe = Path(t) / 'cef'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-O1', '-Wall', '-Wno-unused-function',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(c), '-o', str(exe)], check=True)
    run = platform.machine() in ('x86_64', 'AMD64')
    subprocess.run([str(exe)] + (['run'] if run else []), check=True)
    if not run:
        print('note: not an x86-64 host; the thunk was checked byte for byte but not run')
