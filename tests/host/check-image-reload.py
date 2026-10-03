#!/usr/bin/env python3
"""A module loaded again at the base of its unloaded pool copy gets fresh .data/.bss; no Wine runs.

GTA V Enhanced: the GTA5_Enhanced child loads dxgi.dll (DXMT), unloads it, then
loads it again at the SAME base. mprotect_exec's already-copied check
(ml352: MZ + SizeOfImage) adopted the old pool copy -- no new [jit-pool] line --
and with it the unloaded module's .bss: the guard of dxmt::Config::getInstance()'s
function-local static still said "constructed", while DLL_PROCESS_DETACH had run
its destructor (bucket array = NULL) -> AV READ of 0 at dxgi.dll+0x2c058
(unordered_map::find), entered from EnumAdapterByGpuPreference.

Compiles the production helpers from build/ntdll-unix/virtual_ios.c
(ios_image_reload_mode, ios_jit_note_image_unmapped, ios_jit_reload_choice,
ios_jit_same_headers, struct ios_jit_mapping) against a model table, and checks
the call sites textually:
  - delete_view marks the copies of an unmapped SEC_IMAGE view (after the opt-in
    retire, before unmap_area); data views, adjacent images: untouched;
  - default (mode 1): same image (identical PE headers), NULL owner -> rebuild
    in place, but only inside a pool ledger record of the process mapping it
    again (ios_pool_ledger_holds); per-process copy / different headers -> new
    copy; a live entry -> the old early-out;
  - MADEIRA_IMAGE_RELOAD=2 -> always a new copy; =0 -> nothing marked, old
    behaviour; other values -> default;
  - new slots (add_mapping, child ntdll copies) start unmarked;
  - the in-place rebuild reuses the unloaded copy's pool offset without
    allocating and without re-adding the data-align shift.
Needs python3 and a C compiler (AddressSanitizer/UBSan).
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


def struct(source, name):
    start = source.index('struct %s {' % name)
    return source[start:source.index('\n};', start) + 3] + '\n'


# --- call sites ---------------------------------------------------------------
delete = function(native, 'static void delete_view(')
assert 'if (view->protect & SEC_IMAGE) ios_jit_note_image_unmapped( view->base, view->size );' in delete
assert delete.index('ios_jit_retire_image') < delete.index('ios_jit_note_image_unmapped') < delete.index('unmap_area(')

add = function(native, 'void ios_jit_add_mapping(void *pe_base, void *jit_base, size_t size)')
assert add.index('ios_jit_mappings[slot].unmapped = 0;') < add.index('ios_jit_mappings[slot].pe_base = pe_base;')
child = native[native.index('ios_jit_mappings[slot].jit_base = rx_dest;'):][:900]
assert 'ios_jit_mappings[slot].owner_peb = child_peb;' in child
assert child.index('ios_jit_mappings[slot].unmapped = 0;') < child.index('ios_jit_mappings[slot].pe_base = m->pe_base;')

early = native[native.index('/* Check if this image was already copied to JIT pool */'):]
early = early[:early.index('/* Scan backward to find MZ header')]
# the reload test runs only for an entry that passed ml352's MZ/SizeOfImage check
assert early.index('STALE containment rev=ml352') < early.index('if (ios_jit_mappings[i].unmapped)') \
    < early.index('ERR("iOS JIT: %p already in mapping')
assert re.search(r'if \(choice == 1\)\s*\{\s*reload_jit = ios_jit_mappings\[i\]\.jit_base;'
                 r'\s*reload_pe = \(void \*\)mb;\s*reload_size = ios_jit_mappings\[i\]\.size;\s*break;\s*\}'
                 r'\s*if \(choice == 2\) continue;', early), 'in-place: leave the loop; new copy: skip the entry'

alloc = native[native.index('size_t alloc_size = image_alloc + tramp_prealloc'):]
alloc = alloc[:alloc.index('if (offset == (size_t)-1)')]
assert re.search(r'if \(reload_jit && reload_pe == image_base && reload_size == image_size &&\s*'
                 r'ios_pool_ledger_holds\( \(size_t\)\(\(char \*\)reload_jit - \(char \*\)jit_rx_base\),\s*'
                 r'image_alloc \+ tramp_prealloc, ios_jit_current_peb\(\) \)\)', alloc), \
    'in place only inside this process\'s own ledger record'
assert 'offset = (size_t)((char *)reload_jit - (char *)jit_rx_base);' in alloc
assert alloc.index('reload_jit = NULL;') < alloc.index('offset = ios_pool_alloc_range(')
assert 'if (!reload_jit && offset != (size_t)-1 && data_delta)' in alloc, 'no second data-align shift'

# --- behaviour ----------------------------------------------------------------
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
typedef int kern_return_t;
#define KERN_SUCCESS 0
#define KERN_INVALID_ADDRESS 1
static int mach_task_self(void) { return 0; }
/* the new view: a model buffer; anything else is "unmapped" */
static unsigned char *view_lo; static size_t view_len;
static kern_return_t mach_vm_read_overwrite(int task, mach_vm_address_t a, mach_vm_size_t n,
                                            mach_vm_address_t out, mach_vm_size_t *got)
{
    (void)task;
    if (!view_lo || a < (uintptr_t)view_lo || a + n > (uintptr_t)view_lo + view_len) return KERN_INVALID_ADDRESS;
    memcpy((void *)(uintptr_t)out, (void *)(uintptr_t)a, n); *got = n; return KERN_SUCCESS;
}
#define IOS_JIT_MAX_MAPPINGS 8
'''
code += struct(native, 'ios_jit_mapping')
code += r'''
static struct ios_jit_mapping ios_jit_mappings[IOS_JIT_MAX_MAPPINGS];
static int ios_jit_mapping_count;
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
struct ios_pool_alloc { size_t off; size_t size; void *peb; };
static struct ios_pool_alloc ios_pool_ledger[4];
static int ios_pool_ledger_count;
'''
code += function(native, 'static int ios_pool_ledger_holds(')
code += function(native, 'static int ios_image_reload_mode(void)')
code += function(native, 'static void ios_jit_note_image_unmapped(')
code += function(native, 'static int ios_jit_reload_choice(')
code += function(native, 'static int ios_jit_same_headers(')
code += r'''
#define SEC_IMAGE 0x1000000
struct file_view { void *base; size_t size; unsigned int protect; };
static void delete_view_model( struct file_view *view )
{
    if (view->protect & SEC_IMAGE) ios_jit_note_image_unmapped( view->base, view->size );
}
static void make_pe( unsigned char *img, unsigned stamp )
{
    memset(img, 0, 0x1000);
    img[0] = 'M'; img[1] = 'Z';
    *(unsigned *)(img + 0x3c) = 0x80;
    memcpy(img + 0x80, "PE\0\0", 4);
    *(unsigned short *)(img + 0x80 + 6) = 3;        /* NumberOfSections */
    *(unsigned *)(img + 0x80 + 8) = stamp;          /* TimeDateStamp */
    *(unsigned short *)(img + 0x80 + 0x14) = 0xf0;  /* SizeOfOptionalHeader */
    *(unsigned *)(img + 0x80 + 0x50) = 0x136000;    /* SizeOfImage */
    memcpy(img + 0x80 + 0x18 + 0xf0, ".text", 5);
}
int main(int argc, char **argv)
{
    const int mode_expect = argc > 1 ? atoi(argv[1]) : 1;
    static unsigned char old_copy[0x1000], new_view[0x1000], other_view[0x1000], neighbour[0x1000];
    void *child = (void *)0x1099dc000ULL, *parent = (void *)0x10a000000ULL;
    const uintptr_t base = (uintptr_t)new_view;      /* the PE base of both loads */
    int mode = ios_image_reload_mode();
    assert(mode == mode_expect);

    /* ledger: dxgi's range (data-align page + image + tramps) for the child, a neighbour for the parent */
    ios_pool_ledger_count = 2;
    ios_pool_ledger[0] = (struct ios_pool_alloc){ 0xcbe8000, 0x138000 + 0x4000, child };
    ios_pool_ledger[1] = (struct ios_pool_alloc){ 0xcbe8000 + 0x13c000, 0x10000, parent };
    assert(ios_pool_ledger_holds(0xcbe8000 + 0x2000, 0x138000, child));          /* shifted copy fits */
    assert(ios_pool_ledger_holds(0xcbe8000, 0x13c000, child));                   /* exactly the record */
    assert(!ios_pool_ledger_holds(0xcbe8000 + 0x2000, 0x13c000, child));        /* would spill into the neighbour */
    assert(!ios_pool_ledger_holds(0xcbe8000 + 0x2000, 0x138000, parent));       /* not that process's record */
    assert(!ios_pool_ledger_holds(0xcbe8000 - 0x1000, 0x1000, child));          /* below every record */
    assert(!ios_pool_ledger_holds(0xcbe8000 + 0x13c000 + 0x10000, 1, parent));  /* past the end */

    make_pe(old_copy, 0x1234); make_pe(new_view, 0x1234); make_pe(other_view, 0x9999);
    view_lo = new_view; view_len = sizeof(new_view);
    ios_jit_mapping_count = 3;
    ios_jit_mappings[0] = (struct ios_jit_mapping){ .pe_base = (void *)base, .jit_base = old_copy,
                                                    .size = 0x136000 };
    /* a per-process copy of the same image, and the next image up */
    ios_jit_mappings[1] = (struct ios_jit_mapping){ .pe_base = (void *)base, .jit_base = old_copy,
                                                    .size = 0x136000, .owner_peb = parent };
    ios_jit_mappings[2] = (struct ios_jit_mapping){ .pe_base = (void *)(base + 0x136000), .jit_base = neighbour,
                                                    .size = 0x10000 };

    /* live entry: the old early-out (second section of a loaded image) */
    assert(ios_jit_reload_choice(&ios_jit_mappings[0], 1, mode) == 0);

    struct file_view data = { (void *)base, 0x136000, 0 };
    delete_view_model(&data);
    assert(!ios_jit_mappings[0].unmapped && !ios_jit_mappings[1].unmapped);

    struct file_view image = { (void *)base, 0x136000, SEC_IMAGE };
    delete_view_model(&image);                       /* FreeLibrary(dxgi) */
    assert(!ios_jit_mappings[2].unmapped);           /* adjacency is not overlap */
    if (mode == 0)
    {
        assert(!ios_jit_mappings[0].unmapped && !ios_jit_mappings[1].unmapped);
        assert(ios_jit_reload_choice(&ios_jit_mappings[0], 1, mode) == 0);
        puts("PASS (mode 0): nothing marked, the unloaded copy is adopted as before");
        return 0;
    }
    assert(ios_jit_mappings[0].unmapped && ios_jit_mappings[1].unmapped);
    assert(ios_jit_mappings[0].pe_base && ios_jit_mappings[0].size == 0x136000); /* not tombstoned */

    /* the same file again at the same base */
    int same = ios_jit_same_headers(base, old_copy);
    assert(same == 1);
    /* a different file of the same size there */
    view_lo = other_view;
    assert(ios_jit_same_headers((uintptr_t)other_view, old_copy) == 0);
    view_lo = NULL;                                  /* nothing mapped: fault-safe read fails */
    assert(ios_jit_same_headers(base, old_copy) == 0);
    view_lo = new_view;

    int c_same = ios_jit_reload_choice(&ios_jit_mappings[0], same, mode);
    int c_diff = ios_jit_reload_choice(&ios_jit_mappings[0], 0, mode);
    int c_owned = ios_jit_reload_choice(&ios_jit_mappings[1], same, mode);
    assert(c_diff == 2 && c_owned == 2);
    if (mode == 1)
    {
        assert(c_same == 1);
        puts("PASS (mode 1): same image/base -> rebuilt in place (inside the process's ledger record); "
             "per-process copy or different headers -> new copy; live entry -> old early-out");
    }
    else
    {
        assert(c_same == 2);
        puts("PASS (mode 2): every unloaded copy -> new copy");
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-image-reload-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(code)
    executable = folder / 'check'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-g',
                    '-Wno-unused-function', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                    '-pthread', str(source), '-o', str(executable)], check=True)
    runs = [(None, 1), ('1', 1), ('2', 2), ('0', 0), ('', 1), ('3', 1), ('10', 1), ('yes', 1)]
    for value, mode in runs:
        env = dict(os.environ)
        env.pop('MADEIRA_IMAGE_RELOAD', None)
        if value is not None:
            env['MADEIRA_IMAGE_RELOAD'] = value
        result = subprocess.run([str(executable), str(mode)], env=env, check=True,
                                capture_output=True, text=True)
        print(f'MADEIRA_IMAGE_RELOAD={value!r}: {result.stdout.strip()}')
        assert (f'[image-reload] mode={mode}' in result.stderr) == (mode != 1), result.stderr
print('PASS: an image loaded again at the base of its unloaded copy never adopts that copy\'s globals '
      '(default: rebuilt in place); MADEIRA_IMAGE_RELOAD=2 new copy, =0 old behaviour')
