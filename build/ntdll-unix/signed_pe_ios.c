/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "signed_pe_ios.h"
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_POINTER_LOCK_FREE == 2,
               "Signed PE fault lookups require lock-free atomics");

struct identity {
    uint32_t magic, version, image_size, section_count;
    uint64_t original_base;
    uint32_t data_rva, machine;
    unsigned char source_hash[32], code_hash[32];
    uint32_t fixup_count, reserved;
    uint32_t fixups[];
};
struct madeira_signed_pe {
    void *library;
    unsigned char *image;
    const struct identity *identity;
    size_t optional, sections;
    FILE *report;
    struct thread_state *thread;
    const unsigned char *trampolines;
};
struct thread_state {
    uint32_t version;
    atomic_uint offset;
    uint64_t size;
    uint32_t teb_sites, tsd_sites;
    unsigned char code_hash[32], trampoline_hash[32];
};
_Static_assert(sizeof(struct thread_state) == 88 && offsetof(struct thread_state, offset) == 4,
               "Signed thread-state data must match the offline wrapper layout");
static uint16_t u16(const void *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t u32(const void *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t u64(const void *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static int inside(size_t off, size_t len, size_t size) { return off <= size && len <= size - off; }

static int protection(const void *pointer, size_t length, int required, int forbidden)
{
    uintptr_t cursor = (uintptr_t)pointer, end = cursor + length;
    if (end < cursor) return 0;
    while (cursor < end) {
        vm_address_t address = cursor;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object) mach_port_deallocate(mach_task_self(), object);
        if (status != KERN_SUCCESS || address > cursor || !size || size > UINTPTR_MAX - address ||
            (info.protection & required) != required || (info.protection & forbidden)) return 0;
        cursor = address + size;
    }
    return 1;
}

static int headers(const unsigned char *image, size_t size, size_t *optional, size_t *sections)
{
    if (!inside(0, 64, size) || u16(image) != 0x5a4d) return 0;
    size_t nt = u32(image + 60);
    if (!inside(nt, 264, size) || u32(image + nt) != 0x4550 || u16(image + nt + 24) != 0x20b) return 0;
    unsigned count = u16(image + nt + 6), length = u16(image + nt + 20);
    if (!count || count > 96 || length < 240 || u32(image + nt + 24 + 56) != size) return 0;
    *optional = nt + 24;
    *sections = *optional + length;
    return inside(*sections, count * 40, size);
}

static int code_hash(const unsigned char *image, size_t size, unsigned char hash[32])
{
    size_t optional, sections;
    if (!headers(image, size, &optional, &sections)) return 0;
    CC_SHA256_CTX state;
    CC_SHA256_Init(&state);
    uint32_t machine = u16(image + optional - 20), image_size = (uint32_t)size;
    CC_SHA256_Update(&state, &machine, 4);
    CC_SHA256_Update(&state, &image_size, 4);
    for (unsigned i = 0; i < u16(image + optional - 18); ++i) {
        const unsigned char *section = image + sections + i * 40;
        uint32_t start = u32(section + 12), length = u32(section + 8), raw = u32(section + 16);
        uint32_t flags = u32(section + 36);
        if (raw > length) length = raw;
        if (!inside(start, length, size)) return 0;
        if (!(flags & 0x20000000)) continue;
        uint32_t end = start + length;
        CC_SHA256_Update(&state, &start, 4); CC_SHA256_Update(&state, &end, 4);
        CC_SHA256_Update(&state, &flags, 4); CC_SHA256_Update(&state, image + start, length);
    }
    CC_SHA256_Final(hash, &state);
    return 1;
}

int madeira_pe_check(struct madeira_signed_pe *m)
{
    unsigned char hash[32];
    if (!m || !code_hash(m->image, m->identity->image_size, hash) ||
        memcmp(hash, m->thread ? m->thread->code_hash : m->identity->code_hash, 32)) return -1;
    if (m->thread) {
        if (!m->trampolines || !m->thread->size || m->thread->size > 16 * 1024 * 1024 ||
            !protection(m->trampolines, m->thread->size, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE)) return -1;
        CC_SHA256(m->trampolines, (CC_LONG)m->thread->size, hash);
        if (memcmp(hash, m->thread->trampoline_hash, 32)) return -1;
    }
    for (unsigned i = 0; i < m->identity->section_count; ++i) {
        const unsigned char *s = m->image + m->sections + i * 40;
        size_t start = u32(s + 12), length = u32(s + 8), raw = u32(s + 16);
        if (raw > length) length = raw;
        if (!length) continue;
        int exec = !!(u32(s + 36) & 0x20000000);
        if (!protection(m->image + start, length, VM_PROT_READ | (exec ? VM_PROT_EXECUTE : VM_PROT_WRITE),
                        exec ? VM_PROT_WRITE : VM_PROT_EXECUTE)) return -1;
    }
    return 0;
}

struct madeira_signed_pe *madeira_pe_open(const char *framework, FILE *report)
{
    if (!framework) return NULL;
    void *library = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
    if (!library) { if (report) fprintf(report, "signed-pe: %s\n", dlerror()); return NULL; }
    struct madeira_signed_pe *m = calloc(1, sizeof(*m));
    if (!m) { dlclose(library); return NULL; }
    m->library = library; m->report = report;
    m->image = dlsym(library, "madeira_pe_image");
    m->identity = dlsym(library, "madeira_pe_identity");
    m->thread = dlsym(library, "madeira_pe_thread_state");
    m->trampolines = dlsym(library, "madeira_pe_trampolines");
    const struct identity *id = m->identity;
    if (!id || !m->image || !protection(id, sizeof(*id), VM_PROT_READ, VM_PROT_EXECUTE) ||
        id->magic != 0x4550504d || (id->version != 1 && id->version != 2) || !id->image_size || id->image_size > 128 * 1024 * 1024 ||
        (id->version == 2 && (!m->thread || !protection(m->thread, sizeof(*m->thread),
             VM_PROT_READ | VM_PROT_WRITE, VM_PROT_EXECUTE) || m->thread->version != 1)) ||
        (id->version == 1 && m->thread) ||
        id->data_rva >= id->image_size || id->fixup_count > id->image_size / 8 ||
        !protection(id, sizeof(*id) + (size_t)id->fixup_count * 4, VM_PROT_READ, VM_PROT_EXECUTE) ||
        !protection(m->image, id->image_size, VM_PROT_READ, 0) ||
        !headers(m->image, id->image_size, &m->optional, &m->sections) ||
        id->section_count != u16(m->image + m->optional - 18) || madeira_pe_check(m)) goto fail;
    for (unsigned i = 0; i < id->fixup_count; ++i)
        if (id->fixups[i] < id->data_rva || !inside(id->fixups[i], 8, id->image_size) ||
            (i && id->fixups[i - 1] >= id->fixups[i])) goto fail;
    if (report) fprintf(report, "signed-pe: image=%p size=%u data-fixups=%u native-text=RX data=RW/NX\n",
                        m->image, id->image_size, id->fixup_count);
    if (report && m->thread) fprintf(report, "signed-pe: offline-TEB-rewrites=%u offline-TSD-rewrites=%u signed-trampolines=%llu\n",
        m->thread->teb_sites, m->thread->tsd_sites, (unsigned long long)m->thread->size);
    return m;
fail:
    if (report) fprintf(report, "signed-pe: invalid image or changed executable bytes\n");
    madeira_pe_close(m);
    return NULL;
}

void madeira_pe_close(struct madeira_signed_pe *m)
{
    if (!m) return;
    dlclose(m->library);
    free(m);
}
void *madeira_pe_image(struct madeira_signed_pe *m) { return m ? m->image : NULL; }

int madeira_pe_thread_offset(struct madeira_signed_pe *m, unsigned offset)
{
    if (!m || !m->thread || !offset || offset >= 4096 || offset % 8) return -1;
    unsigned old = 0;
    return atomic_compare_exchange_strong(&m->thread->offset, &old, offset) || old == offset ? 0 : -1;
}

static const void *data(struct madeira_signed_pe *m, size_t offset, size_t length)
{
    return inside(offset, length, m->identity->image_size) ? m->image + offset : NULL;
}
static const char *string(struct madeira_signed_pe *m, size_t offset)
{
    const char *p = data(m, offset, 1);
    return p && memchr(p, 0, m->identity->image_size - offset) ? p : NULL;
}
static int directory(struct madeira_signed_pe *m, unsigned index, uint32_t *rva, uint32_t *size)
{
    *rva = u32(m->image + m->optional + 112 + index * 8);
    *size = u32(m->image + m->optional + 116 + index * 8);
    return *size && data(m, *rva, *size);
}

void *madeira_pe_export(struct madeira_signed_pe *m, const char *name, uint16_t ordinal)
{
    uint32_t exports, length;
    if (!m || !directory(m, 0, &exports, &length) || length < 40) return NULL;
    const unsigned char *e = m->image + exports;
    uint32_t functions = u32(e + 20), names = u32(e + 24), index = UINT32_MAX;
    const unsigned char *table = data(m, u32(e + 28), (size_t)functions * 4);
    const unsigned char *name_table = data(m, u32(e + 32), (size_t)names * 4);
    const unsigned char *ordinals = data(m, u32(e + 36), (size_t)names * 2);
    if (!table || !name_table || !ordinals) return NULL;
    if (!name) {
        if (ordinal < u32(e + 16)) return NULL;
        index = ordinal - u32(e + 16);
    } else for (uint32_t i = 0; i < names; ++i) {
        const char *candidate = string(m, u32(name_table + 4 * i));
        if (!candidate) return NULL;
        if (!strcmp(candidate, name)) { index = u16(ordinals + 2 * i); break; }
    }
    if (index >= functions) return NULL;
    uint32_t rva = u32(table + 4 * index);
    if (!rva || (rva >= exports && rva - exports < length)) return NULL;
    if (m->identity->machine == 0x8664) {
        uint32_t config, config_size;
        if (!directory(m, 10, &config, &config_size) || config_size < 208) return NULL;
        uintptr_t metadata = u64(m->image + config + 200), base = (uintptr_t)m->image;
        if (metadata < base || !data(m, metadata - base, 80)) return NULL;
        const unsigned char *meta = (const void *)metadata;
        uint32_t count = u32(meta + 52);
        const unsigned char *redirects = data(m, u32(meta + 16), (size_t)count * 8);
        if (!redirects) return NULL;
        for (uint32_t i = 0; i < count; ++i)
            if (u32(redirects + i * 8) == rva) { rva = u32(redirects + i * 8 + 4); break; }
        count = u32(meta + 8);
        const unsigned char *map = data(m, u32(meta + 4), (size_t)count * 8);
        int native = 0;
        if (!map) return NULL;
        for (uint32_t i = 0; i < count; ++i) {
            uint32_t start = u32(map + i * 8), length = u32(map + i * 8 + 4);
            if ((start & 3) == 1 && rva >= (start & ~3u) && rva - (start & ~3u) < length) native = 1;
        }
        if (!native) return NULL;
    }
    void *target = (void *)data(m, rva, 4);
    return target && protection(target, 4, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE) ? target : NULL;
}

int madeira_pe_bind(struct madeira_signed_pe *m, madeira_pe_resolver resolver, void *context)
{
    uint32_t imports, size, delay, delay_size;
    if (!m || !resolver || directory(m, 13, &delay, &delay_size)) return -1;
    if (!directory(m, 1, &imports, &size)) return 0;
    for (size_t descriptor = imports; inside(descriptor - imports, 20, size); descriptor += 20) {
        const unsigned char *d = m->image + descriptor;
        uint32_t lookup = u32(d), dll_rva = u32(d + 12), iat = u32(d + 16);
        if (!lookup && !dll_rva && !iat) return madeira_pe_check(m);
        const char *dll = string(m, dll_rva);
        if (!dll || !iat) return -1;
        if (!lookup) lookup = iat;
        for (size_t i = 0;; ++i) {
            const void *slot = data(m, (size_t)lookup + i * 8, 8);
            void *destination = (void *)data(m, (size_t)iat + i * 8, 8);
            if (!slot || !destination || !protection(destination, 8, VM_PROT_WRITE, VM_PROT_EXECUTE)) return -1;
            uint64_t thunk = u64(slot);
            if (!thunk) break;
            const char *name = thunk >> 63 ? NULL : string(m, thunk + 2);
            if (!(thunk >> 63) && !name) return -1;
            void *target = resolver(context, dll, name, (uint16_t)thunk);
            if (!target) { if (m->report) fprintf(m->report, "signed-pe: unresolved %s!%s\n", dll, name ? name : "ordinal"); return -1; }
            memcpy(destination, &target, 8);
        }
    }
    return -1;
}

int madeira_pe_ec_helpers(struct madeira_signed_pe *m, void (*return_dispatch)(void),
                          void (*call_dispatch)(void), void (*check_call)(void), void (*check_cfg)(void))
{
    uint32_t config, length;
    if (!m || m->identity->machine != 0x8664 || !directory(m, 10, &config, &length) || length < 208) return -1;
    uintptr_t metadata = u64(m->image + config + 200), base = (uintptr_t)m->image;
    if (metadata < base || !data(m, metadata - base, 80)) return -1;
    /* Wine's LLVM indirect call sites pass their target in x11, including non-CFG calls. */
    void (*functions[])(void) = {call_dispatch, return_dispatch, check_call, check_cfg, check_cfg};
    void *slots[5] = {0};
    for (unsigned i = 0; i < 5; ++i) if (functions[i]) {
        uint32_t rva = u32((const unsigned char *)metadata + 20 + i * 4);
        slots[i] = (void *)data(m, rva, 8);
        if (!rva || !slots[i] || !protection(slots[i], 8, VM_PROT_WRITE, VM_PROT_EXECUTE) ||
            (u64(slots[i]) && u64(slots[i]) != (uintptr_t)functions[i])) return -1;
    }
    for (unsigned i = 0; i < 5; ++i) if (slots[i]) memcpy(slots[i], functions+i, 8);
    return 0;
}

int madeira_pe_ec_import(struct madeira_signed_pe *m, const char *name,
                         void (*return_dispatch)(void), void (*call_dispatch)(void), void (*check_call)(void), void (*check_cfg)(void),
                         const void **target, const void **thunk)
{
    if (!name || !target || !thunk || !return_dispatch || !call_dispatch || !check_call || !check_cfg) return -1;
    unsigned char *function = madeira_pe_export(m, name, 0);
    if (!function || function < m->image + 4) return -1;
    uintptr_t base = (uintptr_t)m->image;
    int32_t displacement;
    memcpy(&displacement, function - 4, 4);
    displacement &= ~3;
    uintptr_t entry = (uintptr_t)function + (intptr_t)displacement;
    if (entry < base || !data(m, entry - base, 4) ||
        !protection((void *)entry, 4, VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_WRITE)) return -1;
    if (madeira_pe_ec_helpers(m, return_dispatch, call_dispatch, check_call, check_cfg)) return -1;
    *target = function; *thunk = (void *)entry;
    return 0;
}

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { void *original; struct madeira_signed_pe *module; } registry[128];
static struct {
    _Atomic(uint64_t) generation;
    _Atomic(uintptr_t) original, native, size, code_start, code_end;
} published[128];
static _Atomic(uint64_t) next_generation = 1;
static atomic_int enabled;
static atomic_uint wine_thread_offset;

int madeira_pe_wine_thread_offset(unsigned offset)
{
    if (!offset || offset >= 4096 || offset % 8) return -1;
    unsigned old = 0;
    return atomic_compare_exchange_strong(&wine_thread_offset, &old, offset) || old == offset ? 0 : -1;
}
static pthread_once_t configured = PTHREAD_ONCE_INIT;
static char registry_root[4096];
static int configuration_error;
static void configure(void)
{
    const char *root = getenv("MADEIRA_SIGNED_PE_DIR");
    if (!root || !*root) return;
    size_t length = strnlen(root, sizeof(registry_root));
    if (length == sizeof(registry_root)) configuration_error = -1;
    else memcpy(registry_root, root, length + 1);
    atomic_store_explicit(&enabled, 1, memory_order_release);
}
int madeira_pe_wine_configure(void)
{
    pthread_once(&configured, configure);
    return configuration_error;
}
int madeira_pe_wine_enabled(void)
{
    return atomic_load_explicit(&enabled, memory_order_acquire);
}
static void *translate(const void *address, int reverse)
{
    uintptr_t a = (uintptr_t)address;
    for (unsigned i = 0; i < 128; ++i) {
        uint64_t generation = atomic_load_explicit(&published[i].generation, memory_order_acquire);
        if (!generation) continue;
        uintptr_t original = atomic_load_explicit(&published[i].original, memory_order_relaxed);
        uintptr_t native = atomic_load_explicit(&published[i].native, memory_order_relaxed);
        uintptr_t size = atomic_load_explicit(&published[i].size, memory_order_relaxed);
        uintptr_t base = reverse ? native : original;
        atomic_thread_fence(memory_order_acquire);
        if (a >= base && a - base < size &&
            generation == atomic_load_explicit(&published[i].generation, memory_order_acquire))
            return (void *)((reverse ? original : native) + a - base);
    }
    return (void *)address;
}
void *madeira_pe_wine_translate(const void *address, int reverse)
{
    /* Fault redirects cannot wait on a lock held by the faulting thread. */
    return translate(address, reverse);
}
static int sync_data(unsigned index, size_t offset, size_t length)
{
    struct madeira_signed_pe *m = registry[index].module;
    const struct identity *id = m->identity;
    if (!inside(offset, length, id->image_size)) return -1;
    size_t end = offset + length;
    if (offset < id->data_rva) offset = id->data_rva;
    if (end <= offset) return 0;
    for (unsigned i = 0; i < id->section_count; ++i) {
        const unsigned char *section = m->image + m->sections + i * 40;
        size_t start = u32(section + 12), length = u32(section + 8), raw = u32(section + 16);
        if (raw > length) length = raw;
        size_t finish = start + length;
        if (start < offset) start = offset;
        if (finish > end) finish = end;
        if (finish > start) memcpy(m->image + start, (char *)registry[index].original + start, finish - start);
    }
    for (unsigned i = 0; i < id->fixup_count; ++i) {
        size_t rva = id->fixups[i];
        if (rva >= end || rva + 8 <= offset) continue;
        void *pointer;
        memcpy(&pointer, (char *)registry[index].original + rva, 8);
        uintptr_t value = (uintptr_t)pointer, original = (uintptr_t)registry[index].original;
        pointer = value >= original && value - original < id->image_size ?
            m->image + value - original : translate(pointer, 0);
        memcpy(m->image + rva, &pointer, 8);
    }
    uint32_t iat, iat_size;
    if (directory(m, 12, &iat, &iat_size)) for (size_t rva = iat; rva + 8 <= (size_t)iat + iat_size; rva += 8) {
        if (rva < offset || rva + 8 > end) continue;
        void *pointer;
        memcpy(&pointer, (char *)registry[index].original + rva, 8);
        pointer = translate(pointer, 0);
        memcpy(m->image + rva, &pointer, 8);
    }
    return 0;
}
int madeira_pe_wine_attach(void *image, size_t size)
{
    unsigned char hash[32];
    if (madeira_pe_wine_configure() || !madeira_pe_wine_enabled() || !code_hash(image, size, hash)) return -1;
    char hex[65], path[4096];
    for (unsigned i = 0; i < 32; ++i) snprintf(hex + i * 2, 3, "%02x", hash[i]);
    int count = snprintf(path, sizeof(path), "%s/WinePE_%s.framework/WinePE_%s", registry_root, hex, hex);
    if (count < 0 || (size_t)count >= sizeof(path)) return -1;
    pthread_mutex_lock(&registry_lock);
    unsigned index;
    for (index = 0; index < 128; ++index) if (registry[index].original == image) break;
    if (index < 128) { int result = sync_data(index, 0, size); pthread_mutex_unlock(&registry_lock); return result; }
    for (index = 0; index < 128 && registry[index].module; ++index) {}
    struct madeira_signed_pe *m = index < 128 ? madeira_pe_open(path, stderr) : NULL;
    if (!m) { pthread_mutex_unlock(&registry_lock); return -1; }
    if (m->thread) {
        if (madeira_pe_thread_offset(m, atomic_load(&wine_thread_offset))) {
            madeira_pe_close(m); pthread_mutex_unlock(&registry_lock); return -1;
        }
    }
    for (unsigned i = 0; i < 128; ++i) if (registry[i].module && registry[i].module->image == m->image) {
        /* shortcut: one data instance per signed library; reject concurrent pseudo-process copies. */
        madeira_pe_close(m); pthread_mutex_unlock(&registry_lock); return -1;
    }
    registry[index].module = m; registry[index].original = image;
    int result = sync_data(index, 0, size);
    if (result) { registry[index].module = NULL; registry[index].original = NULL; madeira_pe_close(m); }
    else {
        size_t code_start = m->identity->data_rva;
        for (unsigned i = 0; i < m->identity->section_count; ++i) {
            const unsigned char *section = m->image + m->sections + i * 40;
            if ((u32(section + 36) & 0x20000000) && u32(section + 12) < code_start) code_start = u32(section + 12);
        }
        atomic_store_explicit(&published[index].original, (uintptr_t)image, memory_order_relaxed);
        atomic_store_explicit(&published[index].native, (uintptr_t)m->image, memory_order_relaxed);
        atomic_store_explicit(&published[index].size, size, memory_order_relaxed);
        atomic_store_explicit(&published[index].code_start, (uintptr_t)image + code_start, memory_order_relaxed);
        atomic_store_explicit(&published[index].code_end, (uintptr_t)image + m->identity->data_rva, memory_order_relaxed);
        atomic_store_explicit(&published[index].generation, atomic_fetch_add(&next_generation, 1), memory_order_release);
    }
    pthread_mutex_unlock(&registry_lock);
    return result;
}
int madeira_pe_wine_sync(void *address, size_t size)
{
    uintptr_t a = (uintptr_t)address;
    int result = 0;
    pthread_mutex_lock(&registry_lock);
    for (unsigned i = 0; i < 128; ++i) if (registry[i].module) {
        uintptr_t base = (uintptr_t)registry[i].original;
        if (a >= base && a - base < registry[i].module->identity->image_size) {
            result = sync_data(i, a - base, size) ? -1 : 1;
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);
    return result;
}
void madeira_pe_wine_detach(void *image)
{
    pthread_mutex_lock(&registry_lock);
    for (unsigned i = 0; i < 128; ++i) if (registry[i].original == image && registry[i].module) {
        atomic_store_explicit(&published[i].generation, 0, memory_order_release);
        madeira_pe_close(registry[i].module);
        registry[i].module = NULL; registry[i].original = NULL;
    }
    pthread_mutex_unlock(&registry_lock);
}

int madeira_pe_wine_code_overlap(const void *address, size_t size)
{
    uintptr_t start = (uintptr_t)address;
    if (size > UINTPTR_MAX - start) return 1;
    int result = 0;
    for (unsigned i = 0; i < 128 && !result; ++i) {
        uint64_t generation = atomic_load_explicit(&published[i].generation, memory_order_acquire);
        if (!generation) continue;
        uintptr_t low = atomic_load_explicit(&published[i].code_start, memory_order_relaxed);
        uintptr_t high = atomic_load_explicit(&published[i].code_end, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (start < high && low < start + size &&
            generation == atomic_load_explicit(&published[i].generation, memory_order_acquire)) result = 1;
    }
    return result;
}
