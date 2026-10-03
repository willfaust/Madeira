/*
 * ml2101: the HID controller's report descriptors and reports.
 *
 * GPL-3.0-or-later WITH the Madeira Converter Exception, version 1; see
 * LICENSE-EXCEPTION.md.
 *
 * Pure C over the app's snapshot (struct winios_hidpad, WiniosGamepad.h): the
 * wineserver device (build/wineserver/hidpad_ios.c) builds every report with
 * these functions, and tests/host/check-hidpad.py runs them through
 * Wine's own hidparse.sys and hid.dll parsers on the host.
 *
 * DualSense layout: the USB descriptor is the controller's own, byte for byte
 * (273 bytes, CFI-ZCT1W, as dumped in github.com/nondebug/dualsense,
 * report-descriptor-usb.txt). The input/output report fields follow Linux's
 * hid-playstation.c (struct dualsense_input_report / _output_report_common)
 * and SDL's SDL_hidapi_ps5.c (DS5EffectsState_t), which agree.
 *
 * Generic layout: the object set Windows gives an Xbox controller's HID view
 * and the opt-in DirectInput pad (wine/dlls/dinput/joystick_ios.c): X/Y left
 * stick, Rx/Ry right stick, Z = left trigger - right trigger (so it rests at
 * the centre; see ios_logical_triggers there), an 8-way hat, A B X Y LB RB
 * Back Start L3 R3 Guide. Y axes grow downwards, as HID and DirectInput expect.
 */
#ifndef MADEIRA_HIDPAD_REPORTS_H
#define MADEIRA_HIDPAD_REPORTS_H

#include <stdint.h>
#include <string.h>
#include "hidpad_ids.h"
#include "../../app/Madeira/Winios/WiniosGamepad.h"

/* XINPUT_GAMEPAD_* (the low half of winios_hidpad.buttons). */
#define HIDPAD_XI_DPAD_UP    0x0001
#define HIDPAD_XI_DPAD_DOWN  0x0002
#define HIDPAD_XI_DPAD_LEFT  0x0004
#define HIDPAD_XI_DPAD_RIGHT 0x0008
#define HIDPAD_XI_START      0x0010
#define HIDPAD_XI_BACK       0x0020
#define HIDPAD_XI_LTHUMB     0x0040
#define HIDPAD_XI_RTHUMB     0x0080
#define HIDPAD_XI_LSHOULDER  0x0100
#define HIDPAD_XI_RSHOULDER  0x0200
#define HIDPAD_XI_GUIDE      0x0400
#define HIDPAD_XI_A          0x1000
#define HIDPAD_XI_B          0x2000
#define HIDPAD_XI_X          0x4000
#define HIDPAD_XI_Y          0x8000

