/* fexdiff: differential test of x86-64 integer instruction semantics.
 *
 * Runs a fixed set of instruction forms on deterministic pseudo-random
 * inputs and prints result registers and arithmetic flags. Run natively
 * on an x86-64 Windows machine for the reference, run under the emulator
 * for the candidate, and diff the two outputs: a differing line names the
 * instruction and the inputs that the emulator gets wrong.
 *
 * Each case sets CF from an input bit (bt), executes one instruction with
 * rax, rdx, rbx, rcx preloaded, then captures rax, rdx and the flags
 * (CF PF AF ZF SF OF = mask 0x8d5). Inputs come from an xorshift stream
 * seeded per template name, so both machines run identical cases.
 *
 * Build (any x86-64 gcc): gcc -O0 -static -o fexdiff.exe fexdiff.c
 * Output: stderr and, when writable, fexdiff-results.txt beside the exe.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint64_t a, d, f; } R;
typedef R (*testfn)(uint64_t a, uint64_t d, uint64_t b, uint64_t c, uint64_t cf);

#define FLAGS_MASK 0x8d5ULL

#define DEF(NAME, ASM)                                                                   \
    static R t_##NAME(uint64_t a, uint64_t d, uint64_t b, uint64_t c, uint64_t cf)       \
    {                                                                                    \
        uint64_t f;                                                                      \
        __asm__ volatile("btq $0, %[cf]\n\t" ASM "\n\tpushfq\n\tpopq %[f]\n\t"           \
                         : "+a"(a), "+d"(d), [f] "=&r"(f)                                \
                         : "b"(b), "c"(c), [cf] "r"(cf)                                  \
                         : "cc", "memory");                                              \
        R r = { a, d, f & FLAGS_MASK };                                                  \
        return r;                                                                        \
    }

/* rotates through carry */
DEF(rcl_al_cl,  "rclb %%cl, %%al")
DEF(rcl_ah_cl,  "rclb %%cl, %%ah")
DEF(rcl_ax_cl,  "rclw %%cl, %%ax")
DEF(rcl_eax_cl, "rcll %%cl, %%eax")
DEF(rcl_rax_cl, "rclq %%cl, %%rax")
DEF(rcr_al_cl,  "rcrb %%cl, %%al")
DEF(rcr_dh_cl,  "rcrb %%cl, %%dh")
DEF(rcr_ax_cl,  "rcrw %%cl, %%ax")
DEF(rcr_eax_cl, "rcrl %%cl, %%eax")
DEF(rcr_rax_cl, "rcrq %%cl, %%rax")
DEF(rcl_al_1,   "rclb $1, %%al")
DEF(rcr_al_1,   "rcrb $1, %%al")
DEF(rcl_dh_3,   "rclb $3, %%dh")
DEF(rcr_ax_3,   "rcrw $3, %%ax")
DEF(rcl_ax_9,   "rclw $9, %%ax")
DEF(rcr_ax_17,  "rcrw $17, %%ax")
DEF(rcl_al_9,   "rclb $9, %%al")
DEF(rcr_al_10,  "rcrb $10, %%al")
DEF(rcr_eax_6,  "rcrl $6, %%eax")
DEF(rcl_eax_31, "rcll $31, %%eax")
DEF(rcr_rax_12, "rcrq $12, %%rax")
DEF(rcl_rax_63, "rclq $63, %%rax")
/* plain rotates */
DEF(rol_al_cl,  "rolb %%cl, %%al")
DEF(ror_al_cl,  "rorb %%cl, %%al")
DEF(ror_dl_cl,  "rorb %%cl, %%dl")
DEF(rol_ax_cl,  "rolw %%cl, %%ax")
DEF(ror_ax_cl,  "rorw %%cl, %%ax")
DEF(ror_dx_cl,  "rorw %%cl, %%dx")
DEF(rol_eax_cl, "roll %%cl, %%eax")
DEF(ror_edx_cl, "rorl %%cl, %%edx")
DEF(rol_rax_cl, "rolq %%cl, %%rax")
DEF(ror_rdx_cl, "rorq %%cl, %%rdx")
DEF(ror_al_5,   "rorb $5, %%al")
DEF(rol_ax_8,   "rolw $8, %%ax")
DEF(ror_dx_13,  "rorw $13, %%dx")
DEF(rol_eax_16, "roll $16, %%eax")
DEF(ror_rax_8,  "rorq $8, %%rax")
DEF(rol_rax_56, "rolq $56, %%rax")
/* shifts */
DEF(shl_al_cl,  "shlb %%cl, %%al")
DEF(shl_dh_cl,  "shlb %%cl, %%dh")
DEF(shr_al_cl,  "shrb %%cl, %%al")
DEF(sar_dl_cl,  "sarb %%cl, %%dl")
DEF(sar_dh_cl,  "sarb %%cl, %%dh")
DEF(shl_ax_cl,  "shlw %%cl, %%ax")
DEF(shl_dx_cl,  "shlw %%cl, %%dx")
DEF(shr_ax_cl,  "shrw %%cl, %%ax")
DEF(sar_ax_cl,  "sarw %%cl, %%ax")
DEF(shl_eax_cl, "shll %%cl, %%eax")
DEF(shr_eax_cl, "shrl %%cl, %%eax")
DEF(sar_edx_cl, "sarl %%cl, %%edx")
DEF(shl_rax_cl, "shlq %%cl, %%rax")
DEF(shr_rax_cl, "shrq %%cl, %%rax")
DEF(sar_rax_cl, "sarq %%cl, %%rax")
DEF(shl_al_4,   "shlb $4, %%al")
DEF(sar_dh_4,   "sarb $4, %%dh")
DEF(sal_dh_6,   "salb $6, %%dh")
DEF(shr_ax_15,  "shrw $15, %%ax")
DEF(sar_rax_63, "sarq $63, %%rax")
/* double shifts */
DEF(shld_ax_bx_cl,   "shldw %%cl, %%bx, %%ax")
DEF(shrd_ax_bx_cl,   "shrdw %%cl, %%bx, %%ax")
DEF(shld_eax_ebx_cl, "shldl %%cl, %%ebx, %%eax")
DEF(shrd_eax_ebx_cl, "shrdl %%cl, %%ebx, %%eax")
DEF(shld_rax_rbx_cl, "shldq %%cl, %%rbx, %%rax")
DEF(shrd_rax_rbx_cl, "shrdq %%cl, %%rbx, %%rax")
DEF(shld_rax_rax_cl, "shldq %%cl, %%rax, %%rax")
DEF(shld_ax_bx_9,    "shldw $9, %%bx, %%ax")
DEF(shrd_ax_bx_18,   "shrdw $18, %%bx, %%ax")
DEF(shld_ax_bx_16,   "shldw $16, %%bx, %%ax")
DEF(shrd_dx_ax_cl,   "shrdw %%cl, %%ax, %%dx")
DEF(shrd_edx_ebx_cl, "shrdl %%cl, %%ebx, %%edx")
DEF(shld_eax_ebx_31, "shldl $31, %%ebx, %%eax")
DEF(shrd_rax_rbx_1,  "shrdq $1, %%rbx, %%rax")
/* bit tests */
DEF(bt_ax_bx,   "btw %%bx, %%ax")
DEF(bts_ax_bx,  "btsw %%bx, %%ax")
DEF(btr_ax_bx,  "btrw %%bx, %%ax")
DEF(btc_ax_bx,  "btcw %%bx, %%ax")
DEF(bt_eax_ebx, "btl %%ebx, %%eax")
DEF(btr_edx_ebx,"btrl %%ebx, %%edx")
DEF(bts_edx_ebx,"btsl %%ebx, %%edx")
DEF(bt_rax_rbx, "btq %%rbx, %%rax")
DEF(btr_rdx_rbx,"btrq %%rbx, %%rdx")
DEF(btr_ax_14,  "btrw $14, %%ax")
DEF(bts_ax_3,   "btsw $3, %%ax")
DEF(bt_dx_1,    "btw $1, %%dx")
DEF(btr_rdx_55, "btrq $55, %%rdx")
DEF(btc_eax_7,  "btcl $7, %%eax")
/* bit scans */
DEF(bsf_ax_bx,  "bsfw %%bx, %%ax")
DEF(bsr_ax_bx,  "bsrw %%bx, %%ax")
DEF(bsf_eax_ebx,"bsfl %%ebx, %%eax")
DEF(bsr_eax_ebx,"bsrl %%ebx, %%eax")
DEF(bsf_rax_rbx,"bsfq %%rbx, %%rax")
DEF(bsr_rax_rbx,"bsrq %%rbx, %%rax")
DEF(bsf_dx_ax,  "bsfw %%ax, %%dx")
/* byte swaps, including the 16-bit form the manual leaves undefined */
DEF(bswap_eax,  "bswapl %%eax")
DEF(bswap_rax,  "bswapq %%rax")
DEF(bswap_ax,   ".byte 0x66, 0x0f, 0xc8")
DEF(bswap_dx,   ".byte 0x66, 0x0f, 0xca")
/* carry arithmetic */
DEF(adc_al_bl,   "adcb %%bl, %%al")
DEF(adc_dh_bl,   "adcb %%bl, %%dh")
DEF(adc_ax_bx,   "adcw %%bx, %%ax")
DEF(adc_eax_ebx, "adcl %%ebx, %%eax")
DEF(adc_rax_rbx, "adcq %%rbx, %%rax")
DEF(sbb_al_bl,   "sbbb %%bl, %%al")
DEF(sbb_dl_bh,   "sbbb %%bh, %%dl")
DEF(sbb_ah_bh,   "sbbb %%bh, %%ah")
DEF(sbb_ax_bx,   "sbbw %%bx, %%ax")
DEF(sbb_eax_ebx, "sbbl %%ebx, %%eax")
DEF(sbb_rax_rbx, "sbbq %%rbx, %%rax")
DEF(sbb_rax_rax, "sbbq %%rax, %%rax")
DEF(adc_rax_0,   "adcq $0, %%rax")
DEF(sbb_rax_0,   "sbbq $0, %%rax")
DEF(adc_al_imm,  "adcb $0x7f, %%al")
DEF(sbb_dx_imm,  "sbbw $0x9a7a, %%dx")
/* plain arithmetic and flags */
DEF(add_al_bl,   "addb %%bl, %%al")
DEF(add_rax_rbx, "addq %%rbx, %%rax")
DEF(sub_dx_ax,   "subw %%ax, %%dx")
DEF(sub_dx_imm,  "subw $0x9a7a, %%dx")
DEF(sub_rax_rbx, "subq %%rbx, %%rax")
DEF(cmp_dl_imm,  "cmpb $0x11, %%dl")
DEF(cmp_ebx_edx, "cmpl %%edx, %%ebx")
DEF(test_al_dh,  "testb %%dh, %%al")
DEF(test_rax_imm,"testq $0x1a99, %%rax")
DEF(and_ax_bx,   "andw %%bx, %%ax")
DEF(and_rax_rdx, "andq %%rdx, %%rax")
DEF(xor_al_bl,   "xorb %%bl, %%al")
DEF(xor_rax_rbx, "xorq %%rbx, %%rax")
DEF(or_dh_imm,   "orb $0x2b, %%dh")
DEF(neg_al,      "negb %%al")
DEF(neg_eax,     "negl %%eax")
DEF(neg_rax,     "negq %%rax")
DEF(not_al,      "notb %%al")
DEF(not_dh,      "notb %%dh")
DEF(not_rax,     "notq %%rax")
DEF(inc_al,      "incb %%al")
DEF(inc_dl,      "incb %%dl")
DEF(dec_al,      "decb %%al")
DEF(inc_ax,      "incw %%ax")
DEF(dec_cx_copy, "movw %%cx, %%ax\n\tdecw %%ax")
DEF(inc_rax,     "incq %%rax")
DEF(dec_rax,     "decq %%rax")
/* flag instructions */
DEF(cmc,         "cmc")
DEF(clc,         "clc")
DEF(stc,         "stc")
DEF(lahf,        "lahf")
DEF(sahf,        "sahf")
DEF(pushf_popf,  "pushq %%rbx\n\tpopfq")
DEF(popf_then_adc, "pushq %%rbx\n\tpopfq\n\tadcq %%rdx, %%rax")
DEF(setb_dh,     "setb %%dh")
DEF(setae_dh,    "setae %%dh")
DEF(seto_dh,     "seto %%dh")
DEF(cmp_setcc,   "cmpq %%rbx, %%rax\n\tsetb %%al\n\tsetbe %%ah\n\tsetl %%dl\n\tsetle %%dh\n\tseto %%cl")
DEF(cmp_setcc2,  "cmpw %%bx, %%ax\n\tsets %%al\n\tsetz %%ah\n\tsetp %%dl\n\tsetge %%dh")
DEF(cmovb,       "cmovb %%rbx, %%rax")
DEF(cmovl,       "cmovl %%rbx, %%rdx")
/* conversions and partial registers */
DEF(movsx_dx_al,  "movsbw %%al, %%dx")
DEF(movsx_rax_al, "movsbq %%al, %%rax")
DEF(movzx_di_al,  "movzbw %%al, %%dx")
DEF(movsx_rax_ax, "movswq %%ax, %%rax")
DEF(movsxd,       "movslq %%eax, %%rax")
DEF(cbw,          "cbw")
DEF(cwde,         "cwtl")
DEF(cdqe,         "cltq")
DEF(cwd,          "cwtd")
DEF(cdq,          "cltd")
DEF(cqo,          "cqto")
DEF(mov_dh_write, "movb %%bl, %%dh")
DEF(mov_ah_write, "movb %%bl, %%ah")
DEF(mov_ax_write, "movw %%bx, %%ax")
DEF(mov_eax_write,"movl %%ebx, %%eax")
DEF(xchg_al_ah,   "xchgb %%al, %%ah")
DEF(xchg_ax_dx,   "xchgw %%ax, %%dx")
DEF(lea_scaled,   "leaq 0x2aab542d(,%%rcx,4), %%rax")
DEF(lea_rbx_rax,  "leaq 1(%%rbx,%%rax,8), %%rdx")
/* multiply and divide (inputs shaped so that divides cannot fault) */
DEF(mul_bl,       "mulb %%bl")
DEF(imul_bl,      "imulb %%bl")
DEF(mul_bx,       "mulw %%bx")
DEF(imul_bx,      "imulw %%bx")
DEF(mul_ebx,      "mull %%ebx")
DEF(mul_rbx,      "mulq %%rbx")
DEF(imul_rax_rbx, "imulq %%rbx, %%rax")
DEF(imul_ax_bx_imm,"imulw $0x1234, %%bx, %%ax")
DEF(div_cx,       "xorl %%edx, %%edx\n\tdivw %%cx")
DEF(idiv_cx,      "cwtd\n\tidivw %%cx")
DEF(div_ecx,      "xorl %%edx, %%edx\n\tdivl %%ecx")
DEF(div_rcx,      "xorl %%edx, %%edx\n\tdivq %%rcx")
DEF(idiv_rcx,     "cqto\n\tidivq %%rcx")
/* string of flag-sensitive ops the VM likes */
DEF(rcl_then_adc, "rclb %%cl, %%dh\n\tadcq %%rbx, %%rax")
DEF(shrd_then_sbb,"shrdw %%cl, %%bx, %%ax\n\tsbbq %%rbx, %%rdx")
DEF(bt_then_rcr,  "btw %%bx, %%ax\n\trcrw $1, %%dx")
DEF(neg_stc_add,  "negl %%eax\n\tstc\n\taddl %%ebx, %%eax\n\tshlb $4, %%al")
DEF(sub_rsi_minus1,"subq $-1, %%rax")
DEF(sub_rsi_minus8,"subq $-8, %%rax")
DEF(add_rbp_16,   "addq $16, %%rax")
DEF(shl_cl_2_dec, "shlb $2, %%cl\n\tdecw %%cx\n\tmovw %%cx, %%ax")
DEF(ror_dx_cl_btr,"rorw %%cl, %%dx\n\tbtrl %%ebx, %%edx")

