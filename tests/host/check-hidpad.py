#!/usr/bin/env python3
"""ml2100/ml2101: the opt-in HID controller, checked on a POSIX host.

Compiles the production descriptors and report builders (build/hidpad), the
wrapper the wineserver uses around Wine's hidparse.sys parser, Wine's own
hid.dll HidP_* code (dlls/hid/hidp.c) and the app's snapshot transport
(WiniosGamepad.c), then reads every report back the way a game's hid.dll
would: HidP_GetCaps, HidP_GetUsageValue, HidP_GetUsages.

Needs the wine submodule (WINE_SRC overrides its location) and a C compiler
(CC). No Wine build, device, SDK or controller.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
wine = Path(os.environ.get('WINE_SRC', root / 'wine'))
if not (wine / 'dlls/hidparse.sys/main.c').exists():
    raise SystemExit(f'SKIP: no Wine tree at {wine} (set WINE_SRC)')

test = r'''
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "winioctl.h"
#include "hidusage.h"
#include "ddk/hidpi.h"
#include "wine/hid.h"
#include "wine/debug.h"
#include "hidparse_ios.h"
#include "hidpad_reports.h"

/* What hidp.c needs from kernel32 and ntdll; the debug channel stays silent. */
int __cdecl __wine_dbg_header( enum __wine_debug_class cls, struct __wine_debug_channel *channel,
                               const char *function ) { return -1; }
int __cdecl __wine_dbg_output( const char *str ) { return 0; }
INT WINAPI MulDiv( INT a, INT b, INT c )
{
    LONGLONG r = (LONGLONG)a * b;
    if (!c) return -1;
    if ((r < 0) == (c < 0)) r += c / 2; else r -= c / 2;
    return r / c;
}

struct parsed
{
    void *pre;
    unsigned int size;
    unsigned short in[256], out[256], feat[256];
};

static void parse( const struct hidpad_identity *id, struct parsed *p )
{
    unsigned int len;
    const unsigned char *desc = hidpad_descriptor( id, &len );
    p->pre = madeira_hidparse_preparse( desc, len, &p->size, p->in, p->out, p->feat );
    assert( p->pre && p->size > sizeof(struct hid_preparsed_data) );
    assert( !memcmp( ((struct hid_preparsed_data *)p->pre)->magic, "HidP KDR", 8 ) );
}

static ULONG value( struct parsed *p, USAGE page, USAGE usage, unsigned char *r, unsigned int len )
{
    ULONG v = 0xdeadbeef;
    NTSTATUS s = HidP_GetUsageValue( HidP_Input, page, 0, usage, &v, p->pre, (char *)r, len );
    assert( s == HIDP_STATUS_SUCCESS );
    return v;
}

static LONG scaled( struct parsed *p, USAGE usage, unsigned char *r, unsigned int len )
{
    LONG v = 0x7eadbeef;
    NTSTATUS s = HidP_GetScaledUsageValue( HidP_Input, HID_USAGE_PAGE_GENERIC, 0, usage, &v, p->pre, (char *)r, len );
    assert( s == HIDP_STATUS_SUCCESS );
    return v;
}

/* Bitmask of pressed button usages (1-based). */
static unsigned int buttons( struct parsed *p, unsigned char *r, unsigned int len )
{
    USAGE list[32];
    ULONG n = 32, i;
    unsigned int mask = 0;
    assert( HidP_GetUsages( HidP_Input, HID_USAGE_PAGE_BUTTON, 0, list, &n, p->pre, (char *)r, len ) == HIDP_STATUS_SUCCESS );
    for (i = 0; i < n; i++) { assert( list[i] >= 1 && list[i] <= 32 ); mask |= 1u << (list[i] - 1); }
    return mask;
}

static void check_ids( void )
{
    char link[256];
    const struct hidpad_identity *ds = hidpad_identity_from_env( "dualsense" );
    const struct hidpad_identity *gen = hidpad_identity_from_env( "generic" );
    assert( ds && ds->kind == HIDPAD_KIND_DUALSENSE && ds->vid == 0x054c && ds->pid == 0x0ce6 );
    assert( gen && gen->kind == HIDPAD_KIND_GENERIC && gen->vid == 0x1209 );
    assert( !hidpad_identity_from_env( NULL ) && !hidpad_identity_from_env( "" ) );
    assert( !hidpad_identity_from_env( "xinput" ) && !hidpad_identity_from_env( "DualSense " ) );
    hidpad_interface_link( ds, link, sizeof(link) );
    assert( !strcmp( link, "HID#VID_054C&PID_0CE6&MI_03#9&4d616465&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}" ) );
    hidpad_interface_link( ds, link, 8 );
    assert( strlen( link ) == 7 );
}

static void check_dualsense( void )
{
    const struct hidpad_identity *id = hidpad_identity_from_env( "dualsense" );
    struct hidpad_report_state st = {0};
    struct winios_hidpad pad = {0};
    struct parsed p;
    HIDP_CAPS caps;
    unsigned char r[64], f[64];
    unsigned int len, i;

    parse( id, &p );
    assert( HidP_GetCaps( p.pre, &caps ) == HIDP_STATUS_SUCCESS );
    assert( caps.UsagePage == HID_USAGE_PAGE_GENERIC && caps.Usage == HID_USAGE_GENERIC_GAMEPAD );
    assert( caps.InputReportByteLength == 64 && caps.OutputReportByteLength == 48 );
    assert( caps.FeatureReportByteLength == 64 );
    assert( p.in[1] == 64 && p.out[2] == 48 );
    assert( p.feat[0x05] == 41 && p.feat[0x09] == 20 && p.feat[0x20] == 64 && p.feat[0xf5] == 4 );
    assert( !p.in[2] && !p.feat[1] && !p.feat[0x03] );

    /* At rest, disconnected: centred sticks, no hat, nothing pressed, flat. */
    len = hidpad_input_report( id, &pad, &st, 1000, r );
    assert( len == 64 && r[0] == 1 && r[7] == 0 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_X, r, len ) == 128 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_RY, r, len ) == 0 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_HATSWITCH, r, len ) == 8 );
    assert( buttons( &p, r, len ) == 0 );
    assert( r[24] == 0x00 && r[25] == 0x20 && r[53] == 0x2a );
    assert( r[33] & 0x80 && r[37] & 0x80 );

    /* Sticks: XInput +y up becomes HID +y down; X, Y, Z, Rz are LX LY RX RY,
     * Rx and Ry are L2 and R2 (the descriptor's own order). */
    pad.connected = 1;
    pad.battery = WINIOS_HIDPAD_BATTERY_UNKNOWN;
    pad.lx = 32767; pad.ly = 32767; pad.rx = -32768; pad.ry = -32768;
    pad.left_trigger = 200; pad.right_trigger = 17;
    len = hidpad_input_report( id, &pad, &st, 2000, r );
    assert( r[7] == 1 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_X, r, len ) == 255 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_Y, r, len ) == 0 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_Z, r, len ) == 0 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_RZ, r, len ) == 255 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_RX, r, len ) == 200 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_RY, r, len ) == 17 );
    pad.lx = pad.ly = pad.rx = pad.ry = 0;
    len = hidpad_input_report( id, &pad, &st, 2000, r );
    for (i = 1; i <= 4; i++) assert( r[i] == 128 );

    /* Buttons, in the DirectInput order Windows shows for a DualSense:
     * 1 square 2 cross 3 circle 4 triangle 5 L1 6 R1 7 L2 8 R2 9 create
     * 10 options 11 L3 12 R3 13 PS 14 touchpad 15 mute. */
    {
        static const struct { uint32_t in; unsigned int usage; } map[] =
        {
            { HIDPAD_XI_X, 1 }, { HIDPAD_XI_A, 2 }, { HIDPAD_XI_B, 3 }, { HIDPAD_XI_Y, 4 },
            { HIDPAD_XI_LSHOULDER, 5 }, { HIDPAD_XI_RSHOULDER, 6 }, { WINIOS_HIDPAD_L2, 7 },
            { WINIOS_HIDPAD_R2, 8 }, { HIDPAD_XI_BACK, 9 }, { HIDPAD_XI_START, 10 },
            { HIDPAD_XI_LTHUMB, 11 }, { HIDPAD_XI_RTHUMB, 12 }, { HIDPAD_XI_GUIDE, 13 },
            { WINIOS_HIDPAD_TOUCHPAD, 14 }, { WINIOS_HIDPAD_MUTE, 15 },
        };
        unsigned int all = 0;
        for (i = 0; i < sizeof(map) / sizeof(map[0]); i++)
        {
            pad.buttons = map[i].in;
            len = hidpad_input_report( id, &pad, &st, 3000, r );
            assert( buttons( &p, r, len ) == 1u << (map[i].usage - 1) );
            assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_HATSWITCH, r, len ) == 8 );
            all |= map[i].in;
        }
        pad.buttons = all;
        len = hidpad_input_report( id, &pad, &st, 3000, r );
        assert( buttons( &p, r, len ) == 0x7fff );
    }

    /* D-pad as the hat: 0 north, clockwise; opposite directions cancel. */
    {
        static const struct { uint32_t in; ULONG hat; } hats[] =
        {
            { HIDPAD_XI_DPAD_UP, 0 }, { HIDPAD_XI_DPAD_UP | HIDPAD_XI_DPAD_RIGHT, 1 },
            { HIDPAD_XI_DPAD_RIGHT, 2 }, { HIDPAD_XI_DPAD_DOWN | HIDPAD_XI_DPAD_RIGHT, 3 },
            { HIDPAD_XI_DPAD_DOWN, 4 }, { HIDPAD_XI_DPAD_DOWN | HIDPAD_XI_DPAD_LEFT, 5 },
            { HIDPAD_XI_DPAD_LEFT, 6 }, { HIDPAD_XI_DPAD_UP | HIDPAD_XI_DPAD_LEFT, 7 },
            { HIDPAD_XI_DPAD_UP | HIDPAD_XI_DPAD_DOWN, 8 },
            { HIDPAD_XI_DPAD_UP | HIDPAD_XI_DPAD_DOWN | HIDPAD_XI_DPAD_LEFT, 6 },
        };
        for (i = 0; i < sizeof(hats) / sizeof(hats[0]); i++)
        {
            pad.buttons = hats[i].in | HIDPAD_XI_A;
            len = hidpad_input_report( id, &pad, &st, 3000, r );
            assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_HATSWITCH, r, len ) == hats[i].hat );
            assert( buttons( &p, r, len ) == 2 );
        }
    }

    /* Touchpad points: id stable while down, new per touch; 12-bit x/y. */
    pad.buttons = 0;
    pad.touch[0] = 1; pad.touch_x[0] = 1919; pad.touch_y[0] = 1079;
    len = hidpad_input_report( id, &pad, &st, 4000, r );
    assert( r[33] == 1 && r[34] == (1919 & 0xff) && r[35] == ((1919 >> 8) | ((1079 & 0xf) << 4)) && r[36] == 1079 >> 4 );
    assert( r[37] == 0x80 );
    len = hidpad_input_report( id, &pad, &st, 4000, r );
    assert( r[33] == 1 );
    pad.touch[0] = 0;
    len = hidpad_input_report( id, &pad, &st, 4000, r );
    assert( r[33] == 0x81 );
    pad.touch[0] = 1; pad.touch_x[0] = 5000;
    len = hidpad_input_report( id, &pad, &st, 4000, r );
    assert( r[33] == 2 && (r[34] | (r[35] & 0xf) << 8) == 1919 );
    pad.touch[0] = 0;

    /* Motion and battery, sensor clock in 1/3 us. */
    pad.motion = 1;
    pad.gyro[0] = -16; pad.gyro[1] = 32767; pad.gyro[2] = 1;
    pad.accel[0] = 0; pad.accel[1] = -8192; pad.accel[2] = 4096;
    pad.battery = 45; pad.charging = 1;
    len = hidpad_input_report( id, &pad, &st, 1000000, r );
    assert( (short)(r[16] | r[17] << 8) == -16 && (short)(r[18] | r[19] << 8) == 32767 );
    assert( (short)(r[24] | r[25] << 8) == -8192 && (short)(r[26] | r[27] << 8) == 4096 );
    assert( (r[28] | r[29] << 8 | r[30] << 16 | (unsigned)r[31] << 24) == 3000000 );
    assert( r[53] == 0x14 );
    pad.battery = 100; pad.charging = 2;
    hidpad_input_report( id, &pad, &st, 0, r );
    assert( r[53] == 0x2a );

    /* Feature reports: lengths from the descriptor, calibration that SDL and
     * Linux both normalise to 16 units per deg/s and 8192 per g. */
    for (i = 0; i < 256; i++)
    {
        if (!p.feat[i]) continue;
        memset( f, 0xcc, sizeof(f) );
        assert( hidpad_dualsense_feature( i, f, p.feat[i] ) );
        assert( f[0] == i );
    }
    hidpad_dualsense_feature( 0x05, f, p.feat[0x05] );
    {
        short v[17];
        for (i = 0; i < 17; i++) v[i] = (short)(f[1 + 2 * i] | f[2 + 2 * i] << 8);
        assert( v[0] == 0 && v[1] == 0 && v[2] == 0 );
        assert( (v[9] + v[10]) * 1024 / (v[3] - v[4]) == 64 );     /* SDL: 1024 res -> 16 units per deg/s */
        assert( v[11] - v[12] == 16384 && v[11] - (v[11] - v[12]) / 2 == 0 );
    }
    hidpad_dualsense_feature( 0x09, f, p.feat[0x09] );
    assert( f[6] == 0x02 && f[5] == 0xa1 && f[1] == 0x65 );
    hidpad_dualsense_feature( 0x20, f, p.feat[0x20] );
    assert( (f[44] | f[45] << 8) == 0x0224 && !memcmp( f + 1, "Jun 19 2023", 11 ) );

    free( p.pre );
}

static void check_generic( void )
{
    const struct hidpad_identity *id = hidpad_identity_from_env( "generic" );
    struct hidpad_report_state st = {0};
    struct winios_hidpad pad = {0};
    struct parsed p;
    HIDP_CAPS caps;
    unsigned char r[64];
    unsigned int len, i;

    parse( id, &p );
    assert( HidP_GetCaps( p.pre, &caps ) == HIDP_STATUS_SUCCESS );
    assert( caps.UsagePage == HID_USAGE_PAGE_GENERIC && caps.Usage == HID_USAGE_GENERIC_GAMEPAD );
    assert( caps.InputReportByteLength == HIDPAD_GENERIC_INPUT_LEN && p.in[1] == HIDPAD_GENERIC_INPUT_LEN );
    assert( !caps.OutputReportByteLength && !caps.FeatureReportByteLength );
    assert( caps.NumberInputButtonCaps == 1 && caps.NumberInputValueCaps == 6 );

    len = hidpad_input_report( id, &pad, &st, 0, r );
    assert( len == HIDPAD_GENERIC_INPUT_LEN );
    for (i = 0; i < 5; i++)
        assert( scaled( &p, (USAGE[]){ HID_USAGE_GENERIC_X, HID_USAGE_GENERIC_Y, HID_USAGE_GENERIC_RX,
                                       HID_USAGE_GENERIC_RY, HID_USAGE_GENERIC_Z }[i], r, len ) == 0 );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_HATSWITCH, r, len ) == 0 );
    assert( buttons( &p, r, len ) == 0 );

    pad.connected = 1;
    pad.lx = -32768; pad.ly = 32767; pad.rx = 1234; pad.ry = -32768;
    pad.left_trigger = 255;
    len = hidpad_input_report( id, &pad, &st, 0, r );
    assert( scaled( &p, HID_USAGE_GENERIC_X, r, len ) == -32768 );
    assert( scaled( &p, HID_USAGE_GENERIC_Y, r, len ) == -32767 );     /* up is negative */
    assert( scaled( &p, HID_USAGE_GENERIC_RX, r, len ) == 1234 );
    assert( scaled( &p, HID_USAGE_GENERIC_RY, r, len ) == 32767 );
    assert( scaled( &p, HID_USAGE_GENERIC_Z, r, len ) == 255 * 128 );
    pad.left_trigger = 0; pad.right_trigger = 255;
    len = hidpad_input_report( id, &pad, &st, 0, r );
    assert( scaled( &p, HID_USAGE_GENERIC_Z, r, len ) == -255 * 128 );

    {
        static const uint32_t order[] =
        {
            HIDPAD_XI_A, HIDPAD_XI_B, HIDPAD_XI_X, HIDPAD_XI_Y, HIDPAD_XI_LSHOULDER, HIDPAD_XI_RSHOULDER,
            HIDPAD_XI_BACK, HIDPAD_XI_START, HIDPAD_XI_LTHUMB, HIDPAD_XI_RTHUMB, HIDPAD_XI_GUIDE,
        };
        for (i = 0; i < sizeof(order) / sizeof(order[0]); i++)
        {
            pad.buttons = order[i];
            len = hidpad_input_report( id, &pad, &st, 0, r );
            assert( buttons( &p, r, len ) == 1u << i );
        }
        pad.buttons = WINIOS_HIDPAD_TOUCHPAD | WINIOS_HIDPAD_MUTE | WINIOS_HIDPAD_L2;
        len = hidpad_input_report( id, &pad, &st, 0, r );
        assert( buttons( &p, r, len ) == 0 );
    }
    pad.buttons = HIDPAD_XI_DPAD_DOWN | HIDPAD_XI_DPAD_LEFT;
    len = hidpad_input_report( id, &pad, &st, 0, r );
    assert( value( &p, HID_USAGE_PAGE_GENERIC, HID_USAGE_GENERIC_HATSWITCH, r, len ) == 6 );   /* SW, 1-based */
    free( p.pre );
}

static void check_transport( void )
{
    struct winios_hidpad pad = {0}, got;
    struct winios_gamepad xi;

    assert( sizeof(struct winios_hidpad) == 48 );
    assert( sizeof(struct winios_gamepad) == 20 );
    assert( !winios_hidpad_get_state( &got ) && got.packet == 0 );
    pad.connected = 1; pad.lx = 5; pad.packet = 77; pad.reserved2 = 9;
    winios_hidpad_set_state( &pad );
    assert( winios_hidpad_get_state( &got ) && got.packet == 1 && got.lx == 5 && !got.reserved2 );
    winios_hidpad_set_state( &pad );
    assert( winios_hidpad_get_state( &got ) && got.packet == 1 );
    winios_hidpad_set_state( NULL );
    memset( &got, 0xff, sizeof(got) );
    assert( !winios_hidpad_get_state( &got ) && got.packet == 2 && !got.lx && !got.connected );
    /* The XInput slots are a separate snapshot. */
    assert( !winios_gamepad_get_state( 0, &xi ) );
}

int main( void )
{
    check_ids();
    check_dualsense();
    check_generic();
    check_transport();
    return 0;
}
'''

# ml2105: the registry half (build/ntdll-unix/server_ios.c, ios_hidpad_publish)
# against a fake registry with Wine 11's rule -- NtCreateKey makes one key and
# fails when a parent is missing (server/registry.c key_lookup_name) -- seeded
# like the prefix template: Enum\HID and DeviceClasses\{4D1E55B2-...} exist,
# the class key in upper case as Wine wrote it.
server = (root / 'build/ntdll-unix/server_ios.c').read_text()
a = server.index('#include "../hidpad/hidpad_ids.h"')
b = server.index('\n}\n', server.index('static void ios_hidpad_publish(void)')) + 3
publish = server[a:b].replace('#include "../hidpad/hidpad_ids.h"', '#include "hidpad_ids.h"')

registry = r'''
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "ddk/wdm.h"

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif

/* unix_private.h's helpers. */
static inline void ascii_to_unicode( WCHAR *dst, const char *src, size_t len )
{
    while (len--) *dst++ = (unsigned char)*src++;
}
static inline void init_unicode_string( UNICODE_STRING *str, const WCHAR *data )
{
    const WCHAR *p = data;
    while (*p) p++;
    str->Length = (p - data) * sizeof(WCHAR);
    str->MaximumLength = str->Length + sizeof(WCHAR);
    str->Buffer = (WCHAR *)data;
}

struct node { char name[160]; struct node *parent; int is_volatile; char values[512]; };
static struct node nodes[64];
static unsigned int node_count, creates, log_lines;
static char live_link[256], last_log[512];

static void narrow( const UNICODE_STRING *s, char *out )
{
    unsigned int i, n = s->Length / sizeof(WCHAR);
    for (i = 0; i < n; i++) out[i] = (char)s->Buffer[i];
    out[n] = 0;
}
static struct node *child( struct node *parent, const char *name )
{
    unsigned int i;
    for (i = 0; i < node_count; i++)
        if (nodes[i].parent == parent && !strcasecmp( nodes[i].name, name )) return &nodes[i];
    return NULL;
}
static struct node *add( struct node *parent, const char *name, int vol )
{
    struct node *n = &nodes[node_count++];
    assert( node_count < ARRAY_SIZE(nodes) );
    strcpy( n->name, name );
    n->parent = parent;
    n->is_volatile = vol;
    n->values[0] = 0;
    return n;
}
/* Walk `path` from `n`; *rest gets the first missing element. */
static struct node *walk( struct node *n, char *path, char **rest )
{
    char *p = path, *e;
    while (*p == '\\') p++;
    while (*p)
    {
        struct node *c;
        if ((e = strchr( p, '\\' ))) *e = 0;
        if (!(c = child( n, p ))) { if (e) *e = '\\'; *rest = p; return n; }
        n = c;
        if (!e) break;
        p = e + 1;
    }
    *rest = NULL;
    return n;
}
static struct node *root_node;

NTSTATUS WINAPI NtOpenKey( HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    char path[512], *rest;
    struct node *n;
    narrow( attr->ObjectName, path );
    n = walk( attr->RootDirectory ? (struct node *)attr->RootDirectory : root_node, path, &rest );
    if (rest) return STATUS_OBJECT_NAME_NOT_FOUND;
    *key = n;
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtCreateKey( HANDLE *key, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr, ULONG index,
                             const UNICODE_STRING *class, ULONG options, ULONG *dispos )
{
    char path[512], *rest;
    struct node *n;
    narrow( attr->ObjectName, path );
    n = walk( attr->RootDirectory ? (struct node *)attr->RootDirectory : root_node, path, &rest );
    if (rest)
    {
        if (strchr( rest, '\\' )) return STATUS_OBJECT_NAME_NOT_FOUND;   /* a parent is missing */
        if (n->is_volatile && !(options & REG_OPTION_VOLATILE)) return STATUS_CHILD_MUST_BE_VOLATILE;
        n = add( n, rest, !!(options & REG_OPTION_VOLATILE) );
        creates++;
    }
    *key = n;
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtSetValueKey( HANDLE key, const UNICODE_STRING *name, ULONG index, ULONG type,
                               const void *data, ULONG size )
{
    struct node *n = key;
    char value[64], line[256];
    unsigned int i;
    narrow( name, value );
    if (type == REG_DWORD) snprintf( line, sizeof(line), "%s=dword:%u;", value, *(const DWORD *)data );
    else
    {
        const WCHAR *w = data;
        int len = snprintf( line, sizeof(line), "%s=%s:", value, type == REG_MULTI_SZ ? "multi" : "sz" );
        assert( size % sizeof(WCHAR) == 0 && size >= sizeof(WCHAR) && !w[size / sizeof(WCHAR) - 1] );
        if (type == REG_MULTI_SZ) assert( size >= 2 * sizeof(WCHAR) && !w[size / sizeof(WCHAR) - 2] );
        for (i = 0; i < size / sizeof(WCHAR) - 1; i++) line[len++] = w[i] ? (char)w[i] : '|';
        line[len++] = ';';
        line[len] = 0;
    }
    strcat( n->values, line );
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtOpenSymbolicLinkObject( HANDLE *handle, ACCESS_MASK access, const OBJECT_ATTRIBUTES *attr )
{
    char path[512];
    narrow( attr->ObjectName, path );
    if (!live_link[0] || strcasecmp( path, live_link )) return STATUS_OBJECT_NAME_NOT_FOUND;
    *handle = (HANDLE)1;
    return STATUS_SUCCESS;
}
NTSTATUS WINAPI NtClose( HANDLE handle ) { return STATUS_SUCCESS; }
static void wine_log_write( const char *fmt, ... )
{
    va_list args;
    va_start( args, fmt );
    vsnprintf( last_log, sizeof(last_log), fmt, args );
    va_end( args );
    log_lines++;
}

''' + publish + r'''

static struct node *find( const char *path )
{
    char copy[512], *rest;
    struct node *n;
    strcpy( copy, path );
    n = walk( root_node, copy, &rest );
    return rest ? NULL : n;
}
static void reset( void )
{
    struct node *n;
    node_count = creates = log_lines = 0;
    last_log[0] = 0;
    root_node = add( NULL, "", 0 );
    n = add( add( add( add( root_node, "Registry", 0 ), "Machine", 0 ), "System", 0 ), "CurrentControlSet", 0 );
    add( add( n, "Enum", 0 ), "HID", 0 );
    add( add( add( n, "Control", 0 ), "DeviceClasses", 0 ), "{4D1E55B2-F16F-11CF-88CB-001111000030}", 0 );
}
#define CCS "\\Registry\\Machine\\System\\CurrentControlSet"
#define IFACE CCS "\\Control\\DeviceClasses\\{4D1E55B2-F16F-11CF-88CB-001111000030}\\##?#HID#VID_054C&PID_0CE6&MI_03#9&4d616465&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}"

int main( void )
{
    struct node *n;
    HANDLE key;
    OBJECT_ATTRIBUTES attr;
    UNICODE_STRING name;
    WCHAR buf[256];

    /* The fake follows Wine 11: one NtCreateKey over a missing parent fails. */
    reset();
    ascii_to_unicode( buf, CCS "\\Enum\\HID\\VID_054C&PID_0CE6&MI_03\\x", sizeof(CCS "\\Enum\\HID\\VID_054C&PID_0CE6&MI_03\\x") );
    init_unicode_string( &name, buf );
    InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, 0, NULL );
    assert( NtCreateKey( &key, KEY_ALL_ACCESS, &attr, 0, NULL, REG_OPTION_VOLATILE, NULL ) == STATUS_OBJECT_NAME_NOT_FOUND );

    /* XInput mode: MADEIRA_HIDPAD unset, nothing touched, nothing logged. */
    reset();
    unsetenv( "MADEIRA_HIDPAD" );
    strcpy( live_link, "\\??\\HID#VID_054C&PID_0CE6&MI_03#9&4d616465&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}" );
    ios_hidpad_publish();
    assert( !creates && !log_lines );

    /* DualSense: every level created, volatile, the class key reused as is. */
    reset();
    setenv( "MADEIRA_HIDPAD", "dualsense", 1 );
    ios_hidpad_publish();
    assert( log_lines == 1 && strstr( last_log, "(4/4 keys)" ) && strstr( last_log, "054C:0CE6" ) );
    n = find( CCS "\\Enum\\HID\\VID_054C&PID_0CE6&MI_03\\9&4d616465&0&0000" );
    assert( n && n->is_volatile && n->parent->is_volatile && !n->parent->parent->is_volatile );
    assert( strstr( n->values, "ClassGUID=sz:{745a17a0-74d3-11d0-b6fe-00a0c90f57da};" ) );
    assert( strstr( n->values, "Class=sz:HIDClass;" ) );
    assert( strstr( n->values, "HardwareID=multi:HID\\VID_054C&PID_0CE6&REV_0100&MI_03|HID\\VID_054C&PID_0CE6&MI_03|"
                               "HID\\VID_054C&UP:0001_U:0005|HID_DEVICE_SYSTEM_GAME|HID_DEVICE_UP:0001_U:0005|HID_DEVICE|;" ) );
    assert( strstr( n->values, "Mfg=sz:Sony Interactive Entertainment;" ) );
    n = find( IFACE );
    assert( n && n->is_volatile && !n->parent->is_volatile );
    assert( !strcmp( n->values, "DeviceInstance=sz:HID\\VID_054C&PID_0CE6&MI_03\\9&4d616465&0&0000;" ) );
    n = find( IFACE "\\#" );
    assert( n && !strcmp( n->values, "SymbolicLink=sz:\\\\?\\HID#VID_054C&PID_0CE6&MI_03#9&4d616465&0&0000"
                                     "#{4d1e55b2-f16f-11cf-88cb-001111000030};" ) );
    n = find( IFACE "\\#\\Control" );
    assert( n && !strcmp( n->values, "Linked=dword:1;" ) );
    assert( creates == 5 );   /* VID_..., instance, interface, #, Control: no second class key */

    /* The env names another identity: the registry follows the device that exists. */
    reset();
    setenv( "MADEIRA_HIDPAD", "generic", 1 );
    ios_hidpad_publish();
    assert( find( IFACE "\\#\\Control" ) && !find( CCS "\\Enum\\HID\\VID_1209&PID_4D47" ) );

    /* No device at all: nothing registered, one line saying so. */
    reset();
    live_link[0] = 0;
    setenv( "MADEIRA_HIDPAD", "dualsense", 1 );
    ios_hidpad_publish();
    assert( !creates && log_lines == 1 && strstr( last_log, "made no pad" ) );

    /* Generic pad. */
    reset();
    strcpy( live_link, "\\??\\HID#VID_1209&PID_4D47#9&4d616465&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}" );
    ios_hidpad_publish();
    n = find( CCS "\\Enum\\HID\\VID_1209&PID_4D47\\9&4d616465&0&0000" );
    assert( n && strstr( n->values, "Mfg=sz:Madeira;" ) );
    assert( find( CCS "\\Control\\DeviceClasses\\{4d1e55b2-f16f-11cf-88cb-001111000030}\\##?#HID#VID_1209&PID_4D47"
                  "#9&4d616465&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}\\#\\Control" ) );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-hidpad-') as tmp:
    source = Path(tmp) / 'check.c'
    binary = Path(tmp) / 'check'
    source.write_text(test)
    cc = os.environ.get('CC', 'cc')
    flags = ['-std=gnu11', '-O1', '-fshort-wchar', '-Wno-format', '-Wno-unused-function',
             '-D__WINESRC__', '-DWINE_UNIX_LIB', '-I', str(wine / 'include'),
             '-I', str(root / 'build/hidpad')]
    reg_source = Path(tmp) / 'registry.c'
    reg_binary = Path(tmp) / 'registry'
    reg_source.write_text(registry)
    subprocess.run([cc, *flags, '-Wall', '-Werror', '-Wno-unused-variable', str(reg_source), '-o', str(reg_binary)],
                   check=True)
    subprocess.run([str(reg_binary)], check=True)
    objs = []
    for name, src, extra in [
        ('hidparse', root / 'build/hidpad/hidparse_ios.c',
         [f'-DMADEIRA_HIDPARSE_MAIN="{wine}/dlls/hidparse.sys/main.c"']),
        ('hidp', wine / 'dlls/hid/hidp.c', []),
        ('transport', root / 'app/Madeira/Winios/WiniosGamepad.c', []),
        ('check', source, ['-Wall', '-Werror', '-Wno-unused-variable', '-Wno-format']),
    ]:
        obj = Path(tmp) / f'{name}.o'
        subprocess.run([cc, *flags, *extra, '-c', str(src), '-o', str(obj)], check=True)
        objs.append(str(obj))
    subprocess.run([cc, *objs, '-pthread', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: DualSense and generic descriptors through Wine hidparse + hid.dll, '
      'sticks/triggers/buttons/hat/touch/motion/battery, feature reports, transport, '
      'registry entries (level by level, volatile, only for the device that exists)')
