/* Host controller snapshot shared with win32u. GPL-3.0-or-later WITH the
 * Madeira Converter Exception, version 1; see LICENSE-EXCEPTION.md. */
#ifndef WINIOS_GAMEPAD_H
#define WINIOS_GAMEPAD_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
#define WINIOS_GAMEPAD_MAX 4
struct winios_gamepad {
    uint32_t packet;
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t lx, ly, rx, ry;
    uint8_t connected;
    uint8_t reserved[3];
};

/* NULL disconnects. The transport owns packet numbers; unchanged samples do
 * not advance them. All callers may run concurrently. No callbacks under lock. */
void winios_gamepad_set_state(int index, const struct winios_gamepad *state);
int winios_gamepad_get_state(int index, struct winios_gamepad *out);

/* ml2100: the opt-in HID controller (env.MADEIRA_PAD_MODE = hid). Player 1
 * only, served by the wineserver (build/wineserver/hidpad_ios.c) as a DualSense
 * or a generic HID gamepad; the XInput snapshot above is not involved and its
 * path is unchanged. The low 16 bits of `buttons` are the XINPUT_GAMEPAD_* bits
 * (so the XInput sample, touch merge included, carries over as is); the bits
 * above are what XInput cannot express. Sticks keep the XInput convention: full
 * signed range, +y is up. */
#define WINIOS_HIDPAD_TOUCHPAD 0x00010000u  /* DualSense touchpad click */
#define WINIOS_HIDPAD_MUTE     0x00020000u  /* DualSense microphone button */
#define WINIOS_HIDPAD_L2       0x00040000u  /* trigger past its digital threshold */
#define WINIOS_HIDPAD_R2       0x00080000u

#define WINIOS_HIDPAD_BATTERY_UNKNOWN 0xff

struct winios_hidpad {
    uint32_t packet;              /* transport-owned, as winios_gamepad */
    uint32_t buttons;
    int16_t lx, ly, rx, ry;
    uint8_t left_trigger, right_trigger;
    uint8_t connected;
    uint8_t battery;              /* 0-100, or WINIOS_HIDPAD_BATTERY_UNKNOWN */
    uint8_t charging;             /* 0 discharging, 1 charging, 2 full */
    uint8_t motion;               /* 1: gyro/accel below are live */
    uint8_t touch[2];             /* 1: finger down on touchpad point 0/1 */
    uint8_t reserved[2];
    uint16_t touch_x[2];          /* DualSense touchpad units, 0-1919 */
    uint16_t touch_y[2];          /* 0-1079 */
    int16_t gyro[3];              /* DualSense units (16 per deg/s, feature 0x05) */
    int16_t accel[3];             /* DualSense units (8192 per g) */
    uint16_t reserved2;           /* 48 bytes, no padding: the transport memcmp()s it */
};

/* What the game wrote to the pad (output report 0x02), newest state, for the
 * app to apply. `serial` advances on every change; *_valid say which parts the
 * game has set at least once. Rumble is the "compatible vibration" pair. */
struct winios_hidpad_output {
    uint32_t serial;
    uint8_t rumble_valid, rumble_left, rumble_right;
    uint8_t lightbar_valid, red, green, blue;
    uint8_t player_leds_valid, player_leds;
    uint8_t mute_led_valid, mute_led;
    uint8_t trigger_valid[2];     /* [0] left (L2), [1] right (R2) */
    uint8_t trigger[2][11];       /* the effect block as written: mode, then parameters */
    uint8_t power_valid;          /* the game set the motor power reduction */
    uint8_t power_reduction;      /* low nibble triggers, high nibble rumble, 0-7 = 0-87.5 % less */
    uint8_t reserved[3];          /* 44 bytes, no padding */
};

/* NULL disconnects (the device stays, at rest). Same locking rules as above. */
void winios_hidpad_set_state(const struct winios_hidpad *state);
int winios_hidpad_get_state(struct winios_hidpad *out);
void winios_hidpad_set_output(const struct winios_hidpad_output *output);
/* Copies the latest output into *out and returns 1 when its serial differs
 * from `seen`, else 0. */
int winios_hidpad_get_output(uint32_t seen, struct winios_hidpad_output *out);

/* ml2106: the other direction for XInput. XInputSetState on a host pad reaches
 * win32u's ios_gamepad_query (op 2, NtUserGamepadOp_SetVibration, in
 * build/win32u-unix/driver_ios.c), which stores the two motor speeds here;
 * `serial` advances on every change. Slots 0-3, as above. */
struct winios_gamepad_vibration {
    uint32_t serial;
    uint16_t left;                /* XINPUT_VIBRATION.wLeftMotorSpeed: the large, low-frequency motor */
    uint16_t right;               /* wRightMotorSpeed: the small, high-frequency motor */
};
void winios_gamepad_set_vibration(int index, uint16_t left, uint16_t right);
/* Copies slot `index`'s motors into *out; returns its serial (0: never set). */
uint32_t winios_gamepad_get_vibration(int index, struct winios_gamepad_vibration *out);
/* 1: the app applies XInput rumble, so XInputGetCapabilities reports motors. */
void winios_gamepad_set_rumble_caps(int on);
int winios_gamepad_rumble_caps(void);

/* ml2170: XInputGetBatteryInformation for slots 0-3, read by win32u's
 * ios_gamepad_query (op 4, NtUserGamepadOp_Battery). `type` and `level` are
 * XInput's BATTERY_TYPE_* / BATTERY_LEVEL_* values, mapped by the app from
 * GCDeviceBattery (GamepadInput.swift). `valid` 0 means nothing is published
 * (env.MADEIRA_XINPUT_BATTERY = 0, or the slot was cleared): the op then
 * answers 0 and xinput keeps its old "unknown" battery. Kept apart from the
 * input snapshot so a battery change never advances XInput's packet number. */
#define WINIOS_BATTERY_TYPE_DISCONNECTED 0x00
#define WINIOS_BATTERY_TYPE_WIRED        0x01
#define WINIOS_BATTERY_TYPE_ALKALINE     0x02
#define WINIOS_BATTERY_TYPE_NIMH         0x03
#define WINIOS_BATTERY_TYPE_UNKNOWN      0xff
#define WINIOS_BATTERY_LEVEL_EMPTY  0x00
#define WINIOS_BATTERY_LEVEL_LOW    0x01
#define WINIOS_BATTERY_LEVEL_MEDIUM 0x02
#define WINIOS_BATTERY_LEVEL_FULL   0x03
struct winios_gamepad_battery {
    uint8_t valid;
    uint8_t type;
    uint8_t level;
    uint8_t reserved;
};
/* NULL clears the slot. Returns 1 when the stored value changed. */
int winios_gamepad_set_battery(int index, const struct winios_gamepad_battery *battery);
/* Copies slot `index`'s battery into *out (zeros when invalid); returns `valid`. */
int winios_gamepad_get_battery(int index, struct winios_gamepad_battery *out);

/* ml2106: called after winios_hidpad_set_output or winios_gamepad_set_vibration
 * changed something, outside every lock, on the writer's thread (the
 * wineserver's, or a game thread in win32u). The app's handler only schedules
 * work on its main thread. NULL unregisters. */
typedef void (*winios_pad_output_notify_fn)(void);
void winios_pad_output_set_notify(winios_pad_output_notify_fn fn);
#ifdef __cplusplus
}
#endif
#endif
