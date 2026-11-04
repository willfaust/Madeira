/* Keep the browser manager and its transport intact under --single-process.
 * A renderer manager is constructed and initialized on CEF's renderer thread
 * before its message handlers are registered. All objects use the helper's own
 * allocator, constructor and initializer; no live manager is shallow-copied.
 * The main command-line reference stays alive until after cef_shutdown. The
 * additional by-value reference passed to Initialize is explicitly retained.
 *
 * Assembled twice. Without symbols: the first helper build, everything in one
 * .text tail blob. With --defsym SCH296=1: Social Club 2.4.0.296, whose .text
 * tail has 792 bytes, so the getter and destructor hooks are plain Win64
 * functions (their sites have no live volatile state, see virtual_ios.c), the
 * creation log line is dropped, and the three small stubs go into their own
 * sections, which the test links at verified int3 padding between functions.
 */
.intel_syntax noprefix
.text
.global sc_ipc_get_manager, sc_ipc_capture_config, sc_ipc_ctor_store
.global sc_ipc_renderer_role, sc_ipc_global_loop, sc_ipc_initial_connect
.global sc_ipc_destroy
.global sc_ipc_direct_getter
.ifdef SCH296
/* Every caller CALLs the getter (the one inlined load is routed through a CALL
 * below), so only the Win64 nonvolatile registers need to survive. */
sc_ipc_get_manager:
    sub rsp, 0x28
    mov ecx, 6                    /* TID_RENDERER */
    call qword ptr [rip+cef_currently_on]
    test eax, eax
    je browser
    mov rax, qword ptr [rip+renderer_manager]
    test rax, rax
    jne get_done                  /* also supports Initialize's own getters */
    cmp qword ptr [rip+command_line], 0
    je browser                    /* CEF has not been initialized yet */
    mov ecx, 0x1a30
    call helper_new
    test rax, rax
    je browser
    mov qword ptr [rip+renderer_manager], rax
    mov rcx, rax
    call manager_ctor
    mov rdx, qword ptr [rip+command_line]
    mov qword ptr [rsp+0x20], rdx   /* CefRefPtr passed by value to Initialize */
    mov rax, qword ptr [rdx+8]
    lea rcx, [rdx+8]
    movsxd rax, dword ptr [rax+4]
    add rcx, rax
    mov rax, qword ptr [rcx]
    call qword ptr [rax]           /* CefBaseRefCounted::AddRef */
    lea rdx, [rsp+0x20]
    mov rcx, qword ptr [rip+renderer_manager]
    call manager_init
    mov rax, qword ptr [rip+renderer_manager]
    jmp get_done
browser:
    mov rax, qword ptr [rip+browser_manager]
get_done:
    add rsp, 0x28
    ret
.else
sc_ipc_get_manager:
    pushfq
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 0x90
    movdqu xmmword ptr [rsp+0x30], xmm0
    movdqu xmmword ptr [rsp+0x40], xmm1
    movdqu xmmword ptr [rsp+0x50], xmm2
    movdqu xmmword ptr [rsp+0x60], xmm3
    movdqu xmmword ptr [rsp+0x70], xmm4
    movdqu xmmword ptr [rsp+0x80], xmm5
    mov ecx, 6                    /* TID_RENDERER */
    call qword ptr [rip+cef_currently_on]
    test eax, eax
    je browser
    mov rax, qword ptr [rip+renderer_manager]
    test rax, rax
    jne get_done                  /* also supports Initialize's own getters */
    cmp qword ptr [rip+command_line], 0
    je browser                    /* CEF has not been initialized yet */
    mov ecx, 0x1a30
    call helper_new
    test rax, rax
    je browser
    mov qword ptr [rip+renderer_manager], rax
    mov rcx, rax
    call manager_ctor
    mov rdx, qword ptr [rip+command_line]
    mov qword ptr [rsp+0x20], rdx   /* CefRefPtr passed by value to Initialize */
    mov rax, qword ptr [rdx+8]
    lea rcx, [rdx+8]
    movsxd rax, dword ptr [rax+4]
    add rcx, rax
    mov rax, qword ptr [rcx]
    call qword ptr [rax]           /* CefBaseRefCounted::AddRef */
    lea rdx, [rsp+0x20]
    mov rcx, qword ptr [rip+renderer_manager]
    call manager_init
    movzx eax, al
    mov dword ptr [rsp+0x20], eax  /* actual Initialize result, not a forced success */
    mov r8, qword ptr [rip+renderer_manager]
    mov r9, qword ptr [rip+browser_manager]
    lea rdx, [rip+created_message]
    xor ecx, ecx
    call helper_log
    mov rax, qword ptr [rip+renderer_manager]
    jmp get_done
browser:
    mov rax, qword ptr [rip+browser_manager]
get_done:
    movdqu xmm0, xmmword ptr [rsp+0x30]
    movdqu xmm1, xmmword ptr [rsp+0x40]
    movdqu xmm2, xmmword ptr [rsp+0x50]
    movdqu xmm3, xmmword ptr [rsp+0x60]
    movdqu xmm4, xmmword ptr [rsp+0x70]
    movdqu xmm5, xmmword ptr [rsp+0x80]
    add rsp, 0x90
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    popfq
    ret
