/* madeira-d3d12 list-journal, x64 trampolines (see madeira_list_journal.h).
 *
 * mad_jr_list_tramps[slot]: every list slot that is not journaled points here
 * when list-journal or api-census is on. A list whose journal holds records is
 * flushed first (one call into ARM64EC, with the argument registers kept), then
 * the call goes on to the slot's ARM64EC method as a tail jump, so the stack
 * arguments and the return address are the caller's own.
 *
 * mad_jr_count_tramps[slot]: api-census counting for the other interfaces.
 *
 * mad_res_gva_x64: ID3D12Resource::GetGPUVirtualAddress without the crossing.
 *
 * No RIP-relative data access anywhere: the state is struct mad_jr_ctx, found
 * through the object (rcx -> vtable -> the pointer just before slot 0). */
#include "madeira_list_journal.h"

    .text

    .macro LIST_TRAMP i
    .balign 16
mad_jr_list_tramp_\i:
    movq (%rcx), %rax
    movq -8(%rax), %rax
    cmpb $0, MAD_JR_CTX_CENSUS(%rax)
    je 1f
    incl MAD_JR_CTX_CALLS+4*\i(%rax)
1:  cmpl $0, MAD_JR_USED_OFFSET(%rcx)
    jne 2f
    jmpq *8*\i(%rax)
2:  movl $\i, %r10d
    jmp mad_jr_flush_and_go
    .endm

    .macro COUNT_TRAMP i
    .balign 16
mad_jr_count_tramp_\i:
    movq (%rcx), %rax
    movq -8(%rax), %rax
    incl MAD_JR_CTX_CALLS+4*\i(%rax)
    jmpq *8*\i(%rax)
    .endm

    .irp i, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95
    LIST_TRAMP \i
    .endr

    .irp i, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95
    COUNT_TRAMP \i
    .endr

/* rax = the list's struct mad_jr_ctx, r10d = slot; rcx, rdx, r8, r9 and xmm0-3
 * are the caller's arguments. One stack allocation (described for the
 * unwinder): shadow space, xmm0-3, the integer argument registers, ctx, slot. */
    .balign 16
    .def mad_jr_flush_and_go; .scl 3; .type 32; .endef
    .seh_proc mad_jr_flush_and_go
mad_jr_flush_and_go:
    subq $0x98, %rsp
    .seh_stackalloc 0x98
    .seh_endprologue
    movdqu %xmm0, 0x20(%rsp)
    movdqu %xmm1, 0x30(%rsp)
    movdqu %xmm2, 0x40(%rsp)
    movdqu %xmm3, 0x50(%rsp)
    movq %rcx, 0x60(%rsp)
    movq %rdx, 0x68(%rsp)
    movq %r8, 0x70(%rsp)
    movq %r9, 0x78(%rsp)
    movq %rax, 0x80(%rsp)
    movq %r10, 0x88(%rsp)
    callq *MAD_JR_CTX_FLUSH(%rax)
    movdqu 0x20(%rsp), %xmm0
    movdqu 0x30(%rsp), %xmm1
    movdqu 0x40(%rsp), %xmm2
    movdqu 0x50(%rsp), %xmm3
    movq 0x60(%rsp), %rcx
    movq 0x68(%rsp), %rdx
    movq 0x70(%rsp), %r8
    movq 0x78(%rsp), %r9
    movq 0x80(%rsp), %rax
    movq 0x88(%rsp), %r10
    movq (%rax,%r10,8), %rax
    addq $0x98, %rsp
    rex64 jmpq *%rax
    .seh_endproc

    .balign 16
    .globl mad_res_gva_x64
mad_res_gva_x64:
    movq (%rcx), %rax
    movq -8(%rax), %rax
    cmpb $0, MAD_JR_CTX_CENSUS(%rax)
    je 1f
    incl MAD_JR_CTX_CALLS+4*MAD_RES_GVA_SLOT(%rax)
1:  movq MAD_RES_GPU_ADDRESS_OFFSET(%rcx), %rax
    retq

    .section .rdata,"dr"
    .balign 8
    .globl mad_jr_list_tramps
mad_jr_list_tramps:
    .irp i, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95
    .quad mad_jr_list_tramp_\i
    .endr
    .globl mad_jr_count_tramps
mad_jr_count_tramps:
    .irp i, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95
    .quad mad_jr_count_tramp_\i
    .endr
