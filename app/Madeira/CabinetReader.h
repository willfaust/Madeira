// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// A reader for Microsoft Cabinet files held in memory: stored and MSZIP folders, which is
// what Microsoft's own installers carry (VCRedist.swift takes the Visual C++ runtime DLLs out
// of vc_redist.x64.exe and vc_redist.x86.exe with it). Written from the Cabinet File Format
// specification; LZX and Quantum folders are refused. tests/host/check-vcredist.py compiles
// it on the host and runs it over the real installers.

#ifndef MADEIRA_CABINET_READER_H
#define MADEIRA_CABINET_READER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct madeira_cab madeira_cab;

enum {
    MADEIRA_CAB_OK = 0,
    MADEIRA_CAB_BAD_HEADER = 1,       /* not a cabinet, or a header the reader does not understand */
    MADEIRA_CAB_TRUNCATED = 2,        /* the cabinet claims more than the bytes given */
    MADEIRA_CAB_UNSUPPORTED = 3,      /* a folder compressed with LZX or Quantum */
    MADEIRA_CAB_BAD_DATA = 4,         /* a data block that does not inflate, or lies about its size */
    MADEIRA_CAB_NO_MEMORY = 5,
    MADEIRA_CAB_BAD_INDEX = 6,        /* no such file, or the output buffer is too small */
    MADEIRA_CAB_CONTINUED = 7,        /* the file continues in another cabinet */
    MADEIRA_CAB_TOO_LARGE = 8,        /* a folder larger than the reader is willing to hold in memory */
};

/* Opens the cabinet at `bytes` (`length` bytes available from there; the cabinet may be
 * shorter). The bytes must stay valid until madeira_cab_close. */
int madeira_cab_open(const void *bytes, size_t length, madeira_cab **out);
void madeira_cab_close(madeira_cab *cab);

/* cbCabinet: the cabinet's own length, so a container of several cabinets can be walked. */
size_t madeira_cab_length(const madeira_cab *cab);
unsigned madeira_cab_file_count(const madeira_cab *cab);
/* NUL-terminated, at most 255 bytes, as stored (the caller decides on case). */
const char *madeira_cab_file_name(const madeira_cab *cab, unsigned index);
uint32_t madeira_cab_file_size(const madeira_cab *cab, unsigned index);

/* Copies one file into `out` (`capacity` at least its size). The file's folder is
 * decompressed on first use and kept until madeira_cab_close. */
int madeira_cab_extract(madeira_cab *cab, unsigned index, void *out, size_t capacity);

const char *madeira_cab_strerror(int code);

#ifdef __cplusplus
}
#endif

#endif /* MADEIRA_CABINET_READER_H */
