/* buf-bind-fast: the cached resolver must give the answer of the plain search, whatever is created or released.
 * The function under test is the real text of mad_resolve_bind (resolve_bind.inc), over a model of the address index:
 * the version moves by two on every index change, an index marked dirty takes changes without a version move and is
 * rebuilt (version moves) by the next search. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint64_t UINT64; typedef int64_t LONG64;
struct mad_resource { UINT64 gpu_address, size; void *placed_heap; void *buffer; unsigned seq; int live; };
struct mad_device { LONG64 aidx_ver; int aidx_dirty; };
struct mad_list { struct mad_device *device; struct { UINT64 lo, len; struct mad_resource *r; } bb_e[8]; LONG64 bb_ver; unsigned bb_next, bb_hits, bb_misses; };
#define NRES 96
static struct mad_resource g_res[NRES];
static unsigned g_seq;
static unsigned long long g_searches;
static int mad_buf_bind_fast_on(void) { return 1; }
static struct mad_resource *reference(UINT64 addr, UINT64 *off) {   /* newest live resource holding the address */
    struct mad_resource *found = NULL;
    if (!addr) return NULL;
    for (int i = 0; i < NRES; i++) {
        struct mad_resource *r = &g_res[i];
        if (r->live && r->gpu_address && addr >= r->gpu_address && addr < r->gpu_address + r->size && (!found || r->seq > found->seq)) found = r;
    }
    if (found && off) *off = addr - found->gpu_address;
    return found;
}
static struct mad_resource *mad_resolve_address(struct mad_device *d, UINT64 addr, UINT64 *off) {
    g_searches++;
    if (d->aidx_dirty) { d->aidx_dirty = 0; d->aidx_ver += 2; }   /* the locked path rebuilds the index */
    return reference(addr, off);
}
#include "resolve_bind.inc"
static uint64_t rng_state = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void) { rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17; return rng_state; }
int main(int argc, char **argv) {
    unsigned long long steps = argc > 1 ? strtoull(argv[1], NULL, 0) : 20000000ull, checks = 0, fails = 0, hits = 0;
    static struct mad_device d; static struct mad_list lists[3];
    static char heap_tag, buf_tag; unsigned churn = argc > 2 ? (unsigned)atoi(argv[2]) : 1;
    for (int i = 0; i < 3; i++) lists[i].device = &d;
    for (unsigned long long n = 0; n < steps; n++) {
        unsigned op = rnd() % 100;
        if (op < 6 && rnd() % churn == 0) {   /* create or release */
            unsigned ri = rnd() % 4 ? rnd() % NRES : rnd() % 6; struct mad_resource *r = &g_res[ri];
            if (r->live) { r->live = 0; if (!d.aidx_dirty) d.aidx_ver += 2; }
            else {
                int placed = ri >= 6 && rnd() % 3 == 0;
                memset(r, 0, sizeof *r);
                /* committed buffers: 24 slots of 0x10000 that never overlap each other, reused after a release;
                 * placed ones: anywhere inside two heaps, overlapping each other freely */
                if (placed) { r->gpu_address = 0x40000000ull + (rnd() % 2) * 0x1000000ull + (rnd() % 64) * 0x1000; r->size = 0x1000 * (1 + rnd() % 32); r->placed_heap = &heap_tag; }
                else {
                    unsigned slot = rnd() % 24; int clash = 0;
                    for (int i = 0; i < NRES; i++) if (g_res[i].live && !g_res[i].placed_heap && g_res[i].gpu_address == 0x10000000ull + slot * 0x10000ull) clash = 1;
                    if (clash) continue;
                    r->gpu_address = 0x10000000ull + slot * 0x10000ull; r->size = 0x100 * (1 + rnd() % 255);
                }
                r->buffer = ri < 6 || rnd() % 16 ? &buf_tag : NULL; r->seq = ++g_seq; r->live = 1;
                if (!d.aidx_dirty) d.aidx_ver += 2;
            }
        } else if (op < 7) { if (rnd() % churn == 0) d.aidx_dirty = 1;   /* a slow-path hit marks the index for a rebuild */
        } else if (op < 8) { if (rnd() % churn == 0) d.aidx_ver |= 1;    /* a writer is inside a change: readers must not trust or keep anything */
        } else {
            struct mad_list *l = &lists[rnd() % 3]; struct mad_resource *t = &g_res[rnd() % 10 ? rnd() % 6 : rnd() % NRES], *want, *got;
            UINT64 addr, wo = 0, go = 0;
            if (d.aidx_ver & 1) d.aidx_ver++;   /* the change ends before this thread's next lookup half the time */
            else if (rnd() % (64 * churn) == 0) d.aidx_ver |= 1;
            addr = rnd() % 8 == 0 ? rnd() % 0x60000000ull : t->gpu_address + (t->size ? rnd() % (t->size + 16) : 0);
            if (rnd() % 256 == 0) addr = 0;
            want = reference(addr, &wo);
            { unsigned h0 = l->bb_hits; got = mad_resolve_bind(l, addr, &go); hits += l->bb_hits - h0; }
            checks++;
            if (got != want || (want && go != wo)) { if (fails++ < 10) printf("FAIL step %llu addr %llx: got %p+%llx want %p+%llx (ver %lld dirty %d)\n", n, (unsigned long long)addr, (void *)got, (unsigned long long)go, (void *)want, (unsigned long long)wo, (long long)d.aidx_ver, d.aidx_dirty); }
            if ((d.aidx_ver & 1) && rnd() % 2) d.aidx_ver++;
        }
    }
    printf("%llu lookups, %llu from the kept buffers (%.1f%%), %llu searches, %llu wrong\n", checks, hits, 100.0 * hits / checks, g_searches, fails);
    return fails ? 1 : 0;
}
