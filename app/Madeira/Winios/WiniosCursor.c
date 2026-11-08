/* Copyright 2026 125hz
 *
 * Direct-mode cursor state (see WiniosCursor.h). GPL-3.0-or-later WITH the
 * Madeira Converter Exception, version 1; see LICENSE-EXCEPTION.md.
 *
 * The lock covers small copies only: never a framework call, never a Wine
 * server call. The notification runs after the lock is dropped, at most once
 * until the app takes the state (winios_direct_cursor_get). */
#include "WiniosCursor.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t cursor_lock = PTHREAD_MUTEX_INITIALIZER;
static int cursor_enabled;                     /* atomic; set once, after cursor_notify */
static winios_direct_cursor_notify_t cursor_notify;
static int cursor_tracking;
static int cursor_pending;                     /* a notification is outstanding */
static struct winios_direct_cursor_state cursor_state;
static unsigned char cursor_image[WINIOS_CURSOR_MAX * WINIOS_CURSOR_MAX * 4];

/* Called with the lock held: whether the caller must notify after unlocking. */
static int cursor_mark_changed(void)
{
    cursor_state.reports++;
    if (cursor_pending || !cursor_notify) return 0;
    cursor_pending = 1;
    return 1;
}

static void cursor_notify_unlocked(int notify)
{
    if (notify) cursor_notify();
}

int winios_direct_cursor_wanted(void)
{
    return __atomic_load_n(&cursor_enabled, __ATOMIC_ACQUIRE);
}

void winios_direct_cursor_set(unsigned int id, int w, int h, int hot_x, int hot_y, const void *bgra)
{
    int notify;
    (void)id;
    if (!winios_direct_cursor_wanted() || !bgra || w <= 0 || h <= 0 ||
        w > WINIOS_CURSOR_MAX || h > WINIOS_CURSOR_MAX) return;
    pthread_mutex_lock(&cursor_lock);
    memcpy(cursor_image, bgra, (size_t)w * h * 4);
    cursor_state.w = w;
    cursor_state.h = h;
    cursor_state.hot_x = hot_x;
    cursor_state.hot_y = hot_y;
    if (!++cursor_state.image_serial) cursor_state.image_serial = 1;   /* 0 means "none" */
    notify = cursor_mark_changed();
    pthread_mutex_unlock(&cursor_lock);
    cursor_notify_unlocked(notify);
}

void winios_direct_cursor_show(int show)
{
    int notify = 0;
    if (!winios_direct_cursor_wanted()) return;
    show = !!show;
    pthread_mutex_lock(&cursor_lock);
    if (cursor_state.shown != show || !cursor_state.reports)
    {
        cursor_state.shown = show;
        notify = cursor_mark_changed();
    }
    pthread_mutex_unlock(&cursor_lock);
    cursor_notify_unlocked(notify);
}

void winios_direct_cursor_pos(int x, int y)
{
    int notify = 0;
    if (!winios_direct_cursor_wanted()) return;
    pthread_mutex_lock(&cursor_lock);
    /* While tracking, every report counts, moved or not: it also says that a
     * program is draining the app's mouse input. Otherwise only the first. */
    cursor_state.x = x;
    cursor_state.y = y;
    if (cursor_tracking || !cursor_state.reports) notify = cursor_mark_changed();
    pthread_mutex_unlock(&cursor_lock);
    cursor_notify_unlocked(notify);
}

/* The Wine server's thread, with every mouse event: only a change notifies. */
void winios_direct_cursor_reader(unsigned int flags)
{
    int notify = 0;
    if (!winios_direct_cursor_wanted()) return;
    flags &= WINIOS_READER_RAW_CAPTURE | WINIOS_READER_LL_HOOK | WINIOS_READER_RAW;
    pthread_mutex_lock(&cursor_lock);
    if (cursor_state.reader != flags)
    {
        cursor_state.reader = flags;
        notify = cursor_mark_changed();
    }
    pthread_mutex_unlock(&cursor_lock);
    cursor_notify_unlocked(notify);
}

void winios_direct_cursor_enable(winios_direct_cursor_notify_t notify)
{
    pthread_mutex_lock(&cursor_lock);
    cursor_notify = notify;
    pthread_mutex_unlock(&cursor_lock);
    __atomic_store_n(&cursor_enabled, 1, __ATOMIC_RELEASE);
}

void winios_direct_cursor_track(int on)
{
    pthread_mutex_lock(&cursor_lock);
    cursor_tracking = !!on;
    pthread_mutex_unlock(&cursor_lock);
}

void winios_direct_cursor_get(struct winios_direct_cursor_state *out)
{
    pthread_mutex_lock(&cursor_lock);
    if (out) *out = cursor_state;
    cursor_pending = 0;
    pthread_mutex_unlock(&cursor_lock);
}

unsigned int winios_direct_cursor_copy_image(void *dst, size_t cap, struct winios_direct_cursor_state *image)
{
    unsigned int serial = 0;
    pthread_mutex_lock(&cursor_lock);
    if (dst && cursor_state.w > 0 && (size_t)cursor_state.w * cursor_state.h * 4 <= cap)
    {
        memcpy(dst, cursor_image, (size_t)cursor_state.w * cursor_state.h * 4);
        serial = cursor_state.image_serial;
        if (image)
        {
            image->w = cursor_state.w;
            image->h = cursor_state.h;
            image->hot_x = cursor_state.hot_x;
            image->hot_y = cursor_state.hot_y;
            image->image_serial = serial;
        }
    }
    pthread_mutex_unlock(&cursor_lock);
    return serial;
}
