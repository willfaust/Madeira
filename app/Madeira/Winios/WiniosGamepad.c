/* GPL-3.0-or-later WITH the Madeira Converter Exception, version 1. */
#include "WiniosGamepad.h"
#include <pthread.h>
#include <string.h>

/* ml1920: protect the payload as well as the version. A sequence counter
 * around a non-atomic struct copy still constitutes a C data race. The lock
 * covers only a 20-byte snapshot, never framework work or a Wine server call. */
static pthread_mutex_t pad_lock = PTHREAD_MUTEX_INITIALIZER;
static struct winios_gamepad pads[WINIOS_GAMEPAD_MAX];

void winios_gamepad_set_state(int index, const struct winios_gamepad *state)
{
    struct winios_gamepad next = {0};
    if (index < 0 || index >= WINIOS_GAMEPAD_MAX) return;
    if (state && state->connected) {
        next = *state;
        next.connected = 1;
        memset(next.reserved, 0, sizeof(next.reserved));
    }
    pthread_mutex_lock(&pad_lock);
    next.packet = pads[index].packet;
    if (memcmp(&next, &pads[index], sizeof(next))) {
        next.packet++;
        pads[index] = next;
    }
    pthread_mutex_unlock(&pad_lock);
}

int winios_gamepad_get_state(int index, struct winios_gamepad *out)
{
    struct winios_gamepad value = {0};
    if (index >= 0 && index < WINIOS_GAMEPAD_MAX) {
        pthread_mutex_lock(&pad_lock);
        value = pads[index];
        pthread_mutex_unlock(&pad_lock);
    }
    if (out) {
        if (value.connected) *out = value;
        else memset(out, 0, sizeof(*out));
    }
    return value.connected != 0;
}

/* ml2100: the HID controller's snapshot. Its own lock, so the XInput slots
 * above keep exactly the contention they had. The wineserver thread reads it
 * for every report it builds; the app's gamepad queue writes it. 48 bytes. */
static pthread_mutex_t hidpad_lock = PTHREAD_MUTEX_INITIALIZER;
static struct winios_hidpad hidpad;

void winios_hidpad_set_state(const struct winios_hidpad *state)
{
    struct winios_hidpad next = {0};
    if (state && state->connected) {
        next = *state;
        next.connected = 1;
        memset(next.reserved, 0, sizeof(next.reserved));
        next.reserved2 = 0;
    }
    pthread_mutex_lock(&hidpad_lock);
    next.packet = hidpad.packet;
    if (memcmp(&next, &hidpad, sizeof(next))) {
        next.packet++;
        hidpad = next;
    }
    pthread_mutex_unlock(&hidpad_lock);
}

int winios_hidpad_get_state(struct winios_hidpad *out)
{
    struct winios_hidpad value;
    pthread_mutex_lock(&hidpad_lock);
    value = hidpad;
    pthread_mutex_unlock(&hidpad_lock);
    if (out) {
        if (value.connected) *out = value;
        else {
            /* Keep the packet: a disconnect is a change the reader must see. */
            memset(out, 0, sizeof(*out));
            out->packet = value.packet;
        }
    }
    return value.connected != 0;
}
