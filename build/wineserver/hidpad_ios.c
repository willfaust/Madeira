/*
 * ml2101: the opt-in HID controller, served by the wineserver itself.
 *
 * GPL-3.0-or-later WITH the Madeira Converter Exception, version 1; see
 * LICENSE-EXCEPTION.md.
 *
 * WHY HERE AND NOT winebus.sys. On a desktop Wine a controller reaches
 * hid.dll through services.exe -> plugplay.exe -> winedevice.exe, which loads
 * ntoskrnl.exe, winebus.sys (with a unix backend), winehid.sys, hidclass.sys
 * and hidparse.sys; hidclass creates the device object and serves its reads
 * and IOCTLs from that process. None of it runs in a Madeira game session:
 * the app ships no .sys file and no winedevice.exe/plugplay.exe (.gitignore),
 * the prefix template keeps winebus, winehid and PlugPlay disabled, a library
 * game session starts no service manager, and under madsync services.exe never
 * answered its RPC clients (DockInstallers.swift). The port already replaced
 * two drivers the same way (nsiproxy.sys -> nsi_unixlib_ios.c, mountmgr.sys ->
 * ios_create_drive_symlinks), and Wine's own server serves \Device\ConDrv,
 * \Device\Afd and \Device\NamedPipe without any driver -- which is what this
 * file does for one HID game controller.
 *
 * WHAT A GAME SEES. setupapi lists GUID_DEVINTERFACE_HID from the registry
 * (entries written at session start by build/ntdll-unix/server_ios.c); the
 * listed path, \\?\HID#VID_054C&PID_0CE6&MI_03#...#{4d1e55b2-...}, is a
 * symlink to \Device\MadeiraHidPad0, created below. Opening it gives a file
 * whose reads, writes and IOCTLs land here, with the same contract hidclass.sys
 * (wine/dlls/hidclass.sys/device.c) gives its PDO files: input reports through
 * ReadFile, output reports through WriteFile / IOCTL_HID_SET_OUTPUT_REPORT, and
 * IOCTL_HID_GET_COLLECTION_DESCRIPTOR answering with the preparsed data Wine's
 * own hidparse.sys builds (build/hidpad/hidparse_ios.c), so hid.dll's HidP_*
 * functions, dinput8's HID joystick, windows.gaming.input and Sony's libScePad
 * all read it as they would a device behind hidclass. hid.dll, setupapi.dll
 * and dinput are the shipped builtins, unchanged; 32-bit games reach the same
 * object through WoW64.
 *
 * REPORT CLOCK. A wired DualSense streams a report every 4 ms whether or not
 * anything changed (the sensor clock and counter move), and libScePad keeps a
 * read pending all the time. A read here completes at once when this handle
 * has had no report for 4 ms, or when the app published a new sample and 1 ms
 * has passed; otherwise it waits for the device clock, a 4 ms timer that only
 * runs while some handle has a read pending. Each report is built from the
 * newest snapshot, so a slow reader gets the current state, not a backlog.
 *
 * Nothing here runs unless the app exported MADEIRA_HIDPAD for this session
 * (env.MADEIRA_PAD_MODE = hid); in XInput mode the wineserver does exactly
 * what it did before.
 */

#include "config.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "winioctl.h"
#include "ddk/hidclass.h"

#include "object.h"
#include "file.h"
#include "handle.h"
#include "process.h"
#include "thread.h"
#include "request.h"

#include "../hidpad/hidpad_reports.h"
#include "../hidpad/hidparse_ios.h"

/* wine/include/wine/hid.h; not included for one constant, it pulls the DDK. */
#ifndef IOCTL_HID_GET_WINE_RAWINPUT_HANDLE
#define IOCTL_HID_GET_WINE_RAWINPUT_HANDLE HID_BUFFER_CTL_CODE(300)
#endif