static const struct { const char *name; testfn fn; } tests[] = {
#define E(n) { #n, t_##n },
E(rcl_al_cl) E(rcl_ah_cl) E(rcl_ax_cl) E(rcl_eax_cl) E(rcl_rax_cl)
E(rcr_al_cl) E(rcr_dh_cl) E(rcr_ax_cl) E(rcr_eax_cl) E(rcr_rax_cl)
E(rcl_al_1) E(rcr_al_1) E(rcl_dh_3) E(rcr_ax_3) E(rcl_ax_9) E(rcr_ax_17) E(rcl_al_9) E(rcr_al_10)
E(rcr_eax_6) E(rcl_eax_31) E(rcr_rax_12) E(rcl_rax_63)
E(rol_al_cl) E(ror_al_cl) E(ror_dl_cl) E(rol_ax_cl) E(ror_ax_cl) E(ror_dx_cl) E(rol_eax_cl) E(ror_edx_cl)
E(rol_rax_cl) E(ror_rdx_cl) E(ror_al_5) E(rol_ax_8) E(ror_dx_13) E(rol_eax_16) E(ror_rax_8) E(rol_rax_56)
E(shl_al_cl) E(shl_dh_cl) E(shr_al_cl) E(sar_dl_cl) E(sar_dh_cl) E(shl_ax_cl) E(shl_dx_cl) E(shr_ax_cl)
E(sar_ax_cl) E(shl_eax_cl) E(shr_eax_cl) E(sar_edx_cl) E(shl_rax_cl) E(shr_rax_cl) E(sar_rax_cl)
E(shl_al_4) E(sar_dh_4) E(sal_dh_6) E(shr_ax_15) E(sar_rax_63)
E(shld_ax_bx_cl) E(shrd_ax_bx_cl) E(shld_eax_ebx_cl) E(shrd_eax_ebx_cl) E(shld_rax_rbx_cl) E(shrd_rax_rbx_cl)
E(shld_rax_rax_cl) E(shld_ax_bx_9) E(shrd_ax_bx_18) E(shld_ax_bx_16) E(shrd_dx_ax_cl) E(shrd_edx_ebx_cl)
E(shld_eax_ebx_31) E(shrd_rax_rbx_1)
E(bt_ax_bx) E(bts_ax_bx) E(btr_ax_bx) E(btc_ax_bx) E(bt_eax_ebx) E(btr_edx_ebx) E(bts_edx_ebx) E(bt_rax_rbx)
E(btr_rdx_rbx) E(btr_ax_14) E(bts_ax_3) E(bt_dx_1) E(btr_rdx_55) E(btc_eax_7)
E(bsf_ax_bx) E(bsr_ax_bx) E(bsf_eax_ebx) E(bsr_eax_ebx) E(bsf_rax_rbx) E(bsr_rax_rbx) E(bsf_dx_ax)
E(bswap_eax) E(bswap_rax) E(bswap_ax) E(bswap_dx)
E(adc_al_bl) E(adc_dh_bl) E(adc_ax_bx) E(adc_eax_ebx) E(adc_rax_rbx)
E(sbb_al_bl) E(sbb_dl_bh) E(sbb_ah_bh) E(sbb_ax_bx) E(sbb_eax_ebx) E(sbb_rax_rbx) E(sbb_rax_rax)
E(adc_rax_0) E(sbb_rax_0) E(adc_al_imm) E(sbb_dx_imm)
E(add_al_bl) E(add_rax_rbx) E(sub_dx_ax) E(sub_dx_imm) E(sub_rax_rbx) E(cmp_dl_imm) E(cmp_ebx_edx)
E(test_al_dh) E(test_rax_imm) E(and_ax_bx) E(and_rax_rdx) E(xor_al_bl) E(xor_rax_rbx) E(or_dh_imm)
E(neg_al) E(neg_eax) E(neg_rax) E(not_al) E(not_dh) E(not_rax) E(inc_al) E(inc_dl) E(dec_al) E(inc_ax)
E(dec_cx_copy) E(inc_rax) E(dec_rax)
E(cmc) E(clc) E(stc) E(lahf) E(sahf) E(pushf_popf) E(popf_then_adc) E(setb_dh) E(setae_dh) E(seto_dh)
E(cmp_setcc) E(cmp_setcc2) E(cmovb) E(cmovl)
E(movsx_dx_al) E(movsx_rax_al) E(movzx_di_al) E(movsx_rax_ax) E(movsxd) E(cbw) E(cwde) E(cdqe) E(cwd) E(cdq) E(cqo)
E(mov_dh_write) E(mov_ah_write) E(mov_ax_write) E(mov_eax_write) E(xchg_al_ah) E(xchg_ax_dx) E(lea_scaled) E(lea_rbx_rax)
E(mul_bl) E(imul_bl) E(mul_bx) E(imul_bx) E(mul_ebx) E(mul_rbx) E(imul_rax_rbx) E(imul_ax_bx_imm)
E(div_cx) E(idiv_cx) E(div_ecx) E(div_rcx) E(idiv_rcx)
E(rcl_then_adc) E(shrd_then_sbb) E(bt_then_rcr) E(neg_stc_add) E(sub_rsi_minus1) E(sub_rsi_minus8) E(add_rbp_16)
E(shl_cl_2_dec) E(ror_dx_cl_btr)
#undef E
};

