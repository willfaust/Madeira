/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Bounded read-only Steam UI file diagnostics. File coverage uses file offsets,
 * never the addresses/reuse of the caller's destination buffers.
 * Included only in the staged ntdll file.c; the pinned Wine tree is unchanged.
 */
#ifndef MADEIRA_JS_READ_TRACE_H
#define MADEIRA_JS_READ_TRACE_H
#include <stdint.h>
#include <pthread.h>
#include <sys/stat.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

#define IOS_JSTRACK_MAX 64
#define IOS_JSRANGES_MAX 64
struct ios_js_range { uint64_t lo, hi; };
struct ios_js_entry
{
    HANDLE handle;
    uintptr_t owner, previous_buffer;
    dev_t dev;
    ino_t ino;
    uint64_t generation, size, bytes, unknown_bytes;
    struct ios_js_range ranges[IOS_JSRANGES_MAX];
    unsigned int range_count;
    int coverage_incomplete;
    char name[40];
};
static struct ios_js_entry ios_js_track[IOS_JSTRACK_MAX];
static uint64_t ios_js_generation;
static unsigned int ios_js_open_lines, ios_js_read_lines;
static int ios_js_track_any;
static pthread_mutex_t ios_js_track_lock = PTHREAD_MUTEX_INITIALIZER;

static uintptr_t ios_js_owner(void)
{
    const TEB *current_teb = NtCurrentTeb();
    return current_teb ? (uintptr_t)current_teb->Peb : 0;
}