#define HIDPAD_TICK      (TICKS_PER_SEC / 250)    /* 4 ms, a wired DualSense's report rate */
#define HIDPAD_MIN_GAP   (TICKS_PER_SEC / 1000)   /* a fresh sample goes out after 1 ms */
#define HIDPAD_LOG_LIMIT 8

struct hidpad_device
{
    struct object                 obj;
    const struct hidpad_identity *id;
    struct list                   files;
    struct timeout_user          *clock;
    void                         *preparsed;
    unsigned int                  preparsed_size;
    unsigned short                input_len[256], output_len[256], feature_len[256];
    struct hidpad_report_state    state;
    char                          product[64];
    unsigned int                  opens, reads, outputs, features, refused;
};

struct hidpad_file
{
    struct object         obj;
    struct hidpad_device *device;
    struct fd            *fd;
    struct list           entry;
    struct async_queue    read_q;
    timeout_t             last_report;    /* monotonic_time of this handle's last report, 0 = none */
    unsigned int          last_packet;    /* snapshot packet that report was built from */
    unsigned int          buffers;        /* IOCTL_[GS]ET_NUM_DEVICE_INPUT_BUFFERS */
};

static void hidpad_device_dump( struct object *obj, int verbose );
static struct object *hidpad_device_open_file( struct object *obj, unsigned int access,
                                               unsigned int sharing, unsigned int options );

static const struct object_ops hidpad_device_ops =
{
    sizeof(struct hidpad_device),     /* size */
    &device_type,                     /* type */
    hidpad_device_dump,               /* dump */
    no_add_queue,                     /* add_queue */
    NULL,                             /* remove_queue */
    NULL,                             /* signaled */
    no_satisfied,                     /* satisfied */
    no_signal,                        /* signal */
    no_get_fd,                        /* get_fd */
    default_get_sync,                 /* get_sync */
    default_map_access,               /* map_access */
    default_get_sd,                   /* get_sd */
    default_set_sd,                   /* set_sd */
    default_get_full_name,            /* get_full_name */
    no_lookup_name,                   /* lookup_name */
    directory_link_name,              /* link_name */
    default_unlink_name,              /* unlink_name */
    hidpad_device_open_file,          /* open_file */
    no_kernel_obj_list,               /* get_kernel_obj_list */
    no_close_handle,                  /* close_handle */
    no_destroy                        /* destroy: permanent, never freed */
};

static void hidpad_file_dump( struct object *obj, int verbose );
static struct fd *hidpad_file_get_fd( struct object *obj );
static WCHAR *hidpad_file_get_full_name( struct object *obj, data_size_t max, data_size_t *len );
static void hidpad_file_destroy( struct object *obj );

static const struct object_ops hidpad_file_ops =
{
    sizeof(struct hidpad_file),       /* size */
    &file_type,                       /* type */
    hidpad_file_dump,                 /* dump */
    NULL,                             /* add_queue */
    NULL,                             /* remove_queue */
    NULL,                             /* signaled */
    NULL,                             /* satisfied */
    no_signal,                        /* signal */
    hidpad_file_get_fd,               /* get_fd */
    default_fd_get_sync,              /* get_sync */
    default_map_access,               /* map_access */
    default_get_sd,                   /* get_sd */
    default_set_sd,                   /* set_sd */
    hidpad_file_get_full_name,        /* get_full_name */
    no_lookup_name,                   /* lookup_name */
    no_link_name,                     /* link_name */
    NULL,                             /* unlink_name */
    no_open_file,                     /* open_file */
    no_kernel_obj_list,               /* get_kernel_obj_list */
    async_close_obj_handle,           /* close_handle: as named_pipe.c's ends */
    hidpad_file_destroy               /* destroy */
};

