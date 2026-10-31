#ifndef MADEIRA_SIGNED_CODE_PROBE_H
#define MADEIRA_SIGNED_CODE_PROBE_H

#include <stdint.h>
#include <stdio.h>

struct MadeiraSignedProbeSlots {
    uint64_t bias;
    uint64_t (*callback)(uint64_t);
};

/* 0: loader contract passed, 1: failed, 2: signing/debugger state is inconclusive. */
int madeira_signed_code_probe_run(const char *path, FILE *report);
void madeira_signed_code_probe_if_requested(void);

#endif
