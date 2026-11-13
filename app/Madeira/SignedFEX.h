#ifndef MADEIRA_SIGNED_FEX_H
#define MADEIRA_SIGNED_FEX_H
#include <stdint.h>
#include <stdio.h>

/* Binary-compatible with Wine's AMD64_CONTEXT and ARM64EC_NT_CONTEXT. */
struct MadeiraFEXContext {
    uint64_t home[6];
    uint32_t flags, mxcsr;
    uint16_t cs, ds, es, fs, gs, ss;
    uint32_t eflags;
    uint64_t debug[6], gregs[16], rip;
    unsigned char floating[512], extended[464];
} __attribute__((aligned(16)));

struct MadeiraFEXEntry { uint64_t guest, offset; };
struct MadeiraFEXSection { uint64_t start, end; };
struct MadeiraFEXImport { const char *dll, *name; uint64_t iat; };
struct MadeiraFEXCPUID { uint32_t function, leaf, eax, ebx, ecx, edx; };
typedef int (*MadeiraFEXImportCall)(void *, const struct MadeiraFEXImport *, uint64_t *);
struct MadeiraFEXImage;
struct MadeiraFEXNativeImport { const void *target, *thunk; };
typedef int (*MadeiraFEXImportResolve)(void *, const struct MadeiraFEXImport *,
                                     const struct MadeiraFEXImage *, struct MadeiraFEXNativeImport *);
struct MadeiraFEXImage {
    uint64_t version, base, image_size, entry, frame_size, gregs_offset, rip_offset;
    const unsigned char *code, *code_end;
    const struct MadeiraFEXEntry *entries;
    uint64_t entry_count;
    const struct MadeiraFEXSection *sections;
    uint64_t section_count;
    void (*initialize)(void *);
    void (*enter)(void *, const void *);
    uint64_t (*reference)(uint64_t);
    const struct MadeiraFEXImport *imports;
    uint64_t import_count;
    void (*enter_ec)(void *, const void *, const void *);
    void (*return_ec)(void);
    uint64_t gs_offset;
    uint64_t xmm_offset, callback_offset;
    void (*call_ec)(void), (*check_ec)(void), (*check_ec_cfg)(void);
    int (*load_context)(void *, const struct MadeiraFEXContext *, uint64_t);
    void (*store_context)(const void *, struct MadeiraFEXContext *);
    const unsigned char *guest_code_hash;
    uint64_t base_offset;
    uint64_t ranges_offset;
    const unsigned char *abi_hash;
    uint64_t fault_offset;
    const struct MadeiraFEXCPUID *cpu;
    uint64_t cpu_count, xcr0;
    void *(*thread_current)(void);
    void *(*thread_exchange)(void *);
};

struct MadeiraFEXRuntime;
struct MadeiraFEXRuntime *madeira_signed_fex_open(const char *framework, void *mapped_image, size_t size,
    MadeiraFEXImportResolve resolve, void *context, FILE *report);
/* The resolver returns 0 for a native binding, 1 for a guest binding, or -1 on failure. */
int madeira_signed_fex_add(struct MadeiraFEXRuntime *runtime, const char *framework, void *mapped_image, size_t size,
    MadeiraFEXImportResolve resolve, void *context, FILE *report);
int madeira_signed_fex_close(struct MadeiraFEXRuntime *runtime);
/* The fault callback must stop the failing Windows thread and must not return. */
int madeira_signed_fex_bind_thread(struct MadeiraFEXRuntime *runtime, uint64_t teb, void *stack, size_t stack_size,
    void (*fault)(void *, const struct MadeiraFEXContext *), void *fault_context, FILE *report);
int madeira_signed_fex_unbind_thread(struct MadeiraFEXRuntime *runtime);
/* 0: reached stop_rip; 1: yielded at a block boundary; -1: refused execution. */
int madeira_signed_fex_execute(struct MadeiraFEXRuntime *runtime, struct MadeiraFEXContext *context,
    uint64_t teb, void *stack, size_t stack_size, uint64_t stop_rip, uint64_t budget, FILE *report);

int madeira_signed_fex_run(const char *framework, const char *guest_image, FILE *report);
int madeira_signed_fex_run_with_imports(const char *framework, const char *guest_image, FILE *report,
                                      MadeiraFEXImportCall call, void *context);
int madeira_signed_fex_run_native(const char *framework, const char *guest_image, FILE *report,
                                 MadeiraFEXImportResolve resolve, void *context, uint64_t teb);
void madeira_signed_fex_if_requested(void);
#endif
