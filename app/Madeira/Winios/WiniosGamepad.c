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

/* ml2100: the HID controller's snapshot and the game's output state. Their own
 * lock, so the XInput slots above keep exactly the contention they had. The
 * wineserver thread reads the snapshot for every report it builds and writes
 * the output state when a game sends an output report; the app's gamepad
 * queue does the opposite. Both copies are under 50 bytes. */
static pthread_mutex_t hidpad_lock = PTHREAD_MUTEX_INITIALIZER;
static struct winios_hidpad hidpad;
static struct winios_hidpad_output hidpad_output;

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

/* ml2106: the app's "something to apply" hook; see WiniosGamepad.h. */
static winios_pad_output_notify_fn output_notify;

void winios_pad_output_set_notify(winios_pad_output_notify_fn fn)
{
    __atomic_store_n(&output_notify, fn, __ATOMIC_RELEASE);
}

static void notify_output(void)
{
    winios_pad_output_notify_fn fn = __atomic_load_n(&output_notify, __ATOMIC_ACQUIRE);
    if (fn) fn();
}

void winios_hidpad_set_output(const struct winios_hidpad_output *output)
{
    struct winios_hidpad_output next;
    int changed = 0;
    if (!output) return;
    next = *output;
    memset(next.reserved, 0, sizeof(next.reserved));
    pthread_mutex_lock(&hidpad_lock);
    next.serial = hidpad_output.serial;
    if (memcmp(&next, &hidpad_output, sizeof(next))) {
        next.serial++;
        hidpad_output = next;
        changed = 1;
    }
    pthread_mutex_unlock(&hidpad_lock);
    if (changed) notify_output();
}

int winios_hidpad_get_output(uint32_t seen, struct winios_hidpad_output *out)
{
    struct winios_hidpad_output value;
    pthread_mutex_lock(&hidpad_lock);
    value = hidpad_output;
    pthread_mutex_unlock(&hidpad_lock);
    if (out) *out = value;
    return value.serial != seen;
}

/* ml2106: XInput rumble, per slot. Its own lock: XInputSetState may come from
 * any game thread, as often as every frame; only a change notifies. */
static pthread_mutex_t vibration_lock = PTHREAD_MUTEX_INITIALIZER;
static struct winios_gamepad_vibration vibrations[WINIOS_GAMEPAD_MAX];
static int rumble_caps;

void winios_gamepad_set_vibration(int index, uint16_t left, uint16_t right)
{
    int changed = 0;
    if (index < 0 || index >= WINIOS_GAMEPAD_MAX) return;
    pthread_mutex_lock(&vibration_lock);
    if (!vibrations[index].serial || vibrations[index].left != left || vibrations[index].right != right) {
        vibrations[index].left = left;
        vibrations[index].right = right;
        if (!++vibrations[index].serial) vibrations[index].serial = 1;
        changed = 1;
    }
    pthread_mutex_unlock(&vibration_lock);
    if (changed) notify_output();
}

uint32_t winios_gamepad_get_vibration(int index, struct winios_gamepad_vibration *out)
{
    struct winios_gamepad_vibration value = {0};
    if (index >= 0 && index < WINIOS_GAMEPAD_MAX) {
        pthread_mutex_lock(&vibration_lock);
        value = vibrations[index];
        pthread_mutex_unlock(&vibration_lock);
    }
    if (out) *out = value;
    return value.serial;
}

void winios_gamepad_set_rumble_caps(int on)
{
    __atomic_store_n(&rumble_caps, !!on, __ATOMIC_RELAXED);
}

int winios_gamepad_rumble_caps(void)
{
    return __atomic_load_n(&rumble_caps, __ATOMIC_RELAXED);
}

/* ml2170: per-slot battery for XInputGetBatteryInformation. Its own lock: the
 * app writes it at most once a second per slot, a game may read it every frame. */
static pthread_mutex_t battery_lock = PTHREAD_MUTEX_INITIALIZER;
static struct winios_gamepad_battery batteries[WINIOS_GAMEPAD_MAX];

int winios_gamepad_set_battery(int index, const struct winios_gamepad_battery *battery)
{
    struct winios_gamepad_battery next = {0};
    int changed = 0;
    if (index < 0 || index >= WINIOS_GAMEPAD_MAX) return 0;
    if (battery && battery->valid) {
        next.valid = 1;
        next.type = battery->type;
        next.level = battery->level;
    }
    pthread_mutex_lock(&battery_lock);
    if (memcmp(&next, &batteries[index], sizeof(next))) {
        batteries[index] = next;
        changed = 1;
    }
    pthread_mutex_unlock(&battery_lock);
    return changed;
}

int winios_gamepad_get_battery(int index, struct winios_gamepad_battery *out)
{
    struct winios_gamepad_battery value = {0};
    if (index >= 0 && index < WINIOS_GAMEPAD_MAX) {
        pthread_mutex_lock(&battery_lock);
        value = batteries[index];
        pthread_mutex_unlock(&battery_lock);
    }
    if (out) *out = value;
    return value.valid != 0;
}
