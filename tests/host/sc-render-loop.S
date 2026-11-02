/* Win64 renderer-loop adapter embedded in virtual_ios.c.
 * check-sc-render-loop.py links the symbols to the guarded helper RVAs and
 * checks these bytes against the production blob before executing it. */
.intel_syntax noprefix
.text
.global sc_loop_init, sc_loop_pump, sc_loop_add_ref, sc_loop_release, sc_loop_one_ref, sc_loop_any_ref
sc_loop_init:
    push rbx
    sub rsp, 0x30
    mov rbx, rcx
    mov dword ptr [rsp+0x20], 0
    call current_loop
    test rax, rax
    jnz original
    mov ecx, 0x160
    call helper_new
    test rax, rax
    jz original
    mov rcx, rax
    xor edx, edx
    call loop_ctor
    mov qword ptr [rip+loop_cache], rax
    mov dword ptr [rsp+0x20], 1
original:
    mov rcx, rbx
    call original_webkit
    cmp dword ptr [rsp+0x20], 0
    je init_done
    mov ecx, 6                      /* TID_RENDERER */
    lea rdx, [rip+task]
    mov r8d, 10                     /* minimum delay in milliseconds */
    call qword ptr [rip+cef_post_delayed]
init_done:
    add rsp, 0x30
    pop rbx
    ret
.balign 16, 0x90
sc_loop_pump:
    push rbx
    push rsi
    sub rsp, 0x58
    mov rbx, rcx
    mov rcx, qword ptr [rbx+0x30]
    test rcx, rcx
    jz pump_done
    /* Match MessageLoop's scoped RunState: level, quit flag, dispatcher.
     * DoWork/DoDelayedWork consult it for non-nestable tasks. */
    mov rax, qword ptr [rcx+0x128]
    mov qword ptr [rsp+0x30], rax
    mov edx, 1
    test rax, rax
    jz state_ready
    mov edx, dword ptr [rax]
    inc edx
state_ready:
    mov dword ptr [rsp+0x38], edx
    mov dword ptr [rsp+0x3c], 0
    mov qword ptr [rsp+0x40], 0
    lea rax, [rsp+0x38]
    mov qword ptr [rcx+0x128], rax
    mov esi, 32                     /* yield back to Chromium after a burst */
work_next:
    mov rcx, qword ptr [rbx+0x30]
    call loop_work
    mov byte ptr [rsp+0x28], al
    mov rcx, qword ptr [rbx+0x30]
    lea rdx, [rsp+0x20]
    call loop_delayed
    or al, byte ptr [rsp+0x28]
    jz work_idle
    dec esi
    jnz work_next
    jmp state_restore
work_idle:
    mov rcx, qword ptr [rbx+0x30]
    call loop_idle
state_restore:
    mov rcx, qword ptr [rbx+0x30]
    mov rax, qword ptr [rsp+0x30]
    mov qword ptr [rcx+0x128], rax
    mov ecx, 6
    mov rdx, rbx
    mov r8d, 10
    call qword ptr [rip+cef_post_delayed]
pump_done:
    add rsp, 0x58
    pop rsi
    pop rbx
    ret
/* The 15-byte gap spelled out as production has it (an 11-byte NOP, then a
 * 4-byte one): GNU as releases order a two-NOP pad differently. */
.byte 0x66,0x66,0x2e,0x0f,0x1f,0x84,0x00,0x00,0x00,0x00,0x00
.byte 0x0f,0x1f,0x40,0x00
.balign 16, 0x90
sc_loop_add_ref:
    lock inc dword ptr [rcx+0x38]
    ret
.balign 16, 0x90
sc_loop_release:
    lock dec dword ptr [rcx+0x38]
    xor eax, eax                    /* the image retains an owner reference */
    ret
.balign 16, 0x90
sc_loop_one_ref:
    cmp dword ptr [rcx+0x38], 1
    sete al
    movzx eax, al
    ret
.balign 16, 0x90
sc_loop_any_ref:
    cmp dword ptr [rcx+0x38], 0
    setne al
    movzx eax, al
    ret
