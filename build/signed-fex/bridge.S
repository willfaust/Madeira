#include "abi.h"
.text
.p2align 2
.globl _madeira_fex_enter
_madeira_fex_enter:
    stp x29, x30, [sp, #-192]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mrs x2, FPCR
    mrs x3, FPSR
    stp x2, x3, [sp, #160]
    mov x28, x0
    mov x3, x1
    mov x2, sp
    str x2, [x28, #FEX_STACK]
    ldr w0, [x28, #FEX_NZCV]
    msr NZCV, x0
    ldp w26, w27, [x28, #FEX_PF]
    ldp x4, x7, [x28, #FEX_GREGS]
    ldp x5, x6, [x28, #FEX_GREGS+16]
    ldp x8, x9, [x28, #FEX_GREGS+32]
    ldp x10, x11, [x28, #FEX_GREGS+48]
    ldp x12, x13, [x28, #FEX_GREGS+64]
    ldp x14, x15, [x28, #FEX_GREGS+80]
    ldp x16, x17, [x28, #FEX_GREGS+96]
    ldp x19, x29, [x28, #FEX_GREGS+112]
    ldp q16, q17, [x28, #FEX_XMM]
    ldp q18, q19, [x28, #FEX_XMM+32]
    ldp q20, q21, [x28, #FEX_XMM+64]
    ldp q22, q23, [x28, #FEX_XMM+96]
    ldp q24, q25, [x28, #FEX_XMM+128]
    ldp q26, q27, [x28, #FEX_XMM+160]
    ldp q28, q29, [x28, #FEX_XMM+192]
    ldp q30, q31, [x28, #FEX_XMM+224]
    br x3

.globl _madeira_fex_direct
_madeira_fex_direct:
    // FEX's unlinked thunk leaves the immutable exit record in LR.
    ldr x0, [x30, #8]
    str x0, [x28, #FEX_RIP]
    b _madeira_fex_indirect

.globl _madeira_fex_indirect
_madeira_fex_indirect:
    stp x4, x7, [x28, #FEX_GREGS]
    stp x5, x6, [x28, #FEX_GREGS+16]
    stp x8, x9, [x28, #FEX_GREGS+32]
    stp x10, x11, [x28, #FEX_GREGS+48]
    stp x12, x13, [x28, #FEX_GREGS+64]
    stp x14, x15, [x28, #FEX_GREGS+80]
    stp x16, x17, [x28, #FEX_GREGS+96]
    stp x19, x29, [x28, #FEX_GREGS+112]
    stp q16, q17, [x28, #FEX_XMM]
    stp q18, q19, [x28, #FEX_XMM+32]
    stp q20, q21, [x28, #FEX_XMM+64]
    stp q22, q23, [x28, #FEX_XMM+96]
    stp q24, q25, [x28, #FEX_XMM+128]
    stp q26, q27, [x28, #FEX_XMM+160]
    stp q28, q29, [x28, #FEX_XMM+192]
    stp q30, q31, [x28, #FEX_XMM+224]
    stp w26, w27, [x28, #FEX_PF]
    mrs x0, NZCV
    str w0, [x28, #FEX_NZCV]
    ldr x0, [x28, #FEX_STACK]
    mov sp, x0
    ldp x0, x1, [sp, #160]
    msr FPCR, x0
    msr FPSR, x1
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #192
    ret
