// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

#ifndef itch_7z_h
#define itch_7z_h

#include <stddef.h>
#include <stdint.h>

// A .7z reader for itch.io downloads (ItchArchive.swift, docs/ITCH.md). The archive is
// read from its file a piece at a time and every folder is decoded as a stream, so a
// several-GB solid archive never sits in memory. Methods: Copy, LZMA, LZMA2, the
// branch filters (x86 BCJ, ARM, ARM64, ...) and Delta through the SDK's liblzma, BCJ2
// here, Deflate through zlib. Encrypted archives, PPMd and BZip2 are refused with a
// reason code.

enum {
    I7Z_OK = 0,
    I7Z_NOT_7Z = 1,
    I7Z_DAMAGED = 2,
    I7Z_UNSUPPORTED = 3,
    I7Z_ABORTED = 4,
    I7Z_MEMORY = 5,
    I7Z_IO = 6,
};

enum {
    I7Z_ITEM_DIR = 1,       // a folder
    I7Z_ITEM_LINK = 2,      // a symbolic link (Unix mode in the attributes)
    I7Z_ITEM_ANTI = 4,      // an "anti" item of an update archive: nothing to unpack
    I7Z_ITEM_STREAM = 8,    // has data (else an empty file or a folder)
};

enum { I7Z_BEGIN = 0, I7Z_DATA = 1, I7Z_END = 2 };

typedef struct i7z i7z;

/// The sink for unpacked data: I7Z_BEGIN, then I7Z_DATA pieces, then I7Z_END for every
/// item with I7Z_ITEM_STREAM, in archive order. A non-zero return stops the unpack
/// (I7Z_ABORTED).
typedef int (*i7z_sink)(void *context, int event, uint32_t item, const uint8_t *data, size_t length);

/// Whether the file starts with the 7z signature.
int i7z_is_7z(const char *path);

/// Reads the archive's header. On failure *out is NULL and `reason` holds a short code.
int i7z_open(const char *path, i7z **out, char *reason, size_t reason_size);
uint32_t i7z_count(const i7z *z);
/// UTF-8, "/" or "\\" separators as stored.
const char *i7z_name(const i7z *z, uint32_t item);
int i7z_flags(const i7z *z, uint32_t item);
uint64_t i7z_size(const i7z *z, uint32_t item);
uint64_t i7z_total(const i7z *z);
/// Unpacks every item with data to `sink`, CRC-checked. On failure `reason` holds a short code.
int i7z_extract(i7z *z, i7z_sink sink, void *context, char *reason, size_t reason_size);
void i7z_close(i7z *z);

#endif
