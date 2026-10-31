#include "abi.h"
.text
.p2align 2
.macro LOAD_GUEST_FP
    ldr w0, [x28, #FEX_MXCSR]
    ubfx w1, w0, #13, #2
    rbit w1, w1
    lsr w1, w1, #30
    mrs x2, FPCR
    bic x2, x2, #(7 << 22)
    bic x2, x2, #7
    bic x2, x2, #0x1f00
    bic x2, x2, #0x8000
    bic x2, x2, #(1 << 25)
    bfi x2, x1, #22, #2
    ubfx w1, w0, #15, #1
    bfi x2, x1, #24, #1
    msr FPCR, x2
    ldr w0, [x28, #(FEX_FRAME_SIZE + 16)]
    msr FPSR, x0
.endm
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
    LOAD_GUEST_FP
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
    ldr x1, [x28, #(FEX_FRAME_SIZE + 24)]
    add x0, x0, x1
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
    mrs x0, FPSR
    str w0, [x28, #(FEX_FRAME_SIZE + 16)]
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

.globl _madeira_fex_unsupported
_madeira_fex_unsupported:
    mov x0, #0xff01
    movk x0, #0xff, lsl #16
    str x0, [x28, #FEX_FAULT]
.globl _madeira_fex_guest_fault
_madeira_fex_guest_fault:
    b Lrestore_host

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
    LOAD_GUEST_FP
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
    mrs x16, FPCR
    mrs x17, FPSR
    str x16, [sp, #512]
    str x17, [sp, #520]
    mov x19, sp
    bl _madeira_ec_thread_current
    cbz x0, Lec_unbound
    ldr x17, [x0]
    cbz x17, Lec_first
    ldr x17, [x17, #FEX_STACK]
    b Lec_bound
Lec_first:
    ldr x17, [x0, #24]
Lec_bound:
    ldr x16, [x0, #8]
    ldr x0, [x0, #16]
    mov x1, x19
    mov sp, x17
    sub sp, sp, #16
    blr x16
    mov sp, x19
    ldr x16, [sp, #512]
    ldr x17, [sp, #520]
    msr FPCR, x16
    msr FPSR, x17
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
Lec_unbound:
    bl _madeira_ec_thread_missing

.globl _madeira_ec_check
_madeira_ec_check:
    sub sp, sp, #416
    stp x0, x1, [sp]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x30, [sp, #96]
    str x19, [sp, #112]
    stp q0, q1, [sp, #128]
    stp q2, q3, [sp, #160]
    stp q4, q5, [sp, #192]
    stp q6, q7, [sp, #224]
    stp q8, q9, [sp, #256]
    stp q10, q11, [sp, #288]
    stp q12, q13, [sp, #320]
    stp q14, q15, [sp, #352]
    mrs x16, FPCR
    mrs x17, FPSR
    stp x16, x17, [sp, #384]
    bl _madeira_ec_thread_current
    cbz x0, Lec_native
    ldr x13, [x0, #32]
    ldr x14, [x0, #40]
    ldar x14, [x14]
    ldr x9, [sp, #72]
Lec_check_next:
    cbz x14, Lec_native
    ldp x16, x17, [x13], #16
    sub x16, x9, x16
    cmp x16, x17
    b.lo Lec_guest
    sub x14, x14, #1
    b Lec_check_next
Lec_native:
    ldr x0, [sp, #72]
    bl _madeira_ec_native_target
    mov w13, w0
    b Lec_checked
Lec_guest:
    mov w13, #0
Lec_checked:
    ldp x16, x17, [sp, #384]
    msr FPCR, x16
    msr FPSR, x17
    ldp q0, q1, [sp, #128]
    ldp q2, q3, [sp, #160]
    ldp q4, q5, [sp, #192]
    ldp q6, q7, [sp, #224]
    ldp q8, q9, [sp, #256]
    ldp q10, q11, [sp, #288]
    ldp q12, q13, [sp, #320]
    ldp q14, q15, [sp, #352]
    ldp x0, x1, [sp]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x30, [sp, #96]
    ldr x19, [sp, #112]
    add sp, sp, #416
    cmp w13, #0
    csel x11, x9, x10, ne
    ret
.globl _madeira_ec_check_cfg
_madeira_ec_check_cfg:
    mov x9, x11
    b _madeira_ec_check