static enum server_fd_type hidpad_file_get_fd_type( struct fd *fd );
static void hidpad_file_read( struct fd *fd, struct async *async, file_pos_t pos );
static void hidpad_file_write( struct fd *fd, struct async *async, file_pos_t pos );
static void hidpad_file_get_volume_info( struct fd *fd, struct async *async, unsigned int info_class );
static void hidpad_file_ioctl( struct fd *fd, ioctl_code_t code, struct async *async );

static const struct fd_ops hidpad_file_fd_ops =
{
    default_fd_get_poll_events,       /* get_poll_events */
    default_poll_event,               /* poll_event */
    hidpad_file_get_fd_type,          /* get_fd_type */
    hidpad_file_read,                 /* read */
    hidpad_file_write,                /* write */
    no_fd_flush,                      /* flush */
    default_fd_get_file_info,         /* get_file_info */
    hidpad_file_get_volume_info,      /* get_volume_info */
    hidpad_file_ioctl,                /* ioctl */
    default_fd_cancel_async,          /* cancel_async */
    default_fd_queue_async,           /* queue_async */
    default_fd_reselect_async,        /* reselect_async */
};

static void hidpad_device_dump( struct object *obj, int verbose )
{
    struct hidpad_device *device = (struct hidpad_device *)obj;
    fprintf( stderr, "HID pad %s %04x:%04x\n", device->id->env, device->id->vid, device->id->pid );
}

static void hidpad_file_dump( struct object *obj, int verbose )
{
    struct hidpad_file *file = (struct hidpad_file *)obj;
    fprintf( stderr, "File on HID pad %s\n", file->device->id->env );
}

static struct fd *hidpad_file_get_fd( struct object *obj )
{
    struct hidpad_file *file = (struct hidpad_file *)obj;
    return (struct fd *)grab_object( file->fd );
}

static WCHAR *hidpad_file_get_full_name( struct object *obj, data_size_t max, data_size_t *len )
{
    struct hidpad_file *file = (struct hidpad_file *)obj;
    return file->device->obj.ops->get_full_name( &file->device->obj, max, len );
}

static enum server_fd_type hidpad_file_get_fd_type( struct fd *fd )
{
    return FD_TYPE_DEVICE;
}

static struct object *hidpad_device_open_file( struct object *obj, unsigned int access,
                                               unsigned int sharing, unsigned int options )
{
    struct hidpad_device *device = (struct hidpad_device *)obj;
    struct hidpad_file *file;

    if (!(file = alloc_object( &hidpad_file_ops ))) return NULL;
    file->device = (struct hidpad_device *)grab_object( device );
    file->fd = NULL;
    file->last_report = 0;
    file->last_packet = 0;
    file->buffers = 32;
    init_async_queue( &file->read_q );
    list_add_tail( &device->files, &file->entry );
    if (!(file->fd = alloc_pseudo_fd( &hidpad_file_fd_ops, &file->obj, options )))
    {
        release_object( file );
        return NULL;
    }
    allow_fd_caching( file->fd );

    if (device->opens++ < HIDPAD_LOG_LIMIT)
        fprintf( stderr, "[hid-pad] ml2101 open #%u pid=%04x access=%#x options=%#x\n", device->opens,
                 current ? current->process->id : 0, access, options );
    return &file->obj;
}

static void hidpad_file_destroy( struct object *obj )
{
    struct hidpad_file *file = (struct hidpad_file *)obj;
    struct hidpad_device *device = file->device;

    free_async_queue( &file->read_q );
    if (file->fd) release_object( file->fd );
    list_remove( &file->entry );
    release_object( device );
}

static int hidpad_file_pending( struct hidpad_file *file )
{
    struct async *async = find_pending_async( &file->read_q );
    if (async) release_object( async );
    return async != NULL;
}

static int hidpad_report_due( const struct hidpad_file *file, const struct winios_hidpad *pad )
{
    timeout_t since = monotonic_time - file->last_report;

    if (!file->last_report || since >= HIDPAD_TICK - HIDPAD_TICK / 8) return 1;
    return pad->packet != file->last_packet && since >= HIDPAD_MIN_GAP;
}