static const unsigned char hidpad_dualsense_descriptor[] =
{
    0x05, 0x01,             /* Usage Page (Generic Desktop) */
    0x09, 0x05,             /* Usage (Game Pad) */
    0xA1, 0x01,             /* Collection (Application) */
    0x85, 0x01,             /* Report ID (0x01) */
    0x09, 0x30,             /* Usage (X) */
    0x09, 0x31,             /* Usage (Y) */
    0x09, 0x32,             /* Usage (Z) */
    0x09, 0x35,             /* Usage (Rz) */
    0x09, 0x33,             /* Usage (Rx) */
    0x09, 0x34,             /* Usage (Ry) */
    0x15, 0x00,             /* Logical Minimum (0) */
    0x26, 0xFF, 0x00,       /* Logical Maximum (255) */
    0x75, 0x08,             /* Report Size (8) */
    0x95, 0x06,             /* Report Count (6) */
    0x81, 0x02,             /* Input (Data,Var,Abs) */
    0x06, 0x00, 0xFF,       /* Usage Page (Vendor Defined 0xFF00) */
    0x09, 0x20,             /* Usage (0x20) */
    0x95, 0x01,             /* Report Count (1) */
    0x81, 0x02,             /* Input (Data,Var,Abs) */
    0x05, 0x01,             /* Usage Page (Generic Desktop) */
    0x09, 0x39,             /* Usage (Hat switch) */
    0x15, 0x00,             /* Logical Minimum (0) */
    0x25, 0x07,             /* Logical Maximum (7) */
    0x35, 0x00,             /* Physical Minimum (0) */
    0x46, 0x3B, 0x01,       /* Physical Maximum (315) */
    0x65, 0x14,             /* Unit (English Rotation: degrees) */
    0x75, 0x04,             /* Report Size (4) */
    0x95, 0x01,             /* Report Count (1) */
    0x81, 0x42,             /* Input (Data,Var,Abs,Null) */
    0x65, 0x00,             /* Unit (None) */
    0x05, 0x09,             /* Usage Page (Button) */
    0x19, 0x01,             /* Usage Minimum (0x01) */
    0x29, 0x0F,             /* Usage Maximum (0x0F) */
    0x15, 0x00,             /* Logical Minimum (0) */
    0x25, 0x01,             /* Logical Maximum (1) */
    0x75, 0x01,             /* Report Size (1) */
    0x95, 0x0F,             /* Report Count (15) */
    0x81, 0x02,             /* Input (Data,Var,Abs) */
    0x06, 0x00, 0xFF,       /* Usage Page (Vendor Defined 0xFF00) */
    0x09, 0x21,             /* Usage (0x21) */
    0x95, 0x0D,             /* Report Count (13) */
    0x81, 0x02,             /* Input (Data,Var,Abs) */
    0x06, 0x00, 0xFF,       /* Usage Page (Vendor Defined 0xFF00) */
    0x09, 0x22,             /* Usage (0x22) */
    0x15, 0x00,             /* Logical Minimum (0) */
    0x26, 0xFF, 0x00,       /* Logical Maximum (255) */
    0x75, 0x08,             /* Report Size (8) */
    0x95, 0x34,             /* Report Count (52) */
    0x81, 0x02,             /* Input (Data,Var,Abs) */
    0x85, 0x02,             /* Report ID (0x02) */
    0x09, 0x23,             /* Usage (0x23) */
    0x95, 0x2F,             /* Report Count (47) */
    0x91, 0x02,             /* Output (Data,Var,Abs) */
    0x85, 0x05,             /* Report ID (0x05) */
    0x09, 0x33,             /* Usage (0x33) */
    0x95, 0x28,             /* Report Count (40) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x08,             /* Report ID (0x08) */
    0x09, 0x34,             /* Usage (0x34) */
    0x95, 0x2F,             /* Report Count (47) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x09,             /* Report ID (0x09) */
    0x09, 0x24,             /* Usage (0x24) */
    0x95, 0x13,             /* Report Count (19) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x0A,             /* Report ID (0x0A) */
    0x09, 0x25,             /* Usage (0x25) */
    0x95, 0x1A,             /* Report Count (26) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x20,             /* Report ID (0x20) */
    0x09, 0x26,             /* Usage (0x26) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x21,             /* Report ID (0x21) */
    0x09, 0x27,             /* Usage (0x27) */
    0x95, 0x04,             /* Report Count (4) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x22,             /* Report ID (0x22) */
    0x09, 0x40,             /* Usage (0x40) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x80,             /* Report ID (0x80) */
    0x09, 0x28,             /* Usage (0x28) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x81,             /* Report ID (0x81) */
    0x09, 0x29,             /* Usage (0x29) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x82,             /* Report ID (0x82) */
    0x09, 0x2A,             /* Usage (0x2A) */
    0x95, 0x09,             /* Report Count (9) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x83,             /* Report ID (0x83) */
    0x09, 0x2B,             /* Usage (0x2B) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x84,             /* Report ID (0x84) */
    0x09, 0x2C,             /* Usage (0x2C) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0x85,             /* Report ID (0x85) */
    0x09, 0x2D,             /* Usage (0x2D) */
    0x95, 0x02,             /* Report Count (2) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xA0,             /* Report ID (0xA0) */
    0x09, 0x2E,             /* Usage (0x2E) */
    0x95, 0x01,             /* Report Count (1) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xE0,             /* Report ID (0xE0) */
    0x09, 0x2F,             /* Usage (0x2F) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xF0,             /* Report ID (0xF0) */
    0x09, 0x30,             /* Usage (0x30) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xF1,             /* Report ID (0xF1) */
    0x09, 0x31,             /* Usage (0x31) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xF2,             /* Report ID (0xF2) */
    0x09, 0x32,             /* Usage (0x32) */
    0x95, 0x0F,             /* Report Count (15) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xF4,             /* Report ID (0xF4) */
    0x09, 0x35,             /* Usage (0x35) */
    0x95, 0x3F,             /* Report Count (63) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0x85, 0xF5,             /* Report ID (0xF5) */
    0x09, 0x36,             /* Usage (0x36) */
    0x95, 0x03,             /* Report Count (3) */
    0xB1, 0x02,             /* Feature (Data,Var,Abs) */
    0xC0,                   /* End Collection */
};

