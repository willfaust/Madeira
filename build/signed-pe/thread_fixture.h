/* Standalone ABI tests only. This does not initialize a Wine process. */
#ifndef MADEIRA_WINE_THREAD_FIXTURE_H
#define MADEIRA_WINE_THREAD_FIXTURE_H
#include <pthread.h>
#include <stdint.h>
#include <string.h>
static pthread_once_t fixture_once = PTHREAD_ONCE_INIT;
static pthread_key_t fixture_key;
static int fixture_error;
static unsigned fixture_offset;
static unsigned char fixture_peb[65536];
static _Thread_local unsigned char fixture_teb[16384];
static void fixture_init(void)
{
    fixture_error = pthread_key_create(&fixture_key, NULL);
    unsigned token = 0;
    if (fixture_error || pthread_setspecific(fixture_key, &token)) { fixture_error = 1; return; }
    uintptr_t tsd;
    __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd));
    tsd &= ~(uintptr_t)7;
    unsigned found = 0;
    for (unsigned i = 1; i < 512; ++i) if (((void **)tsd)[i] == &token) { fixture_offset = i * 8; ++found; }
    if (pthread_setspecific(fixture_key, NULL) || found != 1) fixture_error = 1;
}

static int standalone_thread(struct madeira_signed_pe *module, FILE *report, uintptr_t *teb)
{
    /* shortcut: this is the standalone ABI workload's TEB/PEB fixture; process startup must use Wine's real context. */
    pthread_once(&fixture_once, fixture_init);
    if (fixture_error || pthread_setspecific(fixture_key, fixture_teb)) return -1;
    void *self = fixture_teb, *peb = fixture_peb;
    memcpy(fixture_teb + 0x30, &self, 8);
    memcpy(fixture_teb + 0x60, &peb, 8);
    if (madeira_pe_thread_offset(module, fixture_offset)) return -1;
    fprintf(report, "thread-context=standalone-TEB/PEB-test-fixture offset=%u; no Wine process startup.\n", fixture_offset);
    *teb = (uintptr_t)fixture_teb;
    return 0;
}

#endif