/* Complete this handle's oldest pending read with a fresh report, if one is
 * due. One report per handle per call: hidclass hands each queue one report
 * per device report too. */
static void hidpad_file_deliver( struct hidpad_file *file )
{
    struct hidpad_device *device = file->device;
    unsigned char report[HIDPAD_DUALSENSE_INPUT_LEN];
    struct winios_hidpad pad;
    struct async *async;
    unsigned int len;

    if (!(async = find_pending_async( &file->read_q ))) return;
    winios_hidpad_get_state( &pad );
    if (hidpad_report_due( file, &pad ))
    {
        len = hidpad_input_report( device->id, &pad, &device->state, monotonic_time / 10, report );
        file->last_report = monotonic_time;
        file->last_packet = pad.packet;
        if (!device->reads++)
            fprintf( stderr, "[hid-pad] ml2101 first input report: %u bytes, pad %s\n", len,
                     pad.connected ? "connected" : "at rest" );
        async_request_complete_alloc( async, STATUS_SUCCESS, len, len, report );
    }
    release_object( async );
}

static void hidpad_clock( void *private );

static void hidpad_start_clock( struct hidpad_device *device )
{
    if (!device->clock) device->clock = add_timeout_user( -HIDPAD_TICK, hidpad_clock, device );
}

/* The device clock: every 4 ms while any handle has a read pending. */
static void hidpad_clock( void *private )
{
    struct hidpad_device *device = private;
    struct hidpad_file *file, *next;
    int pending = 0;

    device->clock = NULL;
    LIST_FOR_EACH_ENTRY_SAFE( file, next, &device->files, struct hidpad_file, entry )
    {
        hidpad_file_deliver( file );
        pending |= hidpad_file_pending( file );
    }
    if (pending) hidpad_start_clock( device );
}

static void hidpad_file_read( struct fd *fd, struct async *async, file_pos_t pos )
{
    struct hidpad_file *file = get_fd_user( fd );
    struct hidpad_device *device = file->device;

    /* hidclass's pdo_read: a buffer shorter than one report is refused. */
    if (get_reply_max_size() < device->input_len[1])
    {
        set_error( STATUS_INVALID_BUFFER_SIZE );
        return;
    }
    queue_async( &file->read_q, async );
    hidpad_file_deliver( file );
    if (hidpad_file_pending( file )) hidpad_start_clock( device );
    set_error( STATUS_PENDING );
}

/* An output report from WriteFile or IOCTL_HID_SET_OUTPUT_REPORT; the same
 * checks as hidclass's hid_device_xfer_report. Accepted and counted: the
 * reports (rumble, adaptive triggers, lightbar) are not applied to the
 * physical pad here. */
static unsigned int hidpad_output( struct hidpad_device *device, const unsigned char *data, data_size_t size,
                                   const char *how )
{
    if (!size || !device->output_len[data[0]] || size < device->output_len[data[0]])
    {
        if (device->refused++ < HIDPAD_LOG_LIMIT)
            fprintf( stderr, "[hid-pad] ml2104 %s refused: report %#x, %u bytes\n", how,
                     size ? data[0] : 0, size );
        return STATUS_INVALID_PARAMETER;
    }
    if (!device->outputs++)
        fprintf( stderr, "[hid-pad] ml2101 first output report via %s: report %#x, %u bytes\n", how,
                 data[0], size );
    return STATUS_SUCCESS;
}

static void hidpad_file_write( struct fd *fd, struct async *async, file_pos_t pos )
{
    struct hidpad_file *file = get_fd_user( fd );
    data_size_t size = get_req_data_size();
    unsigned int status = hidpad_output( file->device, get_req_data(), size, "write" );

    if (status)
    {
        set_error( status );
        return;
    }
    async_request_complete( async, STATUS_SUCCESS, size, 0, NULL );
    set_error( STATUS_PENDING );
}