static const unsigned char hidpad_generic_descriptor[] =
{
    0x05, 0x01,             /* Usage Page (Generic Desktop) */
    0x09, 0x05,             /* Usage (Game Pad) */
    0xA1, 0x01,             /* Collection (Application) */
    0x85, 0x01,             /*   Report ID (0x01) */
    0x09, 0x01,             /*   Usage (Pointer) */
    0xA1, 0x00,             /*   Collection (Physical) */
    0x09, 0x30,             /*     Usage (X) */
    0x09, 0x31,             /*     Usage (Y) */
    0x16, 0x00, 0x80,       /*     Logical Minimum (-32768) */
    0x26, 0xFF, 0x7F,       /*     Logical Maximum (32767) */
    0x75, 0x10,             /*     Report Size (16) */
    0x95, 0x02,             /*     Report Count (2) */
    0x81, 0x02,             /*     Input (Data,Var,Abs) */
    0xC0,                   /*   End Collection */
    0x09, 0x01,             /*   Usage (Pointer) */
    0xA1, 0x00,             /*   Collection (Physical) */
    0x09, 0x33,             /*     Usage (Rx) */
    0x09, 0x34,             /*     Usage (Ry) */
    0x81, 0x02,             /*     Input (Data,Var,Abs) */
    0xC0,                   /*   End Collection */
    0x09, 0x32,             /*   Usage (Z): left - right trigger */
    0x95, 0x01,             /*   Report Count (1) */
    0x81, 0x02,             /*   Input (Data,Var,Abs) */
    0x09, 0x39,             /*   Usage (Hat switch) */
    0x15, 0x01,             /*   Logical Minimum (1) */
    0x25, 0x08,             /*   Logical Maximum (8) */
    0x35, 0x00,             /*   Physical Minimum (0) */
    0x46, 0x3B, 0x01,       /*   Physical Maximum (315) */
    0x65, 0x14,             /*   Unit (English Rotation: degrees) */
    0x75, 0x04,             /*   Report Size (4) */
    0x95, 0x01,             /*   Report Count (1) */
    0x81, 0x42,             /*   Input (Data,Var,Abs,Null) */
    0x65, 0x00,             /*   Unit (None) */
    0x45, 0x00,             /*   Physical Maximum (0) */
    0x81, 0x03,             /*   Input (Const,Var,Abs): 4 bits of padding */
    0x05, 0x09,             /*   Usage Page (Button) */
    0x19, 0x01,             /*   Usage Minimum (1) */
    0x29, 0x0B,             /*   Usage Maximum (11) */
    0x15, 0x00,             /*   Logical Minimum (0) */
    0x25, 0x01,             /*   Logical Maximum (1) */
    0x75, 0x01,             /*   Report Size (1) */
    0x95, 0x0B,             /*   Report Count (11) */
    0x81, 0x02,             /*   Input (Data,Var,Abs) */
    0x95, 0x05,             /*   Report Count (5) */
    0x81, 0x03,             /*   Input (Const,Var,Abs): padding */
    0xC0,                   /* End Collection */
};

