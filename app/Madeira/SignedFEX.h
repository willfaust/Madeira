#ifndef MADEIRA_SIGNED_FEX_H
#define MADEIRA_SIGNED_FEX_H
#include <stdint.h>
#include <stdio.h>

struct MadeiraFEXEntry { uint64_t guest, offset; };
struct MadeiraFEXSection { uint64_t start, end; };
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
};

int madeira_signed_fex_run(const char *framework, const char *guest_image, FILE *report);
void madeira_signed_fex_if_requested(void);
#endif
