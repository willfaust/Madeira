#!/usr/bin/env python3
"""ADD/SUB off x18 take the destination-register trampoline; no Wine runs.

iOS zeroes x18 when it preempts a thread. The x18 patcher in
build/ntdll-unix/virtual_ios.c used to run every ADD/SUB that reads x18 through
the "via x18" trampoline (load x18 from TPIDRRO_EL0, then the instruction
unchanged): a preemption in between leaves x18 = 0, the ADD computes a small
address without faulting, and a later access faults where the handler cannot
repair it. Wine's debug buffer is NtCurrentTeb() + 0x2000 + sizeof(TEB32), so
its output lands at 0x3404 (RockstarService.exe, GTA V Enhanced build 375,
2026-10-04 09:52: ntdll printf padding loop writing to 0x3404 with x18 = 0).

Compiles the production ios_insn_x18_role, ios_insn_replace_x18 and
ios_x18_arith_dest and checks:
  - ADD/SUB (immediate) with Rn = x18 use the destination, any width, with or
    without flags, unless the destination is x18 or 31 (SP / XZR);
  - ADD/SUB (register) use the destination when x18 is one source and the other
    source is not the destination; x18 in both sources stays on the old path;
  - SUB/SUBS are classified at all (the role mask used to keep the op bit, so
    only ADD matched and every SUB off x18 read the raw, zeroed x18);
  - loads, stores, LDP/STP and MOV are not taken by this rule;
  - the rewritten instruction reads the destination where it read x18, and the
    three setup words load the TEB into that register;
and textually that the patcher emits this form before its "via x18" fallback.
Needs python3 and a C compiler (AddressSanitizer/UBSan when available).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


defines = native[native.index('#define X18_ROLE_NONE 0'):native.index('static int ios_insn_x18_role(uint32_t insn, int stores)')]
code = '#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n' + defines
code += function(native, 'static int ios_insn_x18_role(uint32_t insn, int stores)')
code += function(native, 'static int ios_x18_arith_dest(uint32_t insn, int role)')
code += function(native, 'static uint32_t ios_insn_replace_x18(uint32_t insn, int role, int scratch)')
code += r'''
#define FAIL(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)
/* stores = 0: an image without the x18-as-stored-value rule (every image but opengl32) */
static int dest( uint32_t insn ) { return ios_x18_arith_dest( insn, ios_insn_x18_role( insn, 0 ) ); }
static void expect( uint32_t insn, int rd, uint32_t rewritten, const char *what )
{
    int got = dest( insn );
    if (got != rd) FAIL("%s (0x%08x): dest %d, want %d\n", what, insn, got, rd);
    if (rd >= 0)
    {
        uint32_t r = ios_insn_replace_x18( insn, ios_insn_x18_role( insn, 0 ), rd );
        if (r != rewritten) FAIL("%s: rewritten 0x%08x, want 0x%08x\n", what, r, rewritten);
    }
}
int main( void )
{
    /* get_info(): add x8, x18, #3, lsl #12 -> add x8, x8, #3, lsl #12 */
    expect( 0x91400E48, 8, 0x91400D08, "add x8, x18, #0x3000" );
    expect( 0x9100C240, 0, 0x9100C000, "add x0, x18, #0x30" );
    expect( 0xD1002249, 9, 0xD1002129, "sub x9, x18, #8" );
    expect( 0xB1002249, 9, 0xB1002129, "adds x9, x18, #8" );
    expect( 0x11002249, 9, 0x11002129, "add w9, w18, #8" );
    expect( 0x9100225F, -1, 0, "add sp, x18, #8" );
    expect( 0xB100225F, -1, 0, "cmn x18, #8" );
    expect( 0x91002252, -1, 0, "add x18, x18, #8" );
    /* register forms */
    expect( 0x8B120128, 8, 0x8B080128, "add x8, x9, x18" );
    expect( 0x8B090248, 8, 0x8B090108, "add x8, x18, x9" );
    expect( 0xCB120128, 8, 0xCB080128, "sub x8, x9, x18" );
    expect( 0x8B080248, -1, 0, "add x8, x18, x8" );
    expect( 0x8B120108, -1, 0, "add x8, x8, x18" );
    expect( 0x8B120248, -1, 0, "add x8, x18, x18" );
    expect( 0xEB12013F, -1, 0, "cmp x9, x18" );
    /* not arithmetic */
    expect( 0xF9400640, -1, 0, "ldr x0, [x18, #8]" );
    expect( 0xF9000640, -1, 0, "str x0, [x18, #8]" );
    expect( 0xA9000640, -1, 0, "stp x0, x1, [x18]" );
    expect( 0xAA1203E8, -1, 0, "mov x8, x18" );
    expect( 0x91002128, -1, 0, "add x8, x9, #8 (no x18)" );
    puts( "PASS: ADD/SUB off x18 with a free destination use it; the rest keep their forms" );
    return 0;
}
'''

patcher = function(native, 'int ios_jit_patch_x18(char *text_rw, char *text_rx, size_t text_size,')
arith = patcher.index('else if (arith_rd >= 0)')
assert patcher.index('int arith_rd = (!is_mov_from_x18 && !is_int_ldr_imm) ? ios_x18_arith_dest(insn, role) : -1;') < arith
assert arith < patcher.index('Use x18 itself.'), 'the destination form comes before the via-x18 fallback'
block = patcher[arith:patcher.index('Use x18 itself.')]
assert '0xD53BD060 | arith_rd' in block and '0x927DF000 | (arith_rd << 5) | arith_rd' in block
assert '0xF9400000 | ((slot_off / 8) << 10) | (arith_rd << 5) | arith_rd' in block
assert 'ios_insn_replace_x18(insn, role, arith_rd)' in block and 'tramp_off + 20 > tramp_size' in block
print('PASS: the patcher emits the destination form for ADD/SUB before the via-x18 fallback')

with tempfile.TemporaryDirectory(prefix='madeira-x18-arith-') as directory:
    folder = Path(directory)
    source = folder / 'check.c'
    source.write_text(code)
    exe = folder / 'check'
    cc = os.environ.get('CC', 'cc')
    flags = [cc, '-std=gnu11', '-Wall', '-Wextra', '-Wno-unused-function', '-Wno-tautological-compare', '-Werror', '-g', str(source), '-o', str(exe)]
    sanitize = ['-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    if subprocess.run(flags[:1] + sanitize + flags[1:], capture_output=True).returncode != 0:
        subprocess.run(flags, check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True)
    print(out.stdout, end='')
    assert out.returncode == 0, out.stderr
