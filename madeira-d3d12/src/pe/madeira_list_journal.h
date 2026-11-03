/* madeira-d3d12 list-journal: shared between the ARM64EC runtime and its x64 part.
 *
 * Every ID3D12GraphicsCommandList method an x64 game calls is a crossing from
 * emulated x64 code into ARM64EC code. Path of Exile 2 records about ten of them
 * per draw, about a million a second, and the crossing costs more than the
 * recording itself. With madeira.cfg list-journal = 1 the hot recording methods
 * are x64 code inside this DLL (madeira_list_journal.x64.c): they append the
 * call and its arguments to a per-list journal, and the ARM64EC runtime replays
 * the journal through the same list_* functions as before when the list is
 * closed, when the journal is full, or before any method that is not journaled
 * (madeira_list_journal.x64.S sends every other slot through a check first). The
 * methods see the same calls in the same order; only their timing moves to the
 * flush. Methods that read CPU descriptors or other memory the game may change
 * right after the call (OMSetRenderTargets, the Clear* methods, ...) are not
 * journaled, and static-cbv (which reads descriptor tables while recording)
 * turns the journal off.
 *
 * THE X64 CODE NEVER ADDRESSES THIS DLL'S GLOBALS. Madeira runs a hybrid DLL's
 * ARM64EC code from a copy of the whole image in its JIT pool, .data included,
 * while x64 code always runs at the PE address (FEX's [pool-rip-fix]): a
 * RIP-relative load from x64 code reads the PE's .data, a stale copy the
 * ARM64EC code never writes. So each vtable carries a pointer just before its
 * first slot (jr_ctx, set by the ARM64EC side and so pointing into the copy it
 * uses), and the x64 code reaches its state through the object: [rcx] is the
 * vtable, [vtable - 8] the struct mad_jr_ctx. The build checks that the x64
 * objects reference no data symbol.
 *
 * Also included by the .S file: only preprocessor definitions outside the
 * __ASSEMBLER__ guard. */
#ifndef MADEIRA_LIST_JOURNAL_H
#define MADEIRA_LIST_JOURNAL_H

/* struct mad_list keeps the journal right after the mad_obj prefix (vtbl, refs,
 * iid, name); madeira_d3d12.c asserts both offsets. */
#define MAD_JR_OFFSET       32
#define MAD_JR_USED_OFFSET  (MAD_JR_OFFSET + 8)
/* struct mad_resource: gpu_address, and GetGPUVirtualAddress's ID3D12Resource slot. */
#define MAD_RES_GPU_ADDRESS_OFFSET 0x70
#define MAD_RES_GVA_SLOT    11

/* struct mad_jr_ctx: slots per interface (List7's 81 plus List8's one is the most),
 * and the byte offsets the trampolines use. */
#define MAD_JR_SLOTS        96
#define MAD_JR_CTX_CALLS    (8 * MAD_JR_SLOTS)
#define MAD_JR_CTX_FLUSH    (MAD_JR_CTX_CALLS + 4 * MAD_JR_SLOTS)
#define MAD_JR_CTX_CENSUS   (MAD_JR_CTX_FLUSH + 8)

#ifndef __ASSEMBLER__
#include <stdint.h>

/* One per interface whose slots go through trampolines, in ARM64EC .data. */
struct mad_jr_ctx {
    void *target[MAD_JR_SLOTS];        /* the ARM64EC method behind each slot */
    uint32_t calls[MAD_JR_SLOTS];      /* api-census: calls per slot (plain increments, approximate) */
    void (*flush)(void *list);         /* list only: replays a list's journal */
    uint8_t census;                    /* api-census on */
};

struct mad_journal {
    uint8_t *buf;          /* records, 8-byte aligned; allocated by the first flush */
    uint32_t used, cap;    /* bytes */
};

/* One record: a head, then the payload; size covers both, a multiple of 8. */
struct mad_jr_head {
    uint16_t op;
    uint16_t size;
    uint32_t a;            /* the first small argument of the call */
};

enum mad_jr_op {
    JR_PSO = 1, JR_ROOTSIG, JR_CROOTSIG,
    JR_ROOT_CBV, JR_ROOT_SRV, JR_ROOT_UAV, JR_ROOT_TABLE,
    JR_CROOT_CBV, JR_CROOT_SRV, JR_CROOT_UAV, JR_CROOT_TABLE,
    JR_ROOT_CONST, JR_ROOT_CONSTS, JR_CROOT_CONST, JR_CROOT_CONSTS,
    JR_TOPOLOGY, JR_IB, JR_IB_NULL, JR_VBS, JR_VIEWPORTS, JR_SCISSORS,
    JR_STENCIL_REF, JR_BLEND_FACTOR,
    JR_DRAW, JR_DRAW_INDEXED, JR_DISPATCH, JR_BARRIERS, JR_HEAPS,
    JR_OP_COUNT
};

/* Limits above which a call is not journaled (the journal is flushed and the
 * ARM64EC method called directly, as without the journal). */
#define MAD_JR_MAX_CONSTS     64
#define MAD_JR_MAX_VIEWS      32
#define MAD_JR_MAX_RECTS      16
#define MAD_JR_MAX_BARRIERS   32
#define MAD_JR_MAX_HEAPS      4
#define MAD_JR_BYTES          (64 * 1024)

/* The x64 methods, by List7 vtable slot (madeira_list_journal.x64.c). */
struct mad_jr_method {
    uint32_t slot;
    void *fn;
};

/* Defined by the x64 code, read by the ARM64EC side (never the other way). */
extern const struct mad_jr_method mad_jr_x64_methods[];
extern void *const mad_jr_list_tramps[MAD_JR_SLOTS];
extern void *const mad_jr_count_tramps[MAD_JR_SLOTS];
extern char mad_res_gva_x64[];
#endif

#endif /* MADEIRA_LIST_JOURNAL_H */
