#!/usr/bin/env python3
"""Social Club layout 2: the helper's commits into its large grants, in 256 MB steps; no Wine runs.

SocialClubHelper.exe committed past chrome_elf.dll's real 4 GB pool (13:56 in
the log of 2026-10-08 13:39:08, GTA V Enhanced build 451) before it raised its
out-of-memory exception and the game quit. build/ntdll-unix/virtual_ios.c's
ios_sc2_note_growth says in 256 MB steps how far the helper has committed into
each of its large grants. Compiles it and checks: a line at each new 256 MB
step and none below it or for a lower commit; a commit past the real part
reported with the real and reported sizes; the metadata regions left out; a
restarted helper (new PEB) counted from 0 again; and textually that
ios_sc2_note_commit feeds it every commit inside a grant.
Needs python3 and a C compiler.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]

native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
start = native.index('static void ios_sc2_note_growth( uint64_t a, uint64_t size, const struct ios_sc2_gv *gv, void *peb )')
growth = native[start:native.index('\n}\n', start) + 3]
enums = native[native.index('enum { IOS_SC2_NONE,'):]
enums = enums[:enums.index('\n', enums.index('enum { IOS_SC_K_V1')) + 1]
gv = native[native.index('struct ios_sc2_gv {'):]
gv = gv[:gv.index('};') + 2] + '\n'
harness2 = r"""
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
""" + enums + gv + r"""
static const char *ios_sc_kind_what(int kind) { return kind == IOS_SC2_E ? "chrome_elf.dll's PartitionAlloc pools" : "another grant"; }
static const char *ios_sc_host_name(char *b, size_t n) { snprintf(b, n, "SocialClubHelper.exe"); return b; }
static char out[1 << 16];
static size_t outn;
static int fake_dprintf(int fd, const char *f, ...)
{
    va_list ap; int w;
    (void)fd;
    va_start(ap, f);
    w = vsnprintf(out + outn, sizeof out - outn, f, ap);
    va_end(ap);
    if (w > 0) outn += (size_t)w;
    return w;
}
#define dprintf fake_dprintf
""" + growth + r"""
#define MB (1ull << 20)
int main(void)
{
    struct ios_sc2_gv e = { 0x7800000000ull, 4096 * MB, 0x7800000000ull, 32768 * MB, IOS_SC2_E };
    struct ios_sc2_gv j = { 0x7400000000ull, 8192 * MB, 0x7400000000ull, 16384 * MB, IOS_SC2_J2 };
    int a = 1, b = 2;
    ios_sc2_note_growth(e.view + 10 * MB, 2 * MB, &e, &a);
    ios_sc2_note_growth(e.view + 200 * MB, 2 * MB, &e, &a);
    if (outn) { printf("FAIL: a line below the first 256 MB step: %s", out); return 1; }
    ios_sc2_note_growth(e.view + 300 * MB, 2 * MB, &e, &a);
    ios_sc2_note_growth(e.view + 280 * MB, 2 * MB, &e, &a);
    ios_sc2_note_growth(e.view + 400 * MB, 2 * MB, &e, &a);
    ios_sc2_note_growth(e.view + 600 * MB, 2 * MB, &e, &a);
    ios_sc2_note_growth(j.view + 900 * MB, 4096, &j, &a);
    ios_sc2_note_growth(0x794fe00000ull, 0x410000, &e, &a);   /* the 13:56 commit */
    ios_sc2_note_growth(e.view + 300 * MB, 2 * MB, &e, &b);   /* a restarted helper */
    printf("%s", out);
    if (strcmp(out,
        "[sc-cef] layout 2: SocialClubHelper.exe has committed chrome_elf.dll's PartitionAlloc pools up to +302 MB (4096 MB real of 32768 MB reported)\n"
        "[sc-cef] layout 2: SocialClubHelper.exe has committed chrome_elf.dll's PartitionAlloc pools up to +602 MB (4096 MB real of 32768 MB reported)\n"
        "[sc-cef] layout 2: SocialClubHelper.exe has committed chrome_elf.dll's PartitionAlloc pools up to +5378 MB (4096 MB real of 32768 MB reported)\n"
        "[sc-cef] layout 2: SocialClubHelper.exe has committed chrome_elf.dll's PartitionAlloc pools up to +302 MB (4096 MB real of 32768 MB reported)\n"))
    { printf("FAIL: unexpected growth lines\n"); return 1; }
    printf("PASS: growth lines at each new 256 MB step only, past the real part too, metadata left out, a restarted helper counted again\n");
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix='madeira-sc-growth-') as directory:
    c = Path(directory) / 'growth.c'
    exe = Path(directory) / 'growth'
    c.write_text(harness2)
    build = subprocess.run(['cc', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-fsanitize=address,undefined',
                            '-o', str(exe), str(c)], capture_output=True, text=True)
    assert build.returncode == 0, build.stdout + build.stderr
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    print(run.stdout, end='')
    assert run.returncode == 0, run.stdout + run.stderr

note = native[native.index('static void ios_sc2_note_commit( void *addr, SIZE_T size )'):]
note = note[:note.index('\n}\n')]
assert ('if (gi >= 0 && (c != IOS_SC2_C_OK || a - g[gi].view < g[gi].real))   /* a commit in this grant */\n'
        '        ios_sc2_note_growth( a, size, &g[gi], peb );') in note, 'ios_sc2_note_commit must feed the growth lines'
assert 'int i, n = 0, gi = -1, c, owner;' in note, 'gi must start at -1 so a commit outside every grant is not counted'
print('PASS: ios_sc2_note_commit feeds every commit inside a grant to the growth lines')