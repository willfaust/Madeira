#include <stdint.h>

#if defined(_WIN32) && defined(__x86_64__)
#define ENTRY __declspec(dllexport) __attribute__((naked)) uint64_t
ENTRY guest_workload(uint64_t seed)
{
    __asm__("pushfq\n popq %rax\n retq");
}
ENTRY context_round(uint64_t seed)
{
    __asm__("cvtsd2si %xmm0, %rax\n retq");
}
ENTRY context_add(uint64_t seed)
{
    __asm__("addsd %xmm1, %xmm0\n movq %xmm0, %rax\n retq");
}
ENTRY context_divide(uint64_t seed)
{
    __asm__("divsd %xmm1, %xmm0\n movq %xmm0, %rax\n retq");
}
ENTRY context_copy(uint64_t seed)
{
    __asm__("rep movsb\n retq");
}
ENTRY context_unaligned(uint64_t seed)
{
    __asm__("movzwl (%rcx), %r8d\n movw %r8w, (%rdx)\n movl (%rcx), %r9d\n movl %r9d, 4(%rdx)\n movq (%rcx), %rax\n movq %rax, 8(%rdx)\n retq");
}
ENTRY context_publish(uint64_t seed)
{
    __asm__("movq $1, %r8\n 1: cmpq $0, 8(%rcx)\n jne 1b\n movq %r8, (%rcx)\n movq $1, 8(%rcx)\n incq %r8\n cmpq %rdx, %r8\n jbe 1b\n xorl %eax, %eax\n retq");
}
ENTRY context_receive(uint64_t seed)
{
    __asm__("movq $1, %r8\n 1: cmpq $0, 8(%rcx)\n je 1b\n cmpq %r8, (%rcx)\n jne 2f\n movq $0, 8(%rcx)\n incq %r8\n cmpq %rdx, %r8\n jbe 1b\n xorl %eax, %eax\n retq\n 2: movq $1, %rax\n retq");
}
ENTRY context_resume(uint64_t seed)
{
    __asm__("addq $11, %rax\n retq");
}
ENTRY context_pause(uint64_t seed)
{
    __asm__("addq $7, %rax\n jmp context_resume");
}
ENTRY context_loop(uint64_t seed)
{
    __asm__("decq %rcx\n jnz context_loop\n retq");
}
ENTRY context_flags_resume(uint64_t seed)
{
    __asm__("pushfq\n popq %rax\n retq");
}
ENTRY context_flags_pause(uint64_t seed)
{
    __asm__("decq %rcx\n jmp context_flags_resume");
}
ENTRY context_thread(uint64_t seed)
{
    __asm__("movq %gs:0x30, %rax\n movq %gs:0x60, %rdx\n retq");
}
ENTRY context_cpuid(uint64_t seed)
{
    __asm__("cpuid\n retq");
}
ENTRY context_xcr(uint64_t seed)
{
    __asm__("xgetbv\n retq");
}
ENTRY context_illegal(uint64_t seed)
{
    __asm__("ud2\n retq");
}
ENTRY context_unbound(uint64_t seed)
{
    __asm__("fsin\n retq");
}
ENTRY context_syscall(uint64_t seed)
{
    __asm__("syscall\n retq");
}
ENTRY context_wait(uint64_t seed)
{
    __asm__("movq $1, 8(%rcx)\n 1: cmpq $0, (%rcx)\n je 1b\n retq");
}
#else
uint64_t guest_workload(uint64_t seed) { return seed; }
#endif
