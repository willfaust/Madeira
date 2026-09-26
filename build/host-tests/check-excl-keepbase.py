#!/usr/bin/env python3
"""ml1990: store-exclusive emulation that keeps the base register.

Extracts the pure planner/commit core from signal_arm64_ios.c and checks it
against the exact device sequence (Wine's RtlpUnWaitCriticalSection), the
other compiler shapes in the shipped ntdll, and every decline rule. A
threaded run proves a failing commit is an ordinary LL/SC failure (no lost
or duplicated increments). Device execution is still required."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
begin = source.index('/* ml1990 keepbase core begin */')
end = source.index('/* ml1990 keepbase core end */')
core = source[begin:end]

c = r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
''' + core + r'''
#define LDAXR_WZR_X0      0x885ffc1fu  /* ldaxr wzr, [x0]        */
#define STLXR_W9_W8_X0    0x8809fc08u  /* stlxr w9, w8, [x0]      */
#define LDAXR_X8_X19      0xc85ffe68u  /* ldaxr x8, [x19]         */
#define CBNZ_X8           0xb5000208u  /* cbnz x8, +64            */
#define STLXR_W8_X22_X19  0xc808fe76u  /* stlxr w8, x22, [x19]    */
#define LDAXR_W9_X8       0x885ffd09u  /* ldaxr w9, [x8]          */
#define ADD_W9_W9_1       0x11000529u  /* add w9, w9, #1          */
#define SUBS_W9_W9_1      0x71000529u  /* subs w9, w9, #1         */
#define SUB_X9_X9_1_LSL12 0xd1400529u  /* sub x9, x9, #1, lsl #12 */
#define STLXR_W10_W9_X8   0x880afd09u  /* stlxr w10, w9, [x8]     */
#define ADD_X8_X8_4       0x91001108u  /* add x8, x8, #4          */
#define LDR_W3_SP         0xb9400be3u  /* ldr w3, [sp, #8]        */
#define B_FWD             0x14000010u  /* b +64                   */
#define RET               0xd65f03c0u
#define NOP               0xd503201fu
#define STXP_W3_X4_X5_X2  0xc8231444u
#define LDXP_X0_X1_X2     0xc87f0440u
#define LDAXRB_W1_X2      0x085ffc41u
#define STLXRB_W3_W4_X2   0x0803fc44u
#define LDAXRH_W1_X2      0x485ffc41u
#define STXRH_W3_W4_X2    0x48037c44u
#define CMP_W8_W2         0x6b02011fu
#define BNE_FWD           0x54000101u
#define TBNZ_W9_3         0x37180089u
#define STLXR_WZR_W8_X0   0x881ffc08u
#define LDAXR_W8_X0       0x885ffc08u
#define MOV_W10_W8        0x2a0803eau
#define MOVK_W8           0x72a00028u
#define CASAL_W1_W2_X0    0x88e1fc02u
#define STLR_W1_X0        0x889ffc01u

static uint64_t shared_counter;
static void *incrementer(void *arg)
{
    /* The planner result for ldaxr x8,[x19]; add x8,x8,#1; stlxr w10,x8,[x19],
     * committed exactly as the Mach handler does. */
    uint32_t win[1] = { 0x91000508u /* add x8, x8, #1 */ };
    uint32_t prev[2] = { win[0], LDAXR_X8_X19 };
    struct ios_excl_keep k;
    int i;
    assert(ios_excl_keepbase_plan(0xc80afe68u /* stlxr w10, x8, [x19] */, prev, 2, &k));
    assert(k.delta == 1 && k.ld_rt == 8 && k.rt == 8);
    for (i = 0; i < 200000; i++)
    {
        for (;;)
        {
            uint64_t observed = __atomic_load_n(&shared_counter, __ATOMIC_ACQUIRE); /* the native ldaxr */
            uint64_t x8 = observed + 1;                                            /* the native add   */
            if (ios_excl_keepbase_commit(&k, (uintptr_t)&shared_counter, x8, x8) == 0) break;
        }
    }
    (void)arg;
    return NULL;
}

int main(void)
{
    struct ios_excl_keep k;
    uint32_t mem32;
    uint64_t mem64;
    uint8_t mem8;
    uint16_t mem16;

    /* 1. The device sequence: Wine's InterlockedExchange before RtlWakeAddressSingle. */
    {
        uint32_t prev[] = { LDAXR_WZR_X0, 0x52800028u /* mov w8,#1 */ };
        assert(ios_excl_is_store_single(STLXR_W9_W8_X0));
        assert(ios_excl_keepbase_plan(STLXR_W9_W8_X0, prev, 2, &k));
        assert(k.rn == 0 && k.rs == 9 && k.rt == 8 && k.ld_rt == 31 && k.distance == 1 && k.size_lg2 == 2);
        mem32 = 0xdeadbeef;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem32, 0, 0xffffffff00000001ull) == 0);
        assert(mem32 == 1);
    }
    /* 2. Compare-exchange shape: ldaxr x8; cbnz x8; stlxr w8, x22 (status aliases load reg). */
    {
        uint32_t prev[] = { CBNZ_X8, LDAXR_X8_X19 };
        assert(ios_excl_keepbase_plan(STLXR_W8_X22_X19, prev, 2, &k));
        assert(k.rn == 19 && k.rs == 8 && k.rt == 22 && k.ld_rt == 8 && k.delta == 0 && k.distance == 2);
        mem64 = 0;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem64, 0, 0x1234567890ull) == 0 && mem64 == 0x1234567890ull);
        /* someone else wrote between the load and the store: must report failure, not store */
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem64, 0, 77) == 1 && mem64 == 0x1234567890ull);
    }
    /* 3. Increment overwrites the loaded register: delta inverts it exactly. */
    {
        uint32_t prev[] = { ADD_W9_W9_1, LDAXR_W9_X8 };
        assert(ios_excl_keepbase_plan(STLXR_W10_W9_X8, prev, 2, &k));
        assert(k.ld_rt == 9 && k.delta == 1);
        mem32 = 5;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem32, 6, 6) == 0 && mem32 == 6);
        mem32 = 7;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem32, 6, 6) == 1 && mem32 == 7);
        /* wraparound: 0xffffffff + 1 == 0 in a W register */
        mem32 = 0xffffffffu;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem32, 0, 0) == 0 && mem32 == 0);
    }
    /* 4. Decrement (subs) and 64-bit shifted immediate. */
    {
        uint32_t prev[] = { SUBS_W9_W9_1, LDAXR_W9_X8 };
        assert(ios_excl_keepbase_plan(STLXR_W10_W9_X8, prev, 2, &k));
        mem32 = 1;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem32, 0, 0) == 0 && mem32 == 0);
        mem32 = 0;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem32, 0xffffffffu, 0xffffffffu) == 0 && mem32 == 0xffffffffu);
    }
    {
        uint32_t prev[] = { SUB_X9_X9_1_LSL12, 0xc85ffd09u /* ldaxr x9, [x8] */ };
        assert(ios_excl_keepbase_plan(0xc80afd09u /* stlxr w10, x9, [x8] */, prev, 2, &k));
        mem64 = 0x10000;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem64, 0xf000, 0xf000) == 0 && mem64 == 0xf000);
        /* 32-bit op on the X load's register truncates: not invertible, declined. */
        prev[0] = ADD_W9_W9_1;
        assert(!ios_excl_keepbase_plan(0xc80afd09u, prev, 2, &k));
    }
    /* 5. CAS loop with cmp/b.ne/tbnz/nop and a copy of the observed value. */
    {
        uint32_t prev[] = { NOP, TBNZ_W9_3, BNE_FWD, CMP_W8_W2, MOV_W10_W8, LDAXR_W8_X0 };
        assert(ios_excl_keepbase_plan(0x880bfc0au /* stlxr w11, w10, [x0] */, prev, 6, &k));
        assert(k.ld_rt == 8 && k.distance == 6 && k.delta == 0);
    }
    /* 6. Byte and halfword forms. */
    {
        uint32_t prev[] = { LDAXRB_W1_X2 };
        assert(ios_excl_keepbase_plan(STLXRB_W3_W4_X2, prev, 1, &k) && k.size_lg2 == 0);
        mem8 = 0x40;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem8, 0x40, 0x1ff) == 0 && mem8 == 0xff);
        prev[0] = LDAXRH_W1_X2;
        assert(ios_excl_keepbase_plan(STXRH_W3_W4_X2, prev, 1, &k) && k.size_lg2 == 1);
        mem16 = 9;
        assert(ios_excl_keepbase_commit(&k, (uintptr_t)&mem16, 8, 1) == 1 && mem16 == 9);
        /* size mismatch: a byte load never pairs with a halfword store */
        prev[0] = LDAXRB_W1_X2;
        assert(!ios_excl_keepbase_plan(STXRH_W3_W4_X2, prev, 1, &k));
    }
    /* 7. Declines: every one of these keeps the legacy retarget. */
    {
        uint32_t p1[] = { ADD_X8_X8_4, LDAXR_W9_X8 };      /* base rewritten between */
        uint32_t p2[] = { LDR_W3_SP, LDAXR_W9_X8 };        /* memory access between */
        uint32_t p3[] = { B_FWD, LDAXR_W9_X8 };            /* store only reachable by branch */
        uint32_t p4[] = { RET, LDAXR_W9_X8 };
        uint32_t p5[] = { NOP, NOP, NOP, NOP, NOP, NOP, NOP, NOP, LDAXR_W9_X8 };  /* beyond window */
        uint32_t p6[] = { LDAXR_W8_X0 };                   /* different base */
        uint32_t p7[] = { MOVK_W8, LDAXR_W8_X0 };          /* loaded value clobbered */
        uint32_t p8[] = { LDXP_X0_X1_X2 };
        uint32_t p9[] = { CASAL_W1_W2_X0, LDAXR_W8_X0 };
        uint32_t p10[] = { 0x885ffd08u /* ldaxr w8, [x8] */ };
        assert(!ios_excl_keepbase_plan(STLXR_W10_W9_X8, p1, 2, &k));
        assert(!ios_excl_keepbase_plan(STLXR_W10_W9_X8, p2, 2, &k));
        assert(!ios_excl_keepbase_plan(STLXR_W10_W9_X8, p3, 2, &k));
        assert(!ios_excl_keepbase_plan(STLXR_W10_W9_X8, p4, 2, &k));
        assert(!ios_excl_keepbase_plan(STLXR_W10_W9_X8, p5, 9, &k));
        assert(!ios_excl_keepbase_plan(STLXR_W10_W9_X8, p6, 1, &k));
        assert(!ios_excl_keepbase_plan(0x880bfc0au, p7, 2, &k));
        assert(!ios_excl_keepbase_plan(STXP_W3_X4_X5_X2, p8, 1, &k));    /* pair store */
        assert(!ios_excl_keepbase_plan(0x880bfc0au, p9, 2, &k));         /* atomic between */
        assert(!ios_excl_keepbase_plan(0x880afd09u /* stlxr w10,w9,[x8] */, p10, 1, &k)); /* load wrote base */
        assert(!ios_excl_keepbase_plan(STLXR_WZR_W8_X0, p6, 1, &k));     /* status discarded */
        assert(!ios_excl_keepbase_plan(STLXR_W9_W8_X0, p6, 0, &k));      /* empty window */
        assert(!ios_excl_is_store_single(CASAL_W1_W2_X0));
        assert(!ios_excl_is_store_single(STLR_W1_X0));
        assert(!ios_excl_is_store_single(LDAXR_WZR_X0));
        assert(!ios_excl_is_store_single(STXP_W3_X4_X5_X2));
        assert(!ios_excl_is_load_single(LDXP_X0_X1_X2));
    }
    /* 8. Contention: a failed commit is an honest failure. */
    {
        pthread_t t[4];
        int i;
        shared_counter = 0;
        for (i = 0; i < 4; i++) pthread_create(&t[i], NULL, incrementer, NULL);
        for (i = 0; i < 4; i++) pthread_join(t[i], NULL);
        assert(shared_counter == 800000);
    }
    puts("PASS ml1990 keepbase: device ldaxr-wzr/stlxr exchange, CAS/increment/decrement/shifted inversion, "
         "byte/half widths, 12 decline rules, 4-thread contention exact");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-excl-') as td:
    td = Path(td)
    (td / 'keep.c').write_text(c)
    subprocess.run(['cc', '-std=c11', '-O1', '-pthread', '-Wall', '-Wno-unused-function',
                    '-fsanitize=address,undefined', str(td / 'keep.c'), '-o', str(td / 'keep')], check=True)
    subprocess.run([str(td / 'keep')], check=True)

# Integration guards: the Mach path must try keepbase first, only off the pool
# view, and must leave the legacy retarget as the fallback.
assert 'if (!in_jit && ios_excl_keepbase_enabled() && ios_excl_is_store_single( insn ))' in source
assert 'if (!keep_done &&\n                            ios_decode_exclusive_alias( insn, fault_addr, rw_addr, &fix )' in source
assert 'getenv( "MADEIRA_EXCL_ALIAS_KEEPBASE" )' in source
assert source.count('ml1990 keepbase #') == 1 and 'keep_n++ < 12' in source
print('PASS ml1990 integration guards present; device execution still required')