static inline const unsigned char *hidpad_descriptor( const struct hidpad_identity *id, unsigned int *size )
{
    if (id->kind == HIDPAD_KIND_DUALSENSE)
    {
        *size = sizeof(hidpad_dualsense_descriptor);
        return hidpad_dualsense_descriptor;
    }
    *size = sizeof(hidpad_generic_descriptor);
    return hidpad_generic_descriptor;
}

#define HIDPAD_DUALSENSE_INPUT_LEN 64
#define HIDPAD_GENERIC_INPUT_LEN   14

/* Per-device state the reports carry from one to the next. */
struct hidpad_report_state
{
    unsigned char seq;              /* DualSense report counter */
    unsigned char touch_id[2];      /* DualSense finger ids, new per touch */
    unsigned char touching[2];
};

static inline void hidpad_put16( unsigned char *p, unsigned int v )
{
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
}

static inline void hidpad_put32( unsigned char *p, uint32_t v )
{
    hidpad_put16( p, v & 0xffff );
    hidpad_put16( p + 2, v >> 16 );
}

/* Y grows downwards in HID; the snapshot's grows upwards (XInput). */
static inline int hidpad_flip( int16_t v )
{
    return v == -32768 ? 32767 : -v;
}

/* -32768..32767 to the DualSense's 0..255, centre 128. */
static inline unsigned char hidpad_u8( int v )
{
    return (unsigned char)((v + 32768) >> 8);
}

/* The d-pad as a hat: 0..7 clockwise from north, -1 centred. Opposite
 * directions held together cancel, as on the pad itself. */
static inline int hidpad_hat( uint32_t buttons )
{
    static const signed char table[3][3] =
    {
        { 5, 4, 3 },    /* down:  SW  S  SE */
        { 6, -1, 2 },   /*        W   -  E  */
        { 7, 0, 1 },    /* up:    NW  N  NE */
    };
    int y = !!(buttons & HIDPAD_XI_DPAD_UP) - !!(buttons & HIDPAD_XI_DPAD_DOWN);
    int x = !!(buttons & HIDPAD_XI_DPAD_RIGHT) - !!(buttons & HIDPAD_XI_DPAD_LEFT);
    return table[y + 1][x + 1];
}

/* USB input report 0x01, 64 bytes. `now_us` feeds the sensor clock (units of
 * 1/3 microsecond, hid-playstation.c). A disconnected snapshot is the pad at
 * rest, lying flat. */
