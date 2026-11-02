#!/usr/bin/env python3
"""Exercise the production queue-mask handler with and without a driver fd.

The DirectInput worker may drain Madeira's native ring immediately before an
infinite message wait. It has no driver fd, but must still install its wake
mask and signal any raw input already queued. Compile the actual handler on
the host, stubbing only server objects and fd/sync operations.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/wineserver/queue_ios.c').read_text()
start = source.index('DECL_HANDLER(set_queue_mask)')
handler = source[start:source.index('/* get the current message queue status */', start)]
fixture = r'''
#include <assert.h>
#include <poll.h>
#include <stdio.h>
typedef struct {
    unsigned wake_mask, changed_mask, wake_bits, changed_bits, internal_bits;
    long long access_time;
} queue_shm_t;
struct msg_queue { void *fd; void *sync; queue_shm_t *shared; };
struct request { unsigned poll_events, wake_mask, changed_mask; };
struct reply { unsigned wake_bits, changed_bits; };
static struct msg_queue *current_queue;
static int signaled, fd_polls, driver_clears;
static const long long monotonic_time = 123456;
#define QS_DRIVER 0x80000000u
#define QS_RAWINPUT 0x0400u
#define QS_ALLINPUT 0x04ffu
#define DECL_HANDLER(name) static void name(const struct request *req, struct reply *reply)
#define SHARED_WRITE_BEGIN(shm, type) { type *shared = (shm);
#define SHARED_WRITE_END }
static struct msg_queue *get_current_queue(void) { return current_queue; }
static int get_queue_status(struct msg_queue *q) {
    queue_shm_t *s = q->shared;
    return (s->wake_bits & s->wake_mask) ||
           (s->changed_bits & s->changed_mask) || s->internal_bits;
}
static void clear_queue_bits(struct msg_queue *q, unsigned bits) {
    assert(q->fd && bits == QS_DRIVER);
    q->shared->internal_bits &= ~bits;
    driver_clears++;
}
static void set_fd_events(void *fd, int events) {
    assert(fd && events == POLLIN); fd_polls++;
}
static void signal_sync(void *sync) { assert(sync); signaled = 1; }
static void reset_sync(void *sync) { assert(sync); signaled = 0; }
'''
fixture += handler + r'''
int main(void) {
    for (int fd = 0; fd < 2; fd++)
    for (int drained = 0; drained < 2; drained++)
    for (int pending = 0; pending < 2; pending++)
    for (int available = 0; available < 2; available++) {
        queue_shm_t shared = {0};
        struct msg_queue queue = {fd ? &fd : NULL, &queue, &shared};
        struct request req = {drained, available ? QS_ALLINPUT : 0, QS_ALLINPUT};
        struct reply reply = {0};
        shared.wake_bits = shared.changed_bits = pending ? QS_RAWINPUT : 0;
        current_queue = &queue;
        signaled = 1; fd_polls = driver_clears = 0;
        set_queue_mask(&req, &reply);
        assert(shared.access_time == monotonic_time);
        assert(shared.wake_mask == req.wake_mask);
        assert(shared.changed_mask == QS_ALLINPUT);
        assert(reply.wake_bits == shared.wake_bits);
        assert(reply.changed_bits == shared.changed_bits);
        assert(signaled == pending);
        assert(fd_polls == (fd && drained));
        assert(driver_clears == (fd && drained));
    }
    current_queue = NULL;
    struct request req = {1, 0, QS_ALLINPUT};
    struct reply reply = {0};
    set_queue_mask(&req, &reply);
    puts("PASS: 16 queue wait/drain cases, including pending RawInput without a driver fd");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-queue-wake-') as tmp:
    csrc, exe = Path(tmp) / 'queue.c', Path(tmp) / 'queue'
    csrc.write_text(fixture)
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Wextra', '-Werror',
                    str(csrc), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