static void hidpad_file_get_volume_info( struct fd *fd, struct async *async, unsigned int info_class )
{
    static const FILE_FS_DEVICE_INFORMATION info = { FILE_DEVICE_UNKNOWN, 0 };

    if (info_class != FileFsDeviceInformation) set_error( STATUS_NOT_IMPLEMENTED );
    else if (get_reply_max_size() < sizeof(info)) set_error( STATUS_BUFFER_TOO_SMALL );
    else set_reply_data( &info, sizeof(info) );
}

/* A HID string as hidclass returns it: UTF-16, NUL included. */
static void hidpad_reply_string( const char *str )
{
    WCHAR buffer[64];
    data_size_t len = 0;

    while (str[len] && len < ARRAY_SIZE(buffer) - 1) { buffer[len] = (unsigned char)str[len]; len++; }
    buffer[len++] = 0;
    if (get_reply_max_size() < len * sizeof(WCHAR)) set_error( STATUS_BUFFER_TOO_SMALL );
    else set_reply_data( buffer, len * sizeof(WCHAR) );
}

static void hidpad_reply_ulong( ULONG value )
{
    if (get_reply_max_size() < sizeof(value)) set_error( STATUS_BUFFER_TOO_SMALL );
    else set_reply_data( &value, sizeof(value) );
}

/* The request data of a METHOD_*_DIRECT / NEITHER IOCTL is the input buffer
 * followed by the output buffer's contents (ntdll's server_ioctl_file), so
 * byte 0 is the report ID whether the caller passed the report as input
 * (hidapi) or only as output (hid.dll). */