static inline unsigned int hidpad_dualsense_input( const struct winios_hidpad *pad, struct hidpad_report_state *st,
                                                   uint64_t now_us, unsigned char *r )
{
    static const unsigned char face[][2] =
    {
        { HIDPAD_XI_X >> 8, 0x10 }, { HIDPAD_XI_A >> 8, 0x20 },
        { HIDPAD_XI_B >> 8, 0x40 }, { HIDPAD_XI_Y >> 8, 0x80 },
    };
    uint32_t b = pad->connected ? pad->buttons : 0;
    unsigned int i;
    int hat = hidpad_hat( b );

    memset( r, 0, HIDPAD_DUALSENSE_INPUT_LEN );
    r[0] = 0x01;
    r[1] = pad->connected ? hidpad_u8( pad->lx ) : 0x80;
    r[2] = pad->connected ? hidpad_u8( hidpad_flip( pad->ly ) ) : 0x80;
    r[3] = pad->connected ? hidpad_u8( pad->rx ) : 0x80;
    r[4] = pad->connected ? hidpad_u8( hidpad_flip( pad->ry ) ) : 0x80;
    r[5] = pad->connected ? pad->left_trigger : 0;
    r[6] = pad->connected ? pad->right_trigger : 0;
    r[7] = st->seq++;
    r[8] = hat < 0 ? 8 : hat;
    for (i = 0; i < sizeof(face) / sizeof(face[0]); i++)
        if ((b >> 8) & face[i][0]) r[8] |= face[i][1];
    if (b & HIDPAD_XI_LSHOULDER) r[9] |= 0x01;
    if (b & HIDPAD_XI_RSHOULDER) r[9] |= 0x02;
    if (b & WINIOS_HIDPAD_L2) r[9] |= 0x04;
    if (b & WINIOS_HIDPAD_R2) r[9] |= 0x08;
    if (b & HIDPAD_XI_BACK) r[9] |= 0x10;      /* Create */
    if (b & HIDPAD_XI_START) r[9] |= 0x20;     /* Options */
    if (b & HIDPAD_XI_LTHUMB) r[9] |= 0x40;
    if (b & HIDPAD_XI_RTHUMB) r[9] |= 0x80;
    if (b & HIDPAD_XI_GUIDE) r[10] |= 0x01;    /* PS */
    if (b & WINIOS_HIDPAD_TOUCHPAD) r[10] |= 0x02;
    if (b & WINIOS_HIDPAD_MUTE) r[10] |= 0x04;

    if (pad->connected && pad->motion)
    {
        for (i = 0; i < 3; i++) hidpad_put16( r + 16 + 2 * i, (uint16_t)pad->gyro[i] );
        for (i = 0; i < 3; i++) hidpad_put16( r + 22 + 2 * i, (uint16_t)pad->accel[i] );
    }
    else hidpad_put16( r + 24, 8192 );         /* 1 g on Y: flat, face up */
    hidpad_put32( r + 28, (uint32_t)(now_us * 3) );

    for (i = 0; i < 2; i++)
    {
        unsigned char *p = r + 33 + 4 * i;
        int down = pad->connected && pad->touch[i];
        unsigned int x = down ? pad->touch_x[i] : 0, y = down ? pad->touch_y[i] : 0;

        if (down && !st->touching[i]) st->touch_id[i] = (st->touch_id[i] + 1) & 0x7f;
        st->touching[i] = down;
        if (x > 1919) x = 1919;
        if (y > 1079) y = 1079;
        p[0] = st->touch_id[i] | (down ? 0 : 0x80);
        p[1] = x & 0xff;
        p[2] = ((x >> 8) & 0x0f) | ((y & 0x0f) << 4);
        p[3] = y >> 4;
    }

    /* Battery: level 0-10 in the low nibble, 0 discharging / 1 charging /
     * 2 full above it. Unknown reads as a full pad, as a wired one would. */
    if (pad->connected && pad->battery != WINIOS_HIDPAD_BATTERY_UNKNOWN)
    {
        unsigned int level = pad->battery >= 100 ? 10 : pad->battery / 10;
        r[53] = level | ((pad->charging > 2 ? 0 : pad->charging) << 4);
    }
    else r[53] = 0x2a;
    return HIDPAD_DUALSENSE_INPUT_LEN;
}

