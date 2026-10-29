#!/usr/bin/env python3
"""Run the production wait and pipe fallbacks without new OS entry points."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
sync = (root / 'wine/dlls/ntdll/unix/sync.c').read_text()
sync = sync[sync.index('#elif defined(__APPLE__)'):]
assert sync.count('__builtin_available( macOS 14.4, iOS 17.4, * )') == 2
a = sync.index('static inline int futex_wait(')
b = sync.index('\n#endif /* __APPLE__ */', a)
waits = sync[a:b]
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
a = server.index('int server_pipe( int fd[2] )')
pipe = server[a:server.index('\n}', a) + 2]
code = r'''
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
typedef int LONG;
#ifndef MAC_OS_VERSION_14_4
#define MAC_OS_VERSION_14_4 1
#endif
#define HAVE_PIPE2 1
#define WINE_IOS 1
#define UL_COMPARE_AND_WAIT 1
#define OS_SYNC_WAIT_ON_ADDRESS_NONE 0
#define OS_SYNC_WAKE_BY_ADDRESS_NONE 0
#define OS_CLOCK_MACH_ABSOLUTE_TIME 0
static int available;
#define __builtin_available(...) available
static int __ulock_wait(uint32_t op, void *p, uint64_t value, uint32_t timeout)
{ assert(op == 1 && p && value == 5 && (timeout == 0 || timeout == 1000000)); return 11; }
static int __ulock_wake(uint32_t op, void *p, uint64_t value) { return 12; }
static int os_sync_wait_on_address(void *p, uint64_t v, int size, int flags) { return 21; }
static int os_sync_wait_on_address_with_timeout(void *p, uint64_t v, int size, int flags, int clock, uint64_t ns)
{ assert(ns == 1000000000); return 22; }
static int os_sync_wake_by_address_any(void *p, int size, int flags) { return 23; }
#define pipe2(...) _Static_assert(0, "iOS pipe2 must use the older pipe fallback")
WAITS
PIPE
int main(void)
{
    LONG value = 5;
    struct timespec one = {1,0}, zero = {0,0};
    assert(futex_wait(&value,5,NULL) == 11 && futex_wait(&value,5,&one) == 11);
    assert(futex_wake_one(&value) == 12);
    available = 1;
    assert(futex_wait(&value,5,NULL) == 21 && futex_wait(&value,5,&one) == 22);
    assert(futex_wake_one(&value) == 23);
    assert(futex_wait(&value,5,&zero) == -1 && errno == ETIMEDOUT);
    int fd[2]; assert(!server_pipe(fd));
    assert(fcntl(fd[0],F_GETFD) & FD_CLOEXEC);
    assert(fcntl(fd[1],F_GETFD) & FD_CLOEXEC);
    close(fd[0]); close(fd[1]);
}
'''.replace('WAITS', waits).replace('PIPE\n', pipe + '\n')
with tempfile.TemporaryDirectory() as folder:
    c = Path(folder) / 'test.c'
    binary = Path(folder) / 'test'
    c.write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-fsanitize=address,undefined', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: old-OS ulock fallback, newer wait API, timeout and close-on-exec pipe fallback')
