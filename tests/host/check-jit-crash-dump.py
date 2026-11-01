#!/usr/bin/env python3
"""Run the real crash-artifact helper with hostile pointers and sparse pool stubs."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
begin = source.index('static void ios_jit_dump_range(')
end = source.index('\n/* The [fault-stuck]', begin)
helper = source[begin:end]
assert 'ios_dump_jit_pool( "mach UNHANDLED", &state, fault_addr, (uint64_t)thread )' in source
assert 'ios_dump_jit_pool( "ILL diag", &context->uc_mcontext->__ss,' in source

code = r'''
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef int kern_return_t;
#define KERN_SUCCESS 0
#define MINCORE_INCORE 1
#define MINCORE_PAGED_OUT 4
static unsigned vm_page_size = 16384;
typedef struct { uint64_t __x[29], pc, lr, sp, fp; } arm_thread_state64_t;
#define arm_thread_state64_get_pc(s) ((s).pc)
#define arm_thread_state64_get_lr(s) ((s).lr)
#define arm_thread_state64_get_sp(s) ((s).sp)
#define arm_thread_state64_get_fp(s) ((s).fp)
static unsigned char storage[65536];
void *ios_jit_rx_base_global = (void *)(uintptr_t)0x300000000ull;
void *ios_jit_rw_base_global = storage;
size_t ios_jit_pool_size_global = 0x40000000;
static unsigned scans, reads, invalid_reads, alias_reads;
static size_t copied;
static int full_allowed;
static int mach_task_self(void) { return 1; }
static kern_return_t mach_vm_read_overwrite(int task, mach_vm_address_t address,
        mach_vm_size_t size, mach_vm_address_t output, mach_vm_size_t *got)
{
    (void)task; reads++; assert(size <= 4096); *got = 0;
    if (address >= (uintptr_t)storage && address - (uintptr_t)storage <= sizeof(storage) &&
        size <= sizeof(storage) - (address - (uintptr_t)storage))
    {
        if (address == (uintptr_t)storage + 256) alias_reads++;
        memcpy((void *)(uintptr_t)output, (const void *)(uintptr_t)address, size);
        *got = size; copied += size; return KERN_SUCCESS;
    }
    invalid_reads++; return 1;
}
static int mincore(void *address, size_t size, char *vec)
{
    (void)address; assert(full_allowed); scans++;
    memset(vec, 0, size / vm_page_size);
    for (size_t i = 0; i < size / vm_page_size; i += 2) vec[i] = MINCORE_INCORE;
    return 0;
}
''' + helper + r'''
static off_t file_size(const char *name)
{
    struct stat st; return stat(name, &st) ? -1 : st.st_size;
}
static void reset_files(void)
{
    unlink("fex-jit-crash.txt"); unlink("fex-jit-dump.bin");
    scans = reads = invalid_reads = alias_reads = 0; copied = 0; full_allowed = 0;
    ios_jit_pool_size_global = 0x40000000;
}
static void verify_compact(const arm_thread_state64_t *state)
{
    char text[65536]; FILE *file;
    ios_dump_jit_pool("fixture fault", state, 0x19efef30, 0x254);
    assert(file_size("fex-jit-crash.txt") > 0 && file_size("fex-jit-crash.txt") < 65536);
    assert(file_size("fex-jit-dump.bin") == -1 && scans == 0 && reads <= 7 && copied <= 8960);
    file = fopen("fex-jit-crash.txt", "rb"); assert(file);
    size_t n = fread(text, 1, sizeof(text)-1, file); text[n] = 0; fclose(file);
    assert(strstr(text, "MADEIRA-JIT-CRASH-v1") && strstr(text, "fault=0x19efef30"));
    assert(strstr(text, "range=fault-address address=0x19efef30 read=0x19efef30 requested=256 kr=1 copied=0"));
    assert(invalid_reads > 0);
    if (state) assert(alias_reads == 1 && strstr(text,"x8=0x19efef30"));
}
int main(void)
{
    char directory[] = "/tmp/madeira-jit-crash-XXXXXX";
    arm_thread_state64_t state = {0};
    assert(mkdtemp(directory) && chdir(directory) == 0);
    setenv("MADEIRA_DOCS_DIR", directory, 1);
    memset(storage, 0x5a, sizeof(storage));
    state.pc = 0x300000200; state.lr = 0x300001000;
    state.sp = (uintptr_t)storage + 8192; state.fp = state.sp + 512;
    state.__x[28] = (uintptr_t)storage + 16384; state.__x[8] = 0x19efef30;
    state.__x[0] = 0xc000000d;
    unsetenv("MADEIRA_JIT_DUMP"); reset_files(); verify_compact(&state);
    setenv("MADEIRA_JIT_DUMP", "compact", 1); reset_files(); verify_compact(NULL);
    setenv("MADEIRA_JIT_DUMP", "unexpected", 1); reset_files(); verify_compact(&state);
    // Disabled mode does not create a new artifact or inspect any memory.
    setenv("MADEIRA_JIT_DUMP", "0", 1); reset_files();
    ios_dump_jit_pool("off", &state, 0, 0);
    assert(!reads && !scans && file_size("fex-jit-crash.txt") == -1 && file_size("fex-jit-dump.bin") == -1);
    // Only explicit opt-in scans the pool and preserves pool-relative sparse offsets.
    for (int mode = 0; mode < 2; mode++)
    {
        setenv("MADEIRA_JIT_DUMP", mode ? "full" : "1", 1); reset_files();
        ios_jit_pool_size_global = sizeof(storage); full_allowed = 1;
        vm_page_size = mode ? 4096 : 16384;
        ios_dump_jit_pool("explicit full", &state, 0, 0);
        assert(scans == 1 && reads == 0 && file_size("fex-jit-dump.bin") == sizeof(storage));
        assert(file_size("fex-jit-crash.txt") == -1);
        FILE *dump = fopen("fex-jit-dump.bin", "rb"); assert(dump);
        assert(fgetc(dump) == 0x5a);
        assert(!fseek(dump, vm_page_size, SEEK_SET) && fgetc(dump) == 0);
        assert(!fseek(dump, 2 * vm_page_size, SEEK_SET) && fgetc(dump) == 0x5a);
        fclose(dump);
    }
    // Bad, overflowing and stale candidates never become direct native reads.
    setenv("MADEIRA_JIT_DUMP", "compact", 1); reset_files();
    state.pc = UINT64_MAX; state.lr = 1; state.sp = 0x19efef30; state.fp = UINT64_MAX;
    state.__x[28] = UINT64_MAX; state.__x[8] = 0;
    ios_dump_jit_pool("invalid", &state, UINT64_MAX, 1);
    assert(file_size("fex-jit-crash.txt") < 65536 && scans == 0 && copied == 0);
    reset_files(); assert(chdir("/") == 0 && rmdir(directory) == 0);
    puts("PASS actual crash helper: compact bounded default, safe invalid/guest/alias reads, off switch and explicit sparse full mode at 4/16KB pages");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-jit-dump-test-') as directory:
    src, exe = Path(directory)/'check.c', Path(directory)/'check'
    src.write_text(code)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