static uint64_t rng_state;
static uint64_t rnd(void)
{
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    rng_state = x;
    return x;
}

static const uint64_t counts[] = { 0, 1, 2, 7, 8, 9, 15, 16, 17, 18, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256 };
static const uint64_t specials[] = { 0, 1, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fffffff,
                                     0x80000000, 0xffffffff, 0x100000000ULL, 0x142557c38ULL, 0x142813598ULL,
                                     0x7fffffffffffffffULL, 0x8000000000000000ULL, 0xffffffffffffffffULL };

#define CASES 96
#define PRINTED 40

static FILE *out;

static void emit(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (out) { va_start(ap, fmt); vfprintf(out, fmt, ap); va_end(ap); }
}

int main(void)
{
    unsigned ti;
    out = fopen("fexdiff-results.txt", "w");
    emit("fexdiff 1 tests=%u cases=%u\n", (unsigned)(sizeof(tests) / sizeof(tests[0])), CASES);
    for (ti = 0; ti < sizeof(tests) / sizeof(tests[0]); ti++)
    {
        const char *name = tests[ti].name;
        uint64_t h = 1469598103934665603ULL, seed = 0x9e3779b97f4a7c15ULL;
        const char *p;
        unsigned i;
        for (p = name; *p; p++) seed = (seed ^ (unsigned char)*p) * 1099511628211ULL;
        rng_state = seed | 1;
        for (i = 0; i < CASES; i++)
        {
            uint64_t a = rnd(), d = rnd(), b = rnd(), c, cf = rnd() & 1;
            R r;
            if (i < 20) c = counts[i];
            else if (i < 39) a = specials[i - 20], c = rnd() & 0x3f;
            else if (i < 58) b = specials[i - 39], c = rnd() & 0x3f;
            else c = rnd();
            if (strncmp(name, "div_", 4) == 0 || strncmp(name, "idiv_", 5) == 0)
            {   /* keep the quotient in range: divisor never 0, dividend narrow */
                c |= 1;
                if (name[0] == 'd') a &= 0xffff; else a = (int16_t)a;
                if (strcmp(name, "div_ecx") == 0) a = (uint32_t)a;
                if (strcmp(name, "div_rcx") == 0 || strcmp(name, "idiv_rcx") == 0) a = (uint32_t)a, c |= 0x100000000ULL;
            }
            if (strncmp(name, "pushf", 5) == 0 || strncmp(name, "popf", 4) == 0)
                b = (b & FLAGS_MASK) | 0x202;   /* popfq: arithmetic flags only, never TF/DF/AC */
            r = tests[ti].fn(a, d, b, c, cf);
            h = (h ^ r.a) * 1099511628211ULL;
            h = (h ^ r.d) * 1099511628211ULL;
            h = (h ^ r.f) * 1099511628211ULL;
            if (i < PRINTED)
                emit("T %-16s %2u a=%016llx d=%016llx b=%016llx c=%016llx cf=%llu -> a=%016llx d=%016llx f=%03llx\n",
                     name, i, (unsigned long long)a, (unsigned long long)d, (unsigned long long)b,
                     (unsigned long long)c, (unsigned long long)cf, (unsigned long long)r.a,
                     (unsigned long long)r.d, (unsigned long long)r.f);
        }
        emit("H %-16s %016llx\n", name, (unsigned long long)h);
    }
    emit("fexdiff done\n");
    if (out) fclose(out);
    return 0;
}
