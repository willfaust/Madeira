/*
 * iOS-Madeira: XInput host pads.
 *
 * There is no winebus/hidclass stack on iOS, so xinput can never see a HID
 * gamepad. Instead the app observes GameController.framework (DualSense,
 * DualShock, Xbox, MFi — all look the same there) and pushes each pad's
 * state into the table below via madeira_pad_*; xinput1_3's host mode
 * (wine/dlls/xinput1_3/main.c) reads it through these unix calls.
 *
 * Vibration flows the other way: xinput stores the requested motor speeds
 * here and the app polls them with madeira_pad_get_vibration.
 *
 * Registered in virtual_ios.c load_builtin_unixlib for any module whose
 * name contains "xinput".
 */

#include <pthread.h>
#include <string.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "wine/unixlib.h"
#include "unixlib.h"

#include "MadeiraPad.h"   /* app/Madeira — the Swift-facing API */

#define PAD_COUNT 4

struct host_pad
{
    int connected;
    UINT32 packet;
    UINT16 buttons;
    BYTE lt, rt;
    INT16 lx, ly, rx, ry;
    UINT16 vid, pid;
    int has_rumble;
    UINT16 vib_left, vib_right;
    UINT32 vib_serial;
};

static struct host_pad pads[PAD_COUNT];
static pthread_mutex_t pads_lock = PTHREAD_MUTEX_INITIALIZER;

/* ---- host (Swift) side ---------------------------------------------- */

void madeira_pad_set_connected(int index, int connected, int vendor_id, int product_id, int has_rumble)
{
    struct host_pad *pad;

    if (index < 0 || index >= PAD_COUNT) return;
    pthread_mutex_lock(&pads_lock);
    pad = &pads[index];
    if (connected && !pad->connected) memset(pad, 0, sizeof(*pad));
    if (connected)
    {
        /* May change while connected: slot 0 is shared by the touch pad
         * and whichever physical pad takes it. */
        pad->vid = vendor_id;
        pad->pid = product_id;
        pad->has_rumble = has_rumble;
    }
    pad->connected = connected;
    if (!connected)
    {
        pad->buttons = 0;
        pad->lt = pad->rt = 0;
        pad->lx = pad->ly = pad->rx = pad->ry = 0;
        pad->vib_left = pad->vib_right = 0;
    }
    pad->packet++;
    pthread_mutex_unlock(&pads_lock);
}

void madeira_pad_update(int index, int buttons, int left_trigger, int right_trigger,
                        int thumb_lx, int thumb_ly, int thumb_rx, int thumb_ry)
{
    struct host_pad *pad;

    if (index < 0 || index >= PAD_COUNT) return;
    pthread_mutex_lock(&pads_lock);
    pad = &pads[index];
    if (pad->buttons != (UINT16)buttons || pad->lt != (BYTE)left_trigger || pad->rt != (BYTE)right_trigger ||
        pad->lx != (INT16)thumb_lx || pad->ly != (INT16)thumb_ly ||
        pad->rx != (INT16)thumb_rx || pad->ry != (INT16)thumb_ry)
    {
        pad->buttons = buttons;
        pad->lt = left_trigger;
        pad->rt = right_trigger;
        pad->lx = thumb_lx;
        pad->ly = thumb_ly;
        pad->rx = thumb_rx;
        pad->ry = thumb_ry;
        pad->packet++;
    }
    pthread_mutex_unlock(&pads_lock);
}

int madeira_pad_get_vibration(int index, int *left_motor, int *right_motor)
{
    int serial;

    if (index < 0 || index >= PAD_COUNT) return 0;
    pthread_mutex_lock(&pads_lock);
    *left_motor = pads[index].vib_left;
    *right_motor = pads[index].vib_right;
    serial = pads[index].vib_serial;
    pthread_mutex_unlock(&pads_lock);
    return serial;
}

/* ---- guest (xinput) side -------------------------------------------- */

static NTSTATUS xinput_host_probe(void *args)
{
    struct xinput_host_probe_params *params = args;
    params->abi = XINPUT_HOST_ABI;
    return STATUS_SUCCESS;
}

static NTSTATUS xinput_host_get_state(void *args)
{
    struct xinput_host_state_params *params = args;
    struct host_pad *pad;

    if (params->index >= PAD_COUNT) return STATUS_INVALID_PARAMETER;
    pthread_mutex_lock(&pads_lock);
    pad = &pads[params->index];
    params->connected = pad->connected;
    params->packet = pad->packet;
    params->buttons = pad->buttons;
    params->left_trigger = pad->lt;
    params->right_trigger = pad->rt;
    params->thumb_lx = pad->lx;
    params->thumb_ly = pad->ly;
    params->thumb_rx = pad->rx;
    params->thumb_ry = pad->ry;
    params->vendor_id = pad->vid;
    params->product_id = pad->pid;
    params->has_rumble = pad->has_rumble;
    pthread_mutex_unlock(&pads_lock);
    return STATUS_SUCCESS;
}

static NTSTATUS xinput_host_set_vibration(void *args)
{
    struct xinput_host_vibration_params *params = args;
    struct host_pad *pad;

    if (params->index >= PAD_COUNT) return STATUS_INVALID_PARAMETER;
    pthread_mutex_lock(&pads_lock);
    pad = &pads[params->index];
    if (pad->connected &&
        (pad->vib_left != params->left_motor || pad->vib_right != params->right_motor))
    {
        pad->vib_left = params->left_motor;
        pad->vib_right = params->right_motor;
        pad->vib_serial++;
    }
    pthread_mutex_unlock(&pads_lock);
    return STATUS_SUCCESS;
}

const unixlib_entry_t xinput_unix_call_funcs[] =
{
    xinput_host_probe,
    xinput_host_get_state,
    xinput_host_set_vibration,
};

C_ASSERT(ARRAYSIZE(xinput_unix_call_funcs) == unix_xinput_host_funcs_count);
