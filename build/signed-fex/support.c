#include <stdint.h>
#include <stddef.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include "SignedFEX.h"
#include "abi.h"
#include "image.h"
#include "runtime.h"

extern const unsigned char madeira_fex_code[], madeira_fex_code_end[], madeira_fex_frame[];
extern const unsigned char madeira_fex_indexed[];
extern void madeira_fex_enter(void *, const void *);
extern void madeira_fex_direct(void), madeira_fex_indirect(void);
extern void madeira_ec_enter(void *, const void *, const void *), madeira_ec_return(void);
extern void madeira_ec_call(void), madeira_ec_check(void), madeira_ec_check_cfg(void);
extern void madeira_fex_unsupported(void), madeira_fex_guest_fault(void);
#if FEX_HAS_REFERENCE
extern uint64_t guest_workload(uint64_t);
#define REFERENCE guest_workload
#else
#define REFERENCE NULL
#endif
static const uint64_t empty_lookup[2] = {0, UINT64_MAX};
static _Thread_local void *thread_binding;
__attribute__((visibility("hidden")))
void *madeira_ec_thread_current(void) { return thread_binding; }
static void *thread_exchange(void *value) { void *old = thread_binding; thread_binding = value; return old; }
__attribute__((visibility("hidden"), noreturn))
void madeira_ec_thread_missing(void)
{
    fputs("FAIL: JIT-less callback on a thread without a runtime binding.\n", stderr);
    abort();
}
static __uint128_t cpuid(void *object, uint32_t function, uint32_t leaf)
{
    (void)object;
    for (unsigned i = 0; i < sizeof(cpu_profile) / sizeof(cpu_profile[0]); ++i) {
        const struct MadeiraFEXCPUID *row = cpu_profile + i;
        if (row->function == function && (row->leaf == UINT32_MAX || row->leaf == leaf))
            return ((__uint128_t)row->edx << 96) | ((__uint128_t)row->ecx << 64) | ((uint64_t)row->ebx << 32) | row->eax;
    }
    return 0;
}
static uint64_t xcr(void *object, uint32_t index) { (void)object; return index ? 0 : cpu_xcr0; }
__attribute__((visibility("hidden")))
int madeira_ec_native_target(const void *target)
{
    if ((uintptr_t)target % 4) return 0;
    vm_address_t address = (uintptr_t)target;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    return result == KERN_SUCCESS && address <= (uintptr_t)target && (uintptr_t)target - address <= size &&
        size - ((uintptr_t)target - address) >= 4 &&
        (info.protection & (VM_PROT_READ | VM_PROT_EXECUTE | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_EXECUTE);
}
_Static_assert(sizeof(struct MadeiraFEXContext) == 1232 &&
    offsetof(struct MadeiraFEXContext, gregs) == 0x78 &&
    offsetof(struct MadeiraFEXContext, floating) == 0x100, "Wine x64 context layout");

static void initialize(void *frame)
{
    memcpy(frame, madeira_fex_frame, FEX_FRAME_SIZE);
    unsigned char *bytes = frame;
    memset(bytes + FEX_FRAME_SIZE, 0, 48);
    uint64_t base = FEX_IMAGE_BASE;
    memcpy(bytes + FEX_FRAME_SIZE + 24, &base, 8);
    for (unsigned i = 0; i < sizeof(unsupported_helpers) / sizeof(unsupported_helpers[0]); ++i)
        *(uintptr_t *)(bytes + unsupported_helpers[i]) = (uintptr_t)madeira_fex_unsupported;
    *(uintptr_t *)(bytes + FEX_CPUID) = (uintptr_t)cpuid;
    *(uintptr_t *)(bytes + FEX_XCR) = (uintptr_t)xcr;
    *(uintptr_t *)(bytes + FEX_SIGILL) = (uintptr_t)madeira_fex_guest_fault;
    *(uintptr_t *)(bytes + FEX_SIGTRAP) = (uintptr_t)madeira_fex_guest_fault;
    *(uintptr_t *)(bytes + FEX_SIGSEGV) = (uintptr_t)madeira_fex_guest_fault;
    *(uint64_t *)(bytes + FEX_L1) = (uintptr_t)empty_lookup;
    *(uint64_t *)(bytes + FEX_L1MASK) = 0;
    *(uint64_t *)(bytes + FEX_LOOP) = (uintptr_t)madeira_fex_indirect;
    *(uint64_t *)(bytes + FEX_LINK) = (uintptr_t)madeira_fex_direct;
    *(uintptr_t *)(bytes + FEX_GDT_PTRS) = (uintptr_t)(bytes + FEX_GDT);
    *(uintptr_t *)(bytes + FEX_GDT_PTRS + 8) = (uintptr_t)(bytes + FEX_GDT);
    for (unsigned i = 0; i < FEX_CONSTANT_COUNT; ++i)
        ((uint64_t *)(bytes + FEX_CONSTANT_PTRS))[i] = (uintptr_t)(bytes + FEX_CONSTANTS + i * 16);
    for (unsigned i = 0; i < sizeof(indexed_offsets) / sizeof(indexed_offsets[0]); ++i)
        ((uintptr_t *)(bytes + FEX_INDEXED_PTRS))[i] = (uintptr_t)(madeira_fex_indexed + indexed_offsets[i]);
}

static uint32_t fpsr_from_mxcsr(uint32_t value)
{
    return (value & 1) | ((value & 0x3c) >> 1) | ((value & 2) << 6);
}

static int load_context(void *frame, const struct MadeiraFEXContext *context, uint64_t teb)
{
    if ((context->flags & 0x10000b) != 0x10000b || (context->flags & 0x70) ||
        (context->mxcsr & ~0xffffu) || (context->mxcsr & 0x1fc0) != 0x1f80 ||
        (context->eflags & 0x23100)) return -1;
    unsigned char *bytes = frame, *flags = bytes + FEX_FLAGS;
    memcpy(bytes + FEX_GREGS, context->gregs, 128);
    memcpy(bytes + FEX_RIP, &context->rip, 8);
    memcpy(bytes + FEX_GS, &teb, 8);
    uint64_t zero = 0;
    memcpy(bytes + FEX_FS, &zero, 8);
    for (unsigned i = 0; i < 24; ++i) flags[i] = (context->eflags >> i) & 1;
    flags[1] = flags[9] = 1;
    flags[10] = context->eflags & (1u << 10) ? 0xff : 1;
    uint32_t pf = context->eflags & 4 ? 0 : 1, af = context->eflags & 16;
    uint32_t nzcv = ((context->eflags & 0x80u) << 24) | ((context->eflags & 0x40u) << 24) |
                    ((context->eflags & 1u) ? 0 : 1u << 29) | ((context->eflags & 0x800u) << 17);
    memcpy(bytes + FEX_PF, &pf, 4); memcpy(bytes + FEX_AF, &af, 4);
    memcpy(bytes + FEX_NZCV, &nzcv, 4);
    memcpy(bytes + FEX_SEGMENTS + 2, &context->cs, 2);
    memcpy(bytes + FEX_SEGMENTS + 4, &context->ss, 2);
    if (context->flags & 4) {
        memcpy(bytes + FEX_SEGMENTS, &context->es, 2);
        memcpy(bytes + FEX_SEGMENTS + 6, &context->ds, 2);
        memcpy(bytes + FEX_SEGMENTS + 8, &context->gs, 2);
        memcpy(bytes + FEX_SEGMENTS + 10, &context->fs, 2);
    }
    memcpy(bytes + FEX_MXCSR, &context->mxcsr, 4);
    uint32_t fpsr = fpsr_from_mxcsr(context->mxcsr);
    memcpy(bytes + FEX_FRAME_SIZE + 16, &fpsr, 4);
    memcpy(bytes + FEX_XMM, context->floating + 160, 256);
    memcpy(bytes + FEX_MM, context->floating + 32, 128);
    memcpy(bytes + FEX_FCW, context->floating, 2);
    memcpy(bytes + FEX_FTW, context->floating + 4, 1);
    uint16_t fsw; memcpy(&fsw, context->floating + 2, 2);
    for (unsigned i = 0; i < 16; ++i) flags[32 + i] = (fsw >> i) & 1;
    flags[43] = (fsw >> 11) & 7;
    return 0;
}

static void store_context(const void *frame, struct MadeiraFEXContext *context)
{
    const unsigned char *bytes = frame, *flags = bytes + FEX_FLAGS;
    memcpy(context->gregs, bytes + FEX_GREGS, 128);
    memcpy(&context->rip, bytes + FEX_RIP, 8);
    uint32_t nzcv, pf, af;
    memcpy(&nzcv, bytes + FEX_NZCV, 4); memcpy(&pf, bytes + FEX_PF, 4); memcpy(&af, bytes + FEX_AF, 4);
    uint32_t value = 0;
    for (unsigned i = 0; i < 24; ++i) if (i != 0 && i != 2 && i != 4 && i != 6 && i != 7 && i != 10 && i != 11)
        value |= (uint32_t)(flags[i] & 1) << i;
    value |= ((nzcv >> 31) & 1) << 7 | ((nzcv >> 30) & 1) << 6 |
             (((nzcv >> 29) & 1) ^ 1) | ((nzcv >> 28) & 1) << 11;
    value |= (__builtin_popcount((pf & 255) ^ 1) & 1) << 2;
    value |= (af ^ pf) & 16;
    value |= (flags[10] & 0x80) ? 1u << 10 : 0;
    context->eflags = value;
    uint16_t segments[6]; memcpy(segments, bytes + FEX_SEGMENTS, sizeof(segments));
    context->cs = segments[1]; context->ss = segments[2];
    if (context->flags & 4) {
        context->es = segments[0]; context->ds = segments[3]; context->gs = segments[4]; context->fs = segments[5];
    }
    memcpy(&context->mxcsr, bytes + FEX_MXCSR, 4);
    uint32_t fpsr; memcpy(&fpsr, bytes + FEX_FRAME_SIZE + 16, 4);
    context->mxcsr = (context->mxcsr & ~63u) | (fpsr & 1) | ((fpsr & 0x1e) << 1) | ((fpsr >> 6) & 2);
    memcpy(context->floating + 24, &context->mxcsr, 4);
    memcpy(context->floating + 160, bytes + FEX_XMM, 256);
    memcpy(context->floating + 32, bytes + FEX_MM, 128);
    memcpy(context->floating, bytes + FEX_FCW, 2);
    memcpy(context->floating + 4, bytes + FEX_FTW, 1);
    uint16_t fsw = 0;
    for (unsigned i = 0; i < 16; ++i) if (i < 11 || i > 13) fsw |= (flags[32 + i] & 1) << i;
    fsw |= (flags[43] & 7) << 11;
    memcpy(context->floating + 2, &fsw, 2);
}

__attribute__((visibility("default")))
const struct MadeiraFEXImage madeira_fex_image = {
    4, FEX_IMAGE_BASE, FEX_IMAGE_SIZE, FEX_IMAGE_ENTRY, FEX_FRAME_SIZE + 48, FEX_GREGS, FEX_RIP,
    madeira_fex_code, madeira_fex_code_end, entries, sizeof(entries) / sizeof(entries[0]),
    sections, sizeof(sections) / sizeof(sections[0]), initialize, madeira_fex_enter, REFERENCE,
    imports, FEX_IMPORT_COUNT, madeira_ec_enter, madeira_ec_return, FEX_GS,
    FEX_XMM, FEX_FRAME_SIZE, madeira_ec_call, madeira_ec_check, madeira_ec_check_cfg,
    load_context, store_context, guest_code_hash, FEX_FRAME_SIZE + 24, FEX_FRAME_SIZE + 32, abi_hash,
    FEX_FAULT, cpu_profile, sizeof(cpu_profile) / sizeof(cpu_profile[0]), cpu_xcr0,
    madeira_ec_thread_current, thread_exchange
};
