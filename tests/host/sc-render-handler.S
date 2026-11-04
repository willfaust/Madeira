/* [sc-rph] browser CefApp::GetRenderProcessHandler replacement embedded in
 * virtual_ios.c (ios_sch_thunk, ios_sch296_thunk). check-sc-render-handler.py
 * links the symbols to each build's guarded helper RVAs and compares the bytes
 * with the production blob. RDX is the returned CefRefPtr; the renderer app
 * is built once with the helper's own operator new and constructor, and one
 * reference to it stays in the .data tail cache. */
.intel_syntax noprefix
.text
.global sc_render_handler
sc_render_handler:
    push rbx
    sub rsp, 0x30
    mov rbx, rdx
    mov rax, qword ptr [rip+cache]
    test rax, rax
    jnz have
    mov ecx, 0x60
    call helper_new
    test rax, rax
    jz none
    mov rcx, rax
    mov edx, 1                    /* most derived */
    call renderer_app_ctor
    mov qword ptr [rsp+0x20], rax
    mov rcx, qword ptr [rax+8]    /* AddRef through the virtual base */
    movsxd rcx, dword ptr [rcx+4]
    lea rcx, [rax+rcx+8]
    mov rdx, qword ptr [rcx]
    call qword ptr [rdx]
    mov rax, qword ptr [rsp+0x20]
    mov qword ptr [rip+cache], rax
have:
    mov rcx, rax
    mov rdx, rbx
    call get_handler              /* App::GetRenderProcessHandler: this+0x28 */
out:
    mov rax, rbx
    add rsp, 0x30
    pop rbx
    ret
none:
    mov qword ptr [rbx], 0
    jmp out