static void hidpad_file_ioctl( struct fd *fd, ioctl_code_t code, struct async *async )
{
    struct hidpad_file *file = get_fd_user( fd );
    struct hidpad_device *device = file->device;
    const unsigned char *in = get_req_data();
    data_size_t in_size = get_req_data_size();
    unsigned char report[64];
    unsigned int len;

    switch (code)
    {
    case IOCTL_HID_GET_COLLECTION_INFORMATION:
    {
        HID_COLLECTION_INFORMATION info = {0};

        info.DescriptorSize = device->preparsed_size;
        info.Polled = FALSE;
        info.VendorID = device->id->vid;
        info.ProductID = device->id->pid;
        info.VersionNumber = device->id->version;
        if (get_reply_max_size() < sizeof(info)) set_error( STATUS_BUFFER_OVERFLOW );
        else set_reply_data( &info, sizeof(info) );
        return;
    }
    case IOCTL_HID_GET_COLLECTION_DESCRIPTOR:
        if (get_reply_max_size() < device->preparsed_size) set_error( STATUS_INVALID_BUFFER_SIZE );
        else set_reply_data( device->preparsed, device->preparsed_size );
        return;

    case IOCTL_HID_GET_INPUT_REPORT:
    {
        struct winios_hidpad pad;

        if (!in_size || !(len = device->input_len[in[0]]) || get_reply_max_size() < len)
        {
            set_error( STATUS_INVALID_PARAMETER );
            return;
        }
        winios_hidpad_get_state( &pad );
        len = hidpad_input_report( device->id, &pad, &device->state, monotonic_time / 10, report );
        set_reply_data( report, len );
        return;
    }
    case IOCTL_HID_GET_FEATURE:
        if (!in_size || !(len = device->feature_len[in[0]]) || get_reply_max_size() < len ||
            len > sizeof(report) || !hidpad_dualsense_feature( in[0], report, len ))
        {
            set_error( STATUS_INVALID_PARAMETER );
            return;
        }
        if (device->features++ < 2 * HIDPAD_LOG_LIMIT)
            fprintf( stderr, "[hid-pad] ml2101 feature report %#x read (%u bytes)\n", in[0], len );
        set_reply_data( report, len );
        return;

    case IOCTL_HID_SET_FEATURE:
        if (!in_size || !(len = device->feature_len[in[0]]) || in_size < len)
            set_error( STATUS_INVALID_PARAMETER );
        else if (device->features++ < 2 * HIDPAD_LOG_LIMIT)
            fprintf( stderr, "[hid-pad] ml2101 feature report %#x written (%u bytes), ignored\n", in[0], in_size );
        return;

    case IOCTL_HID_SET_OUTPUT_REPORT:
    {
        unsigned int status = hidpad_output( device, in, in_size, "ioctl" );
        if (status) set_error( status );
        return;
    }
    case IOCTL_HID_GET_MANUFACTURER_STRING:
        hidpad_reply_string( device->id->manufacturer );
        return;
    case IOCTL_HID_GET_PRODUCT_STRING:
        hidpad_reply_string( device->product );
        return;
    case IOCTL_HID_GET_SERIALNUMBER_STRING:
        hidpad_reply_string( device->id->serial );
        return;
    case IOCTL_HID_GET_INDEXED_STRING:
    {
        ULONG index = 0;

        if (in_size >= sizeof(index)) memcpy( &index, in, sizeof(index) );
        /* The USB string descriptor indices: 1 manufacturer, 2 product, 3 serial. */
        switch (index)
        {
        case 1: hidpad_reply_string( device->id->manufacturer ); return;
        case 2: hidpad_reply_string( device->product ); return;
        case 3: hidpad_reply_string( device->id->serial ); return;
        }
        set_error( STATUS_INVALID_PARAMETER );
        return;
    }
    case IOCTL_HID_GET_POLL_FREQUENCY_MSEC:
        hidpad_reply_ulong( 0 );    /* interrupt-driven, as a USB pad is */
        return;
    case IOCTL_HID_SET_POLL_FREQUENCY_MSEC:
        if (in_size < sizeof(ULONG)) set_error( STATUS_BUFFER_TOO_SMALL );
        return;
    case IOCTL_GET_NUM_DEVICE_INPUT_BUFFERS:
        hidpad_reply_ulong( file->buffers );
        return;
    case IOCTL_SET_NUM_DEVICE_INPUT_BUFFERS:
    {
        ULONG count;

        /* hidclass's hid_queue_resize accepts 2..512. Reports never back
         * up here (each is built when read), so the count is only stored. */
        if (in_size != sizeof(count)) { set_error( STATUS_BUFFER_OVERFLOW ); return; }
        memcpy( &count, in, sizeof(count) );
        if (count < 2 || count > 512) set_error( STATUS_INVALID_PARAMETER );
        else file->buffers = count;
        return;
    }
    case IOCTL_HID_FLUSH_QUEUE:
        return;
    case IOCTL_HID_GET_WINE_RAWINPUT_HANDLE:
        /* dinput's HID joystick will not list a device without one. */
        hidpad_reply_ulong( HIDPAD_RAWINPUT_HANDLE );
        return;
    }

    if (device->refused++ < HIDPAD_LOG_LIMIT)
        fprintf( stderr, "[hid-pad] ml2101 unsupported ioctl %#x\n", code );
    set_error( STATUS_NOT_SUPPORTED );
}

static void hidpad_ascii_name( const char *ascii, WCHAR *buffer, unsigned int size, struct unicode_str *str )
{
    unsigned int len = 0;

    while (ascii[len] && len < size) { buffer[len] = (unsigned char)ascii[len]; len++; }
    str->str = buffer;
    str->len = len * sizeof(WCHAR);
}

/* The product string a generic pad reports: the physical controller's name
 * when the app passed one (printable ASCII only), else the identity's. */
