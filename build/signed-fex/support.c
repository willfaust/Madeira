#include <stdint.h>
#include <string.h>
#include "SignedFEX.h"
#include "abi.h"
#include "image.h"

extern const unsigned char madeira_fex_code[], madeira_fex_code_end[], madeira_fex_frame[];
extern void madeira_fex_enter(void *, const void *);
extern void madeira_fex_direct(void), madeira_fex_indirect(void);
extern uint64_t guest_workload(uint64_t);
static const uint64_t empty_lookup[2] = {0, UINT64_MAX};

static void initialize(void *frame)
{
    memcpy(frame, madeira_fex_frame, FEX_FRAME_SIZE);
    unsigned char *bytes = frame;
    *(uint64_t *)(bytes + FEX_L1) = (uintptr_t)empty_lookup;
    *(uint64_t *)(bytes + FEX_L1MASK) = 0;
    *(uint64_t *)(bytes + FEX_LOOP) = (uintptr_t)madeira_fex_indirect;
    *(uint64_t *)(bytes + FEX_LINK) = (uintptr_t)madeira_fex_direct;
    for (unsigned i = 0; i < FEX_CONSTANT_COUNT; ++i)
        ((uint64_t *)(bytes + FEX_CONSTANT_PTRS))[i] = (uintptr_t)(bytes + FEX_CONSTANTS + i * 16);
}

__attribute__((visibility("default")))
const struct MadeiraFEXImage madeira_fex_image = {
    2, FEX_IMAGE_BASE, FEX_IMAGE_SIZE, FEX_IMAGE_ENTRY, FEX_FRAME_SIZE, FEX_GREGS, FEX_RIP,
    madeira_fex_code, madeira_fex_code_end, entries, sizeof(entries) / sizeof(entries[0]),
    sections, sizeof(sections) / sizeof(sections[0]), initialize, madeira_fex_enter, guest_workload,
    imports, FEX_IMPORT_COUNT
};