/* Generic input report 0x01, 14 bytes: X Y Rx Ry Z (16-bit), hat, buttons. */
static inline unsigned int hidpad_generic_input( const struct winios_hidpad *pad, unsigned char *r )
{
    static const uint32_t order[] =
    {
        HIDPAD_XI_A, HIDPAD_XI_B, HIDPAD_XI_X, HIDPAD_XI_Y, HIDPAD_XI_LSHOULDER, HIDPAD_XI_RSHOULDER,
        HIDPAD_XI_BACK, HIDPAD_XI_START, HIDPAD_XI_LTHUMB, HIDPAD_XI_RTHUMB, HIDPAD_XI_GUIDE,
    };
    uint32_t b = pad->connected ? pad->buttons : 0;
    unsigned int i, mask = 0;
    int hat = hidpad_hat( b );

    memset( r, 0, HIDPAD_GENERIC_INPUT_LEN );
    r[0] = 0x01;
    if (pad->connected)
    {
        hidpad_put16( r + 1, (uint16_t)pad->lx );
        hidpad_put16( r + 3, (uint16_t)hidpad_flip( pad->ly ) );
        hidpad_put16( r + 5, (uint16_t)pad->rx );
        hidpad_put16( r + 7, (uint16_t)hidpad_flip( pad->ry ) );
        hidpad_put16( r + 9, (uint16_t)(((int)pad->left_trigger - (int)pad->right_trigger) * 128) );
    }
    r[11] = hat < 0 ? 0 : hat + 1;
    for (i = 0; i < sizeof(order) / sizeof(order[0]); i++)
        if (b & order[i]) mask |= 1u << i;
    hidpad_put16( r + 12, mask );
    return HIDPAD_GENERIC_INPUT_LEN;
}

static inline unsigned int hidpad_input_report( const struct hidpad_identity *id, const struct winios_hidpad *pad,
                                                struct hidpad_report_state *st, uint64_t now_us,
                                                unsigned char *buf )
{
    if (id->kind == HIDPAD_KIND_DUALSENSE) return hidpad_dualsense_input( pad, st, now_us, buf );
    return hidpad_generic_input( pad, buf );
}

/* DualSense feature reports. `len` is the report's length from the descriptor
 * (ID included); IDs this file has no content for read back as zeros, which is
 * what a pad does for most of its factory and test reports.
 *
 *  0x05 calibration: zero bias, 540 deg/s reads 8640 (16 units per deg/s) and
 *       +-1 g reads +-8192 on every axis -- the units winios_hidpad.gyro/accel
 *       use, so the reader's normalisation is exact.
 *  0x09 pairing info: the "Bluetooth address", reversed, as SDL and Linux read
 *       it for the serial number; 02:a1:4d:61:64:65 (locally administered).
 *  0x20 firmware info: a build date/time, and update version 0x0224 at
 *       [44..45] (2.24, the firmware SDL needs for its improved rumble). */
static inline int hidpad_dualsense_feature( unsigned char report_id, unsigned char *buf, unsigned int len )
{
    static const short calibration[] =
    {
        0, 0, 0,                        /* gyro pitch/yaw/roll bias */
        8640, -8640, 8640, -8640, 8640, -8640,
        540, 540,                       /* gyro speed plus/minus (deg/s) */
        8192, -8192, 8192, -8192, 8192, -8192,
    };
    static const unsigned char mac[6] = { 0x65, 0x64, 0x61, 0x4d, 0xa1, 0x02 };
    unsigned int i;

    if (!len) return 0;
    memset( buf, 0, len );
    buf[0] = report_id;
    switch (report_id)
    {
    case 0x05:
        for (i = 0; i < sizeof(calibration) / sizeof(calibration[0]) && 1 + 2 * i + 1 < len; i++)
            hidpad_put16( buf + 1 + 2 * i, (uint16_t)calibration[i] );
        break;
    case 0x09:
        if (len >= 7) memcpy( buf + 1, mac, sizeof(mac) );
        break;
    case 0x20:
        if (len >= 46)
        {
            memcpy( buf + 1, "Jun 19 2023", 11 );
            memcpy( buf + 12, "14:47:34", 8 );
            hidpad_put32( buf + 24, 0x00000613 );   /* hardware info */
            hidpad_put32( buf + 28, 0x01060003 );   /* main firmware version */
            hidpad_put16( buf + 44, 0x0224 );       /* update version */
        }
        break;
    }
    return 1;
}

#endif
