/*
 * GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
 *
 * Desktop Wine's mountmgr creates \Device\Harddisk0 and \??\PhysicalDrive0
 * even without a Unix raw disk. Madeira ships no mountmgr/winedevice stack.
 * Serve that metadata endpoint in the embedded server, as hidpad_ios.c does
 * for HID. Capacity comes from the filesystem backing dosdevices/c:.
 * This device supplies metadata only; it cannot read or write host disk data.
 */
#include "config.h"
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"   /* header-only: this file uses madeira_cfg_get alone */
#include "../madeira_cfg.h"   /* env.MADEIRA_STORAGE_DEVICE from madeira.cfg: the server starts before the bridge exports env. lines (ml1236) */
#pragma GCC diagnostic pop
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "storage_device_ios.h"
#include "winternl.h"
#include "object.h"
#include "file.h"
#include "process.h"
#include "thread.h"
#include "request.h"

struct storage_device
{
    struct object obj;
    struct madeira_disk_info disk;
    unsigned int opens, ioctls;
};
struct storage_file
{
    struct object obj;
    struct storage_device *device;
    struct fd *fd;
};

static void storage_device_dump( struct object *obj, int verbose );
static struct object *storage_device_open( struct object *obj, unsigned int access,
                                          unsigned int sharing, unsigned int options );
static void storage_file_dump( struct object *obj, int verbose );
static struct fd *storage_file_get_fd( struct object *obj );
static WCHAR *storage_file_name( struct object *obj, data_size_t max, data_size_t *len );
static void storage_file_destroy( struct object *obj );
static enum server_fd_type storage_file_type( struct fd *fd );
static void storage_volume_info( struct fd *fd, struct async *async, unsigned int info_class );
static void storage_ioctl( struct fd *fd, ioctl_code_t code, struct async *async );

static const struct object_ops storage_device_ops =
{
    .size = sizeof(struct storage_device), .type = &device_type,
    .dump = storage_device_dump, .get_full_name = default_get_full_name,
    .link_name = directory_link_name, .open_file = storage_device_open,
};
static const struct object_ops storage_file_ops =
{
    .size = sizeof(struct storage_file), .type = &file_type,
    .dump = storage_file_dump, .get_fd = storage_file_get_fd,
    .get_sync = default_fd_get_sync, .get_full_name = storage_file_name,
    .close_handle = async_close_obj_handle, .destroy = storage_file_destroy,
};
static const struct fd_ops storage_fd_ops =
{
    .get_poll_events = default_fd_get_poll_events, .poll_event = default_poll_event,
    .get_fd_type = storage_file_type, .get_file_info = default_fd_get_file_info,
    .get_volume_info = storage_volume_info, .ioctl = storage_ioctl,
    .queue_async = default_fd_queue_async, .reselect_async = default_fd_reselect_async,
};

