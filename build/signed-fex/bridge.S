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
Lrestore_host:
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

.p2align 2
.globl _madeira_ec_enter
_madeira_ec_enter:
    mov x13, x2
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
    mov x9, x1
    mov x14, sp
    str x14, [x28, #FEX_STACK]
    ldr x14, [x28, #FEX_GREGS+32]
    ldr x30, [x14], #8
    mov sp, x14
    mov x4, x14
    ldr x0, [x28, #FEX_GREGS+8]
    ldr x1, [x28, #FEX_GREGS+16]
    ldp x2, x3, [x28, #FEX_GREGS+64]
    ldr x8, [x28, #FEX_GREGS]
    ldp x19, x20, [x28, #FEX_GREGS+96]
    ldp x21, x22, [x28, #FEX_GREGS+112]
    ldp x25, x26, [x28, #FEX_GREGS+48]
    ldr x27, [x28, #FEX_GREGS+24]
    ldr x29, [x28, #FEX_GREGS+40]
    ldp q0, q1, [x28, #FEX_XMM+0]
    ldp q2, q3, [x28, #FEX_XMM+32]
    ldp q4, q5, [x28, #FEX_XMM+64]
    ldp q6, q7, [x28, #FEX_XMM+96]
    ldp q8, q9, [x28, #FEX_XMM+128]
    ldp q10, q11, [x28, #FEX_XMM+160]
    ldp q12, q13, [x28, #FEX_XMM+192]
    ldp q14, q15, [x28, #FEX_XMM+224]
    br x13

.globl _madeira_ec_return
_madeira_ec_return:
    str x30, [x28, #FEX_RIP]
    mov x13, sp
    str x13, [x28, #FEX_GREGS+32]
    str x8, [x28, #FEX_GREGS]
    str x0, [x28, #FEX_GREGS+8]
    str x1, [x28, #FEX_GREGS+16]
    stp x2, x3, [x28, #FEX_GREGS+64]
    stp x19, x20, [x28, #FEX_GREGS+96]
    stp x21, x22, [x28, #FEX_GREGS+112]
    stp x25, x26, [x28, #FEX_GREGS+48]
    str x27, [x28, #FEX_GREGS+24]
    str x29, [x28, #FEX_GREGS+40]
    stp q0, q1, [x28, #FEX_XMM+0]
    stp q2, q3, [x28, #FEX_XMM+32]
    stp q4, q5, [x28, #FEX_XMM+64]
    stp q6, q7, [x28, #FEX_XMM+96]
    stp q8, q9, [x28, #FEX_XMM+128]
    stp q10, q11, [x28, #FEX_XMM+160]
    stp q12, q13, [x28, #FEX_XMM+192]
    stp q14, q15, [x28, #FEX_XMM+224]
    b Lrestore_host

.p2align 2
.globl _madeira_ec_call
_madeira_ec_call:
    sub sp, sp, #1024
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp xzr, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    add x16, sp, #1024
    str x16, [sp, #248]
    stp q0, q1, [sp, #256]
    stp q2, q3, [sp, #288]
    stp q4, q5, [sp, #320]
    stp q6, q7, [sp, #352]
    stp q8, q9, [sp, #384]
    stp q10, q11, [sp, #416]
    stp q12, q13, [sp, #448]
    stp q14, q15, [sp, #480]
    mov x1, sp
    mov x19, sp
    ldr x0, [x28, #FEX_FRAME_SIZE+8]
    ldr x16, [x28, #FEX_FRAME_SIZE]
    ldr x17, [x28, #FEX_STACK]
    mov sp, x17
    sub sp, sp, #16
    blr x16
    mov sp, x19
    ldp q0, q1, [sp, #256]
    ldp q2, q3, [sp, #288]
    ldp q4, q5, [sp, #320]
    ldp q6, q7, [sp, #352]
    ldp q8, q9, [sp, #384]
    ldp q10, q11, [sp, #416]
    ldp q12, q13, [sp, #448]
    ldp q14, q15, [sp, #480]
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldr x19, [sp, #152]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #1024
    ret

.globl _madeira_ec_check
_madeira_ec_check:
    adrp x16, Lec_guest_base@PAGE
    ldr x16, [x16, Lec_guest_base@PAGEOFF]
    sub x17, x9, x16
    adrp x16, Lec_guest_size@PAGE
    ldr x16, [x16, Lec_guest_size@PAGEOFF]
    cmp x17, x16
    csel x11, x10, x9, lo
    ret
.globl _madeira_ec_check_cfg
_madeira_ec_check_cfg:
    mov x9, x11
    b _madeira_ec_check
.section __TEXT,__const
.p2align 3
Lec_guest_base: .quad FEX_GUEST_BASE
Lec_guest_size: .quad FEX_GUEST_SIZE
