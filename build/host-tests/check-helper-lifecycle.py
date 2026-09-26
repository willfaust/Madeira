#!/usr/bin/env python3
"""Exercise production section/descriptor retirement helpers without running Wine."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


server = (root / 'build/ntdll-unix/server_ios.c').read_text()
env = (root / 'build/ntdll-unix/env_ios.c').read_text()
header = (root / 'wine/dlls/ntdll/unix/unix_private.h').read_text()
cache_union = server[server.index('union fd_cache_entry\n'):server.index('C_ASSERT( sizeof(union fd_cache_entry)')]
cache_structs = server[server.index('struct ios_fd_cache {'):server.index('static struct ios_fd_cache *ios_get_fd_cache')]
prefix = r'''
#define WINE_IOS 1
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <pthread.h>
typedef int64_t LONG64;
typedef uintptr_t ULONG_PTR;
typedef unsigned long ULONG;
typedef size_t SIZE_T;
typedef int NTSTATUS;
typedef void *HANDLE;
enum server_fd_type { FD_TYPE_INVALID, FD_TYPE_FILE };
#define FD_CACHE_BLOCK_SIZE (65536 / sizeof(union fd_cache_entry))
#define FD_CACHE_ENTRIES 128
static unsigned closes;
static void ios_fdt_note_close(int fd, const char *why, void *peb) { assert(fd >= 0); closes++; }
static ULONG_PTR user_space_wow_limit, guest_base, observed_limit;
static ULONG_PTR ios_wow_base(void) { return guest_base; }
void ios_inproc_cache_release( void *peb ) { (void)peb; }   /* merge: upstream inproc cache (sync.c) */
#define NtCurrentProcess() ((void *)-1)
#define ViewShare 1
static NTSTATUS NtMapViewOfSection(HANDLE section, HANDLE process, void **ptr,
    ULONG_PTR bits, size_t commit, void *offset, SIZE_T *size, int inherit, int flags, ULONG protect)
{
    assert(*ptr == NULL && *size == 0);
    observed_limit = bits;
    /* Model the native allocator's inability to satisfy a sub-4-GB ceiling. */
    return !guest_base && bits ? -1 : 0;
}
'''
checks = r'''
static void mapping_checks(void)
{
    void *ptr = (void *)123;
    SIZE_T size = 456;
    unsetenv("MADEIRA_SECTION_PROCESS_LIMIT");
    for (int i = 0; i < 3; ++i)
    {
        ULONG_PTR limits[] = {0, 0x7fffffff, 0xffffffff};
        user_space_wow_limit = limits[i];
        guest_base = 0x7100000000;
        assert(map_section(NULL, &ptr, &size, 2) == 0);
        assert(observed_limit == limits[i]);
        guest_base = 0;
        assert(map_section(NULL, &ptr, &size, 2) == 0);
        assert(observed_limit == 0);
        guest_base = 0x7200000000;
        assert(map_section(NULL, &ptr, &size, 2) == 0);
        assert(observed_limit == limits[i]);
    }
    guest_base = 0;
    setenv("MADEIRA_SECTION_PROCESS_LIMIT", "0", 1);
    assert(map_section(NULL, &ptr, &size, 2) == -1);
    assert(observed_limit == 0xffffffff);
    unsetenv("MADEIRA_SECTION_PROCESS_LIMIT");
    puts("PASS: native helper mappings, guest ceilings, transitions and rollback");
}
static struct ios_fd_cache *new_cache(int slot, void *peb)
{
    struct ios_fd_cache *c = calloc(1, sizeof(*c));
    assert(c);
    c->blocks[0] = c->initial_block;
    ios_fd_caches[slot].peb = peb;
    ios_fd_caches[slot].cache = c;
    ios_fd_caches[slot].in_use = 1;
    if (ios_fd_cache_count <= slot) ios_fd_cache_count = slot + 1;
    return c;
}
static void retirement_checks(void)
{
    int pipes[2], other[2];
    assert(pipe(pipes) == 0 && pipe(other) == 0);
    assert(pipes[1] == pipes[0] + 1); /* Original off-by-one closes this endpoint. */
    unsetenv("MADEIRA_FD_CACHE_RELEASE_FIX");
    struct ios_fd_cache *c = new_cache(0, (void *)123);
    struct ios_fd_cache *neighbor = new_cache(1, (void *)456);
    c->initial_block[0].s.fd = pipes[0] + 1;
    c->initial_block[0].s.type = FD_TYPE_FILE;
    c->initial_block[1].s.fd = other[0] + 1;
    c->initial_block[1].s.type = FD_TYPE_INVALID;
    c->initial_block[2].s.fd = (int)0xc0000001;
    c->initial_block[2].s.type = FD_TYPE_INVALID;
    neighbor->initial_block[0].s.fd = other[0] + 1;
    neighbor->initial_block[0].s.type = FD_TYPE_FILE;
    size_t length = FD_CACHE_BLOCK_SIZE * sizeof(union fd_cache_entry);
    c->blocks[1] = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(c->blocks[1] != MAP_FAILED);
    /* A real cached fd 0 must be decoded and closed as well. */
    assert(dup2(pipes[0], 0) == 0);
    c->blocks[1][0].s.fd = 1;
    c->blocks[1][0].s.type = FD_TYPE_FILE;
    ios_fd_cache_release((void *)123);
    assert(closes == 2 && !ios_fd_caches[0].in_use && !ios_fd_caches[0].cache);
    assert(fcntl(pipes[0], F_GETFD) == -1 && fcntl(0, F_GETFD) == -1);
    assert(fcntl(pipes[1], F_GETFD) >= 0 && fcntl(other[0], F_GETFD) >= 0);
    ios_fd_cache_release((void *)123); /* Repeated retirement is harmless. */
    assert(closes == 2);
    ios_fd_cache_release((void *)456);
    assert(closes == 3 && fcntl(other[0], F_GETFD) == -1);
    close(pipes[1]); close(other[1]);
    puts("PASS: decoded descriptors, fd zero, invalid entries, mapped blocks and process isolation");

    /* Rollback reproduces the wrong-close defect using disposable pipe ends. */
    assert(pipe(pipes) == 0);
    if (pipes[0] == 0) { int replacement = fcntl(pipes[0], F_DUPFD, 10); close(pipes[0]); pipes[0] = replacement; }
    int adjacent = dup2(pipes[1], pipes[0] + 1);
    assert(adjacent == pipes[0] + 1);
    c = new_cache(0, NULL); /* NULL is a valid process identity. */
    c->initial_block[0].s.fd = pipes[0] + 1;
    c->initial_block[0].s.type = FD_TYPE_FILE;
    setenv("MADEIRA_FD_CACHE_RELEASE_FIX", "0", 1);
    ios_fd_cache_release(NULL);
    assert(fcntl(pipes[0], F_GETFD) >= 0 && fcntl(adjacent, F_GETFD) == -1);
    close(pipes[0]); if (pipes[1] != adjacent) close(pipes[1]);
    puts("PASS: rollback reproduces adjacent-descriptor closure");
}
int main(void) { mapping_checks(); retirement_checks(); return 0; }
'''
source = '\n'.join([prefix, cache_union, cache_structs,
    function(env, 'ULONG_PTR ios_section_zero_bits(void)'),
    function(header, 'static inline NTSTATUS map_section('),
    function(server, 'void ios_fd_cache_release('), checks])
with tempfile.TemporaryDirectory(prefix='madeira-helper-check-') as directory:
    path = Path(directory)
    (path / 'check.c').write_text(source)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-g', '-O1', '-fsanitize=address,undefined',
                    '-fno-omit-frame-pointer', '-pthread', str(path / 'check.c'),
                    '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True,
                   env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=1'})