static uint64_t ios_js_known_bytes( const struct ios_js_entry *entry )
{
    uint64_t bytes = 0;
    unsigned int i;
    for (i = 0; i < entry->range_count; i++) bytes += entry->ranges[i].hi - entry->ranges[i].lo;
    return bytes;
}
static void ios_js_add_range( struct ios_js_entry *entry, uint64_t lo, uint64_t hi )
{
    unsigned int i = 0;
    if (hi < lo || hi > entry->size) { entry->coverage_incomplete = 1; return; }
    while (i < entry->range_count)
    {
        struct ios_js_range *range = &entry->ranges[i];
        if (range->hi < lo || range->lo > hi) { i++; continue; }
        if (range->lo < lo) lo = range->lo;
        if (range->hi > hi) hi = range->hi;
        memmove( range, range + 1, (--entry->range_count - i) * sizeof(*range) );
    }
    if (entry->range_count == IOS_JSRANGES_MAX) { entry->coverage_incomplete = 1; return; }
    entry->ranges[entry->range_count++] = (struct ios_js_range){lo, hi};
}
static void ios_js_track_add( HANDLE handle, const char *unix_name )
{
    struct stat st;
    struct ios_js_entry *entry = NULL;
    uintptr_t owner = ios_js_owner();
    const char *base, *dot;
    unsigned int i;
    int saved_errno = errno;
    if (!unix_name || !handle || !strstr( unix_name, "steamui" )) return;
    dot = strrchr( unix_name, '.' );
    if (!dot || strcmp( dot, ".js" )) return;
    if (stat( unix_name, &st ) == -1 || st.st_size < 0) { errno = saved_errno; return; }
    base = strrchr( unix_name, '/' ); base = base ? base + 1 : unix_name;
    pthread_mutex_lock( &ios_js_track_lock );
    for (i = 0; i < IOS_JSTRACK_MAX; i++)
        if (ios_js_track[i].generation && ios_js_track[i].owner == owner && ios_js_track[i].handle == handle)
        { entry = &ios_js_track[i]; break; }
    if (!entry)
        for (i = 0; i < IOS_JSTRACK_MAX; i++)
            if (!ios_js_track[i].generation) { entry = &ios_js_track[i]; break; }
    if (!entry)
    {
        entry = &ios_js_track[0];
        for (i = 1; i < IOS_JSTRACK_MAX; i++)
            if (ios_js_track[i].generation < entry->generation) entry = &ios_js_track[i];
    }
    memset( entry, 0, sizeof(*entry) );
    entry->handle = handle; entry->owner = owner; entry->dev = st.st_dev; entry->ino = st.st_ino;
    entry->size = st.st_size; entry->generation = ++ios_js_generation;
    snprintf( entry->name, sizeof(entry->name), "%s", base );
    __atomic_store_n( &ios_js_track_any, 1, __ATOMIC_RELAXED );
    if (ios_js_open_lines++ < 128)
        dprintf( 2, "[js-open-v2] %s owner=%p handle=%p generation=%llu ino=%llu size=%llu\n", entry->name,
                 (void *)owner, handle, (unsigned long long)entry->generation,
                 (unsigned long long)entry->ino, (unsigned long long)entry->size );
    pthread_mutex_unlock( &ios_js_track_lock ); errno = saved_errno;
}
static void ios_js_read_note( HANDLE handle, int unix_fd, const void *buffer, ULONG want, UINT got,
                             const LARGE_INTEGER *offset )
{
    struct ios_js_entry *entry = NULL;
    struct stat st;
    uintptr_t owner = ios_js_owner();
    uint64_t covered;
    unsigned int i, hashed, sum = 2166136261u;
    int saved_errno = errno, explicit_offset, reused, complete;
    char position[48];
    if (!got || !__atomic_load_n( &ios_js_track_any, __ATOMIC_RELAXED )) return;
    pthread_mutex_lock( &ios_js_track_lock );
    for (i = 0; i < IOS_JSTRACK_MAX; i++)
        if (ios_js_track[i].generation && ios_js_track[i].owner == owner && ios_js_track[i].handle == handle)
        { entry = &ios_js_track[i]; break; }
    if (!entry || unix_fd < 0 || fstat( unix_fd, &st ) || st.st_dev != entry->dev || st.st_ino != entry->ino)
        goto done;
    /* A same-inode size change starts a new observation generation. */
    if (st.st_size < 0) goto done;
    if ((uint64_t)st.st_size != entry->size)
    {
        entry->size = st.st_size; entry->range_count = 0; entry->bytes = entry->unknown_bytes = 0;
        entry->coverage_incomplete = 0; entry->generation = ++ios_js_generation;
    }
    entry->bytes += got;
    explicit_offset = offset && offset->QuadPart >= 0;
    if (explicit_offset)
    {
        uint64_t lo = offset->QuadPart;
        ios_js_add_range( entry, lo, lo + got );
        snprintf( position, sizeof(position), "%llu", (unsigned long long)lo );
    }
    else
    {
        /* NULL/FILE_USE_FILE_POINTER_POSITION are valid current-position I/O.
         * Do not guess an offset with a racy post-read lseek or a byte sum. */
        entry->unknown_bytes += got;
        snprintf( position, sizeof(position), "current-position" );
    }
    covered = ios_js_known_bytes( entry );
    complete = explicit_offset && entry->size && covered == entry->size && !entry->coverage_incomplete;
    reused = entry->previous_buffer == (uintptr_t)buffer;
    entry->previous_buffer = (uintptr_t)buffer;
    if (ios_js_read_lines++ >= 512) goto done;
    hashed = got > 65536 ? 65536 : got;
    for (i = 0; i < hashed; i++) { sum ^= ((const unsigned char *)buffer)[i]; sum *= 16777619u; }
    dprintf( 2, "[js-read-v2] %s generation=%llu offset=%s want=%u got=%u hash-prefix=%u sum=%08x "
                "buffer-reused=%d known-offset-bytes=%llu unknown-offset-bytes=%llu file-size=%llu "
                "file-offset-coverage-complete=%d coverage-truncated=%d\n", entry->name,
             (unsigned long long)entry->generation, position, (unsigned)want, got, hashed, sum, reused,
             (unsigned long long)covered, (unsigned long long)entry->unknown_bytes,
             (unsigned long long)entry->size, complete, entry->coverage_incomplete );
done:
    pthread_mutex_unlock( &ios_js_track_lock ); errno = saved_errno;
}
#endif