static void storage_device_dump( struct object *obj, int verbose )
{
    struct storage_device *device = (struct storage_device *)obj;
    fprintf( stderr, "Virtual prefix disk, %llu bytes\n", (unsigned long long)device->disk.bytes );
}
static void storage_file_dump( struct object *obj, int verbose )
{
    fprintf( stderr, "Virtual prefix disk metadata file\n" );
}
static struct fd *storage_file_get_fd( struct object *obj )
{
    return (struct fd *)grab_object( ((struct storage_file *)obj)->fd );
}
static WCHAR *storage_file_name( struct object *obj, data_size_t max, data_size_t *len )
{
    struct storage_file *file = (struct storage_file *)obj;
    return file->device->obj.ops->get_full_name( &file->device->obj, max, len );
}
static enum server_fd_type storage_file_type( struct fd *fd )
{
    return FD_TYPE_DEVICE;
}
static struct object *storage_device_open( struct object *obj, unsigned int access,
                                          unsigned int sharing, unsigned int options )
{
    struct storage_device *device = (struct storage_device *)obj;
    struct storage_file *file;
    if (options & FILE_DIRECTORY_FILE) { set_error( STATUS_NOT_A_DIRECTORY ); return NULL; }
    if (access & (GENERIC_WRITE | FILE_WRITE_DATA | FILE_APPEND_DATA | DELETE))
    { set_error( STATUS_ACCESS_DENIED ); return NULL; }
    if (!(file = alloc_object( &storage_file_ops ))) return NULL;
    file->device = (struct storage_device *)grab_object( device );
    file->fd = alloc_pseudo_fd( &storage_fd_ops, &file->obj, options );
    if (!file->fd) { release_object( file ); return NULL; }
    /* Pseudo fds report STATUS_BAD_DEVICE_TYPE to the raw-device Unix path;
     * ntdll then uses server_ioctl_file, like Wine's normal driver devices. */
    allow_fd_caching( file->fd );
    if (device->opens++ < 32)
        fprintf( stderr, "[storage-device] v1 open #%u pid=%04x access=%#x options=%#x\n",
                 device->opens, current ? current->process->id : 0, access, options );
    return &file->obj;
}
static void storage_file_destroy( struct object *obj )
{
    struct storage_file *file = (struct storage_file *)obj;
    if (file->fd) release_object( file->fd );
    release_object( file->device );
}
static void storage_volume_info( struct fd *fd, struct async *async, unsigned int info_class )
{
    const FILE_FS_DEVICE_INFORMATION info = { FILE_DEVICE_DISK, FILE_READ_ONLY_DEVICE };
    if (info_class != FileFsDeviceInformation) set_error( STATUS_NOT_IMPLEMENTED );
    else if (get_reply_max_size() < sizeof(info)) set_error( STATUS_BUFFER_TOO_SMALL );
    else set_reply_data( &info, sizeof(info) );
}
static void storage_ioctl( struct fd *fd, ioctl_code_t code, struct async *async )
{
    struct storage_file *file = get_fd_user( fd );
    struct storage_device *device = file->device;
    unsigned char out[128];
    size_t written = 0, out_size = get_reply_max_size();
    unsigned int status;
    if (out_size > sizeof(out)) out_size = sizeof(out);
    status = madeira_disk_ioctl( &device->disk, code, get_req_data(), get_req_data_size(),
                                 out, out_size, &written );
    if (device->ioctls++ < 64)
        fprintf( stderr, "[storage-device] v1 ioctl #%u pid=%04x code=%#x input=%u output=%u "
                 "status=%#x bytes=%zu\n", device->ioctls, current ? current->process->id : 0,
                 code, get_req_data_size(), get_reply_max_size(), status, written );
    if (status) set_error( status );
    else if (written) set_reply_data( out, written );
}

static void storage_name( const char *ascii, WCHAR *buffer, struct unicode_str *name )
{
    unsigned int i;
    for (i = 0; ascii[i]; i++) buffer[i] = (unsigned char)ascii[i];
    name->str = buffer;
    name->len = i * sizeof(WCHAR);
}

void madeira_storage_device_init( void )
{
    struct storage_device *device;
    struct unicode_str name;
    struct object *link;
    WCHAR nameW[48];
    uint64_t bytes;
    char optb[16];
    const char *opt = madeira_cfg_get( "env.MADEIRA_STORAGE_DEVICE", optb, sizeof(optb) ) ? optb
                      : getenv( "MADEIRA_STORAGE_DEVICE" );   /* 0: no \\.\\PhysicalDrive0 (the prefix disk's capacity) */
    if (opt && !strcmp( opt, "0" )) return;
    bytes = madeira_disk_capacity_from_prefix( config_dir_fd );
    if (!bytes)
    {
        fprintf( stderr, "[storage-device] v1 prefix filesystem unavailable; no disk published\n" );
        return;
    }
    storage_name( "\\Device\\Harddisk0", nameW, &name );
    struct object_params params = { .ops = &storage_device_ops, .name = name,
        .attr = OBJ_PERMANENT | OBJ_CASE_INSENSITIVE };
    if (!(device = create_named_object( &params )))
    {
        fprintf( stderr, "[storage-device] v1 cannot create Harddisk0: %#x\n", get_error() );
        return;
    }
    device->disk.bytes = bytes;
    device->opens = device->ioctls = 0;
    storage_name( "\\??\\PhysicalDrive0", nameW, &name );
    link = create_obj_symlink( NULL, name, OBJ_PERMANENT | OBJ_CASE_INSENSITIVE, &device->obj, NULL );
    if (link) release_object( link );
    else fprintf( stderr, "[storage-device] v1 cannot link PhysicalDrive0: %#x\n", get_error() );
    fprintf( stderr, "[storage-device] v1 prefix disk bytes=%llu bus=virtual serial=unavailable "
             "metadata-only PhysicalDrive0=%s\n", (unsigned long long)bytes, link ? "ready" : "failed" );
    release_object( device );
}
