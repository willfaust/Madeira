/* GPL-3.0-or-later WITH the Madeira Converter Exception, version 1. */
#ifndef MADEIRA_STORAGE_DEVICE_IOS_H
#define MADEIRA_STORAGE_DEVICE_IOS_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <fcntl.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "winioctl.h"
#include "ntddstor.h"

/* Metadata for the virtual disk containing the prefix, not a raw host disk.
 * No manufacturer, hardware serial or physical-media capabilities are inferred. */
struct madeira_disk_info { uint64_t bytes; };

/* The ProductId a program reads from the disk. The descriptor's product field
 * is sized from this literal, so it and the copy below can never disagree
 * about the length. */
#define MADEIRA_DISK_PRODUCT "Madeira virtual disk"

static inline uint64_t madeira_disk_capacity( uint64_t blocks, uint64_t block_size )
{
    if (!blocks || !block_size || blocks > INT64_MAX / block_size) return 0;
    return blocks * block_size;
}

/* request_ios.c already holds the prefix directory open. Resolve c: relative
 * to that fd, even if another thread changes cwd; follow the normal drive
 * symlink so capacity belongs to the filesystem actually backing the drive. */
static inline uint64_t madeira_disk_capacity_from_prefix( int prefix_fd )
{
    struct statvfs fs;
    uint64_t bytes = 0;
    int fd;
    if (prefix_fd < 0 ||
        (fd = openat( prefix_fd, "dosdevices/c:", O_RDONLY | O_DIRECTORY | O_CLOEXEC )) == -1)
        return 0;
    if (!fstatvfs( fd, &fs ))
        bytes = madeira_disk_capacity( fs.f_blocks, fs.f_frsize ? fs.f_frsize : fs.f_bsize );
    close( fd );
    return bytes;
}

static inline unsigned int madeira_disk_copy_reply( const void *value, size_t size,
                                                    void *out, size_t out_size, size_t *written )
{
    if (!out || out_size < size) return STATUS_BUFFER_TOO_SMALL;
    memcpy( out, value, size );
    *written = size;
    return STATUS_SUCCESS;
}

/* All supported requests are METHOD_BUFFERED and complete synchronously.
 * The caller owns the output scratch space; errors leave it intact and report zero bytes. */
static inline unsigned int madeira_disk_ioctl( const struct madeira_disk_info *disk,
                                               unsigned int code, const void *in, size_t in_size,
                                               void *out, size_t out_size, size_t *written )
{
    DISK_GEOMETRY geometry = {0};
    *written = 0;
    if (!disk->bytes || disk->bytes > INT64_MAX) return STATUS_DEVICE_NOT_READY;
    geometry.Cylinders.QuadPart = disk->bytes / (512u * 255u * 63u);
    geometry.MediaType = FixedMedia;
    geometry.TracksPerCylinder = 255;
    geometry.SectorsPerTrack = 63;
    geometry.BytesPerSector = 512;

    switch (code)
    {
    case IOCTL_STORAGE_GET_DEVICE_NUMBER:
    {
        const STORAGE_DEVICE_NUMBER number = { FILE_DEVICE_DISK, 0, 0 };
        return madeira_disk_copy_reply( &number, sizeof(number), out, out_size, written );
    }
    case IOCTL_DISK_GET_DRIVE_GEOMETRY:
        return madeira_disk_copy_reply( &geometry, sizeof(geometry), out, out_size, written );
    case IOCTL_DISK_GET_DRIVE_GEOMETRY_EX:
    {
        DISK_GEOMETRY_EX value = {0};
        value.Geometry = geometry;
        value.DiskSize.QuadPart = disk->bytes;
        return madeira_disk_copy_reply( &value, sizeof(value), out, out_size, written );
    }
    case IOCTL_DISK_GET_LENGTH_INFO:
    {
        struct { LARGE_INTEGER Length; } value;
        value.Length.QuadPart = disk->bytes;
        return madeira_disk_copy_reply( &value, sizeof(value), out, out_size, written );
    }
    case IOCTL_STORAGE_QUERY_PROPERTY:
    {
        STORAGE_PROPERTY_QUERY query;
        struct { STORAGE_DEVICE_DESCRIPTOR descriptor; char product[sizeof(MADEIRA_DISK_PRODUCT)]; } value = {0};
        if (!in || in_size < sizeof(query)) return STATUS_INVALID_PARAMETER;
        memcpy( &query, in, sizeof(query) );
        if (query.PropertyId != StorageDeviceProperty) return STATUS_NOT_SUPPORTED;
        if (query.QueryType == PropertyExistsQuery) return STATUS_SUCCESS;
        if (query.QueryType != PropertyStandardQuery) return STATUS_NOT_SUPPORTED;
        value.descriptor.Version = sizeof(value.descriptor);
        value.descriptor.Size = offsetof(__typeof__(value), product) + sizeof(value.product);
        value.descriptor.BusType = BusTypeVirtual;
        value.descriptor.ProductIdOffset = offsetof(__typeof__(value), product);
        memcpy( value.product, MADEIRA_DISK_PRODUCT, sizeof(value.product) );
        /* The standard two-step descriptor query: a header gives the full
         * required size without touching any bytes beyond that header. */
        if (out_size < value.descriptor.Size)
            return madeira_disk_copy_reply( &value, sizeof(STORAGE_DESCRIPTOR_HEADER), out, out_size, written );
        return madeira_disk_copy_reply( &value, value.descriptor.Size, out, out_size, written );
    }
    default:
        return STATUS_NOT_SUPPORTED;
    }
}
#endif
