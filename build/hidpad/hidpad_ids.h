/*
 * ml2100: who the opt-in HID controller says it is.
 *
 * GPL-3.0-or-later WITH the Madeira Converter Exception, version 1; see
 * LICENSE-EXCEPTION.md.
 *
 * With `env.MADEIRA_PAD_MODE = hid` in madeira.cfg, player 1's controller
 * reaches Windows as a HID game controller instead of an XInput pad: a
 * DualSense (Sony 054C:0CE6, so Sony's libScePad and anything matching Sony's
 * IDs sees a PlayStation pad) or a generic HID gamepad. The app decides
 * which at session start (GamepadInput.swift) and exports it as
 * MADEIRA_HIDPAD=dualsense|generic before the wineserver starts. Two places
 * read it:
 *
 *   build/wineserver/hidpad_ios.c   the device object, its reads and IOCTLs
 *   build/ntdll-unix/server_ios.c   the registry entries setupapi enumerates
 *
 * and both take every name from this table, so the device path hid.dll opens
 * and the one the registry advertises cannot drift apart.
 *
 * The DualSense is the USB one: interface 3 of the composite device (MI_03),
 * input report 0x01 (64 bytes), output report 0x02 (48 bytes). USB needs no
 * CRC and no Bluetooth mode switch, and every PC title that supports the pad
 * supports it wired.
 */
#ifndef MADEIRA_HIDPAD_IDS_H
#define MADEIRA_HIDPAD_IDS_H

#include <string.h>

#define HIDPAD_KIND_NONE      0
#define HIDPAD_KIND_DUALSENSE 1
#define HIDPAD_KIND_GENERIC   2

/* GUID_DEVINTERFACE_HID, lower case as setupapi writes it. */
#define HIDPAD_HID_INTERFACE_GUID "{4d1e55b2-f16f-11cf-88cb-001111000030}"
/* GUID_DEVCLASS_HIDCLASS. */
#define HIDPAD_HIDCLASS_GUID      "{745a17a0-74d3-11d0-b6fe-00a0c90f57da}"

/* \Device\<name>, the object the wineserver creates. */
#define HIDPAD_NT_DEVICE "\\Device\\MadeiraHidPad0"

/* hid.dll's IOCTL_HID_GET_WINE_RAWINPUT_HANDLE answer. hidclass hands out 3,
 * 4, ... (1 and 2 are Wine's virtual mouse and keyboard); there is no hidclass
 * here, so any value above 2 is free. dinput's HID joystick refuses a device
 * without one, and derives the instance GUID from it, so it must be stable. */
#define HIDPAD_RAWINPUT_HANDLE 0x4d50

struct hidpad_identity
{
    int kind;
    const char *env;            /* MADEIRA_HIDPAD value */
    unsigned short vid, pid, version;
    const char *device_id;      /* HID\VID_xxxx&PID_xxxx[&MI_xx] */
    const char *instance;       /* instance part of the device instance ID */
    const char *hardware_ids[6];
    const char *container_id;
    const char *manufacturer;
    const char *product;
    const char *serial;
};

static const struct hidpad_identity hidpad_identities[] =
{
    {
        HIDPAD_KIND_DUALSENSE, "dualsense", 0x054c, 0x0ce6, 0x0100,
        "HID\\VID_054C&PID_0CE6&MI_03", "9&4d616465&0&0000",
        { "HID\\VID_054C&PID_0CE6&REV_0100&MI_03", "HID\\VID_054C&PID_0CE6&MI_03",
          "HID\\VID_054C&UP:0001_U:0005", "HID_DEVICE_SYSTEM_GAME", "HID_DEVICE_UP:0001_U:0005",
          "HID_DEVICE" },
        "{4d616465-6972-6148-4944-505330000001}",
        /* The USB string descriptors of a CFI-ZCT1W ("Sony Interactive
         * Entertainment DualSense Wireless Controller" in Linux's hidraw
         * line); "Wireless Controller" alone is the DualShock 4's product. */
        "Sony Interactive Entertainment", "DualSense Wireless Controller", "02a14d616465",
    },
    {
        /* pid.codes (no USB-IF membership needed); the same IDs as the opt-in
         * DirectInput pad in wine/dlls/dinput/joystick_ios.c, which is the
         * same virtual controller seen through another API. Not 045E: a family
         * of DirectInput games skips Microsoft's vendor ID as "already XInput". */
        HIDPAD_KIND_GENERIC, "generic", 0x1209, 0x4d47, 0x0100,
        "HID\\VID_1209&PID_4D47", "9&4d616465&0&0000",
        { "HID\\VID_1209&PID_4D47&REV_0100", "HID\\VID_1209&PID_4D47",
          "HID\\VID_1209&UP:0001_U:0005", "HID_DEVICE_SYSTEM_GAME", "HID_DEVICE_UP:0001_U:0005",
          "HID_DEVICE" },
        "{4d616465-6972-6148-4944-47454e000001}",
        "Madeira", "Madeira Gamepad", "",
    },
};

/* The identity MADEIRA_HIDPAD names, or NULL (XInput mode, or a value this
 * build does not know). */
static inline const struct hidpad_identity *hidpad_identity_from_env( const char *value )
{
    unsigned int i;

    if (!value || !value[0]) return NULL;
    for (i = 0; i < sizeof(hidpad_identities) / sizeof(hidpad_identities[0]); i++)
        if (!strcmp( value, hidpad_identities[i].env )) return &hidpad_identities[i];
    return NULL;
}

/* "HID#VID_054C&PID_0CE6&MI_03#9&4d616465&0&0000#{4d1e55b2-...}": the device
 * instance ID with '\' turned into '#', then the interface class, as setupapi
 * and hidclass build it. Prefixed with "\\?\" it is the path hid.dll's callers
 * open; with "\??\" the wineserver symlink; with "##?#" the registry key name. */
static inline void hidpad_interface_link( const struct hidpad_identity *id, char *buf, unsigned int size )
{
    unsigned int i, len = 0;
    const char *parts[] = { id->device_id, "\\", id->instance, "\\", HIDPAD_HID_INTERFACE_GUID };

    for (i = 0; i < sizeof(parts) / sizeof(parts[0]); i++)
    {
        const char *p;
        for (p = parts[i]; *p && len + 1 < size; p++) buf[len++] = *p == '\\' ? '#' : *p;
    }
    if (size) buf[len] = 0;
}

#endif