.endif

sc_ipc_capture_config:
.ifdef SCH296
    mov qword ptr [rsp+0x10], rbx  /* displaced Initialize instruction */
.else
    mov qword ptr [rsp+0x20], rbx  /* displaced Initialize instruction */
.endif
    push rax
    mov rax, qword ptr [rdx]
    mov qword ptr [rip+command_line], rax
    pop rax
    jmp init_continue

sc_ipc_ctor_store:
    pushfq
    cmp rbx, qword ptr [rip+renderer_manager]
    je ctor_done
    mov qword ptr [rip+browser_manager], rbx
ctor_done:
    popfq
    jmp ctor_continue

sc_ipc_renderer_role:
    pushfq
    cmp r14, qword ptr [rip+renderer_manager]
    jne role_done
    mov eax, 1                    /* renderer, despite the browser command line */
role_done:
    mov dword ptr [r14+0xf0], eax  /* displaced role store */
    popfq
    jmp role_continue

.ifdef SCH296
.pushsection .text.global_loop, "ax"
.endif
sc_ipc_global_loop:
    cmp r14, qword ptr [rip+renderer_manager]
    je global_loop_done           /* browser already owns the global I/O loop */
    jmp helper_global_loop
global_loop_done:
    ret
.ifdef SCH296
.popsection
.pushsection .text.initial_connect, "ax"
.endif

sc_ipc_initial_connect:
    cmp rcx, qword ptr [rip+renderer_manager]
    je initial_connect_done       /* wait for the renderer's Channel Response */
    jmp manager_connect
initial_connect_done:
    ret
.ifdef SCH296
.popsection
.endif

/* Called from the destructor after the original handle-close code, with
 * RDI=this, RSI=0 and RCX=this->owned object. Destroy the renderer before
 * clearing the browser singleton, after the main path has called cef_shutdown.
 * The recursive renderer destructor clears only the renderer cache. */
.ifdef SCH296
/* 2.4.0.296: CloseHandle was the last call, and the code after the hook
 * reloads or tests everything it uses except RCX. The frame is aligned. */
sc_ipc_destroy:
    cmp rdi, qword ptr [rip+renderer_manager]
    je destroy_renderer
    cmp qword ptr [rip+renderer_manager], 0
    je destroy_store
    push rcx
    sub rsp, 0x28
    mov rcx, qword ptr [rip+renderer_manager]
    mov qword ptr [rsp+0x20], rcx
    call manager_dtor
    mov rcx, qword ptr [rsp+0x20]
    mov edx, 0x1a30
    call helper_delete
    add rsp, 0x28
    pop rcx
destroy_store:
    mov qword ptr [rip+browser_manager], rsi
    jmp dtor_continue
destroy_renderer:
    mov qword ptr [rip+renderer_manager], 0
    jmp dtor_continue
.else
sc_ipc_destroy:
    pushfq
    cmp rdi, qword ptr [rip+renderer_manager]
    je destroy_renderer
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 0x90                 /* original destructor frame is aligned */
    movdqu xmmword ptr [rsp+0x30], xmm0
    movdqu xmmword ptr [rsp+0x40], xmm1
    movdqu xmmword ptr [rsp+0x50], xmm2
    movdqu xmmword ptr [rsp+0x60], xmm3
    movdqu xmmword ptr [rsp+0x70], xmm4
    movdqu xmmword ptr [rsp+0x80], xmm5
    mov rcx, qword ptr [rip+renderer_manager]
    test rcx, rcx
    je destroy_restore
    mov qword ptr [rsp+0x20], rcx
    call manager_dtor
    mov rcx, qword ptr [rsp+0x20]
    mov edx, 0x1a30
    call helper_delete
destroy_restore:
    movdqu xmm0, xmmword ptr [rsp+0x30]
    movdqu xmm1, xmmword ptr [rsp+0x40]
    movdqu xmm2, xmmword ptr [rsp+0x50]
    movdqu xmm3, xmmword ptr [rsp+0x60]
    movdqu xmm4, xmmword ptr [rsp+0x70]
    movdqu xmm5, xmmword ptr [rsp+0x80]
    add rsp, 0x90
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    popfq
    mov qword ptr [rip+browser_manager], rsi
    jmp dtor_continue
destroy_renderer:
    mov qword ptr [rip+renderer_manager], 0
    popfq
    jmp dtor_continue
.endif
/* One helper function inlines the singleton load instead of calling its
 * getter. Route that lookup by the same CEF thread, preserving its live RAX. */
.ifdef SCH296
/* 2.4.0.296: the load follows a CALL and the code after it overwrites RAX,
 * RCX and the flags before reading them: CALL the getter like its callers. */
.pushsection .text.direct, "ax"
sc_ipc_direct_getter:
    call manager_getter
    mov rbx, rax
    jmp direct_continue
.popsection
.else
sc_ipc_direct_getter:
    pushfq
    push rax
    sub rsp, 0x20
    call manager_getter
    mov rbx, rax
    add rsp, 0x20
    pop rax
    popfq
    jmp direct_continue
created_message:
    .asciz "[sc-ipc] renderer manager=%p browser=%p init=%u"
.endif
