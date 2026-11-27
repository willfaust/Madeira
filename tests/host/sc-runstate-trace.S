/* Bounded flight recorder for the helper's MessagePumpWin::Run state writes.
 * The hooks replay the displaced instructions. They do not repair or skip work. */
.intel_syntax noprefix
.text
.global sc_run_install, sc_run_restore, sc_run_record

.macro save_volatile
    pushfq
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 0x60
    movdqu xmmword ptr [rsp], xmm0
    movdqu xmmword ptr [rsp+0x10], xmm1
    movdqu xmmword ptr [rsp+0x20], xmm2
    movdqu xmmword ptr [rsp+0x30], xmm3
    movdqu xmmword ptr [rsp+0x40], xmm4
    movdqu xmmword ptr [rsp+0x50], xmm5
.endm
.macro restore_volatile
    movdqu xmm0, xmmword ptr [rsp]
    movdqu xmm1, xmmword ptr [rsp+0x10]
    movdqu xmm2, xmmword ptr [rsp+0x20]
    movdqu xmm3, xmmword ptr [rsp+0x30]
    movdqu xmm4, xmmword ptr [rsp+0x40]
    movdqu xmm5, xmmword ptr [rsp+0x50]
    add rsp, 0x60
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    popfq
.endm

sc_run_install:
    mov qword ptr [rcx+0x40], rax
    save_volatile
    mov rdx, rax
    mov r8d, 1
    call sc_run_record
    restore_volatile
    mov rax, qword ptr [rcx]
    jmp install_return
/* 16-byte alignment of sc_run_restore is a no-op here (already aligned); the
 * .balign 16, 0x90 is spelled as zero bytes so both GNU as (which releases a
 * 0x90 fill as multi-byte NOPs) and other assemblers emit identical bytes. */
sc_run_restore:
    mov qword ptr [rbx+0x40], rdi
    save_volatile
    mov rcx, rbx
    mov rdx, rdi
    mov r8d, 2
    call sc_run_record
    restore_volatile
    mov rbx, qword ptr [rsp+0x50]
    jmp restore_return
/* The 11-byte gap spelled out as production has it (the canonical 11-byte
 * NOP): .balign 16, 0x90 releases that fill as multi-byte NOPs in GNU as and
 * as literal 0x90s elsewhere, so the bytes are pinned for every assembler. */
.byte 0x66,0x66,0x2e,0x0f,0x1f,0x84,0x00,0x00,0x00,0x00,0x00
sc_run_record:
    push rbx
    push rsi
    push rdi
    sub rsp, 0x20
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
    call qword ptr [rip+get_thread_id]
    mov r9d, eax
    lea r10, [rip+trace_ring]
    mov eax, 1
    lock xadd qword ptr [r10], rax
    mov rcx, rax
    and ecx, 15
    shl ecx, 5
    lea r10, [r10+rcx+8]
    inc rax
    mov qword ptr [r10], 0
    mov dword ptr [r10+8], r9d
    mov dword ptr [r10+12], edi
    mov qword ptr [r10+16], rbx
    mov qword ptr [r10+24], rsi
    xchg qword ptr [r10], rax
    add rsp, 0x20
    pop rdi
    pop rsi
    pop rbx
    ret