static void hidpad_product_name( struct hidpad_device *device )
{
    const char *name = device->id->kind == HIDPAD_KIND_GENERIC ? getenv( "MADEIRA_HIDPAD_NAME" ) : NULL;
    unsigned int i, len = 0;

    if (name)
        for (i = 0; name[i] && len < sizeof(device->product) - 1; i++)
            if (name[i] >= 0x20 && name[i] < 0x7f) device->product[len++] = name[i];
    device->product[len] = 0;
    if (!len) snprintf( device->product, sizeof(device->product), "%s", device->id->product );
}

/***********************************************************************
 *           madeira_hidpad_init
 *
 * Called once by wineserver_main (main_ios.c) after the object namespace and
 * the registry exist. Creates \Device\MadeiraHidPad0 and the \??\HID#...
 * symlink the registry's interface entry names, or nothing at all when the
 * session is in XInput mode.
 */
void madeira_hidpad_init( void )
{
    const struct hidpad_identity *id = hidpad_identity_from_env( getenv( "MADEIRA_HIDPAD" ) );
    unsigned short input[256], output[256], feature[256];
    struct hidpad_device *device;
    const unsigned char *desc;
    unsigned int desc_len, size, expect;
    struct unicode_str name;
    struct object *symlink;
    WCHAR nameW[256];
    char link[200], path[210];
    void *preparsed;

    if (!id) return;
    desc = hidpad_descriptor( id, &desc_len );
    expect = id->kind == HIDPAD_KIND_DUALSENSE ? HIDPAD_DUALSENSE_INPUT_LEN : HIDPAD_GENERIC_INPUT_LEN;
    if (!(preparsed = madeira_hidparse_preparse( desc, desc_len, &size, input, output, feature )) ||
        input[1] != expect)
    {
        fprintf( stderr, "[hid-pad] ml2101 %s descriptor did not parse to a %u-byte report 0x01 "
                 "(got %u); no device\n", id->env, expect, preparsed ? input[1] : 0 );
        free( preparsed );
        return;
    }

    hidpad_ascii_name( HIDPAD_NT_DEVICE, nameW, ARRAY_SIZE(nameW), &name );
    if (!(device = create_named_object( NULL, &hidpad_device_ops, &name,
                                        OBJ_PERMANENT | OBJ_CASE_INSENSITIVE, NULL )))
    {
        fprintf( stderr, "[hid-pad] ml2101 cannot create %s: %#x\n", HIDPAD_NT_DEVICE, get_error() );
        free( preparsed );
        return;
    }
    device->id = id;
    list_init( &device->files );
    device->clock = NULL;
    device->preparsed = preparsed;
    device->preparsed_size = size;
    memcpy( device->input_len, input, sizeof(input) );
    memcpy( device->output_len, output, sizeof(output) );
    memcpy( device->feature_len, feature, sizeof(feature) );
    memset( &device->state, 0, sizeof(device->state) );
    device->opens = device->reads = device->outputs = device->features = device->refused = 0;
    hidpad_product_name( device );

    hidpad_interface_link( id, link, sizeof(link) );
    snprintf( path, sizeof(path), "\\??\\%s", link );
    hidpad_ascii_name( path, nameW, ARRAY_SIZE(nameW), &name );
    /* ml2105: no link, no device a game can open -- and ntdll publishes the
     * registry entries only for a link that exists (server_ios.c). */
    if (!(symlink = create_obj_symlink( NULL, &name, OBJ_PERMANENT | OBJ_CASE_INSENSITIVE, &device->obj, NULL )))
    {
        fprintf( stderr, "[hid-pad] ml2105 cannot create \\??\\%s: %#x; the pad stays invisible\n",
                 link, get_error() );
        return;
    }
    release_object( symlink );

    fprintf( stderr, "[hid-pad] ml2101 device %s %04x:%04x \"%s\" input %u output %u feature %u bytes, "
             "preparsed %u bytes, \\??\\%s\n", id->env, id->vid, id->pid, device->product,
             input[1], output[id->kind == HIDPAD_KIND_DUALSENSE ? 2 : 0], feature[0x20], size, link );
}
