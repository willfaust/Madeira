// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Cabinet reader (CabinetReader.h). The format, little-endian throughout:
//
//   CFHEADER  "MSCF", reserved1, cbCabinet, reserved2, coffFiles, reserved3, versionMinor,
//             versionMajor, cFolders, cFiles, flags, setID, iCabinet; when flags has
//             RESERVE_PRESENT: cbCFHeader (u16), cbCFFolder (u8), cbCFData (u8), then
//             cbCFHeader reserved bytes. PREV_CABINET / NEXT_CABINET add strings after that,
//             which this reader skips; a file that continues into the next cabinet is refused.
//   CFFOLDER  coffCabStart, cCFData, typeCompress, cbCFFolder reserved bytes.
//   CFFILE    cbFile, uoffFolderStart, iFolder, date, time, attribs, szName (NUL-terminated).
//   CFDATA    csum, cbData, cbUncomp, cbCFData reserved bytes, cbData bytes.
//
// A folder's files are byte ranges of the concatenation of its blocks' output. An MSZIP block
// is "CK" followed by one raw deflate stream whose output is at most 32 KiB and which may refer
// to the previous 32 KiB of the folder's output: each block is inflated with that output as
// the preset dictionary. The block checksums are not verified: the caller checks what it takes
// out (VCRedist.swift verifies the PE machine, the signature directory and the version).

#include "CabinetReader.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

enum {
    CAB_HEADER_BYTES = 36,
    CAB_FOLDER_BYTES = 8,
    CAB_FILE_BYTES = 16,
    CAB_DATA_BYTES = 8,
    CAB_BLOCK_MAX = 32768,
    CAB_NAME_MAX = 255,
    CAB_FOLDER_MAX = 256u << 20,          /* the most a decompressed folder may take: 256 MiB */
    CAB_FILES_MAX = 65535,
    CAB_FLAG_PREV = 1, CAB_FLAG_NEXT = 2, CAB_FLAG_RESERVE = 4,
    CAB_COMPRESS_NONE = 0, CAB_COMPRESS_MSZIP = 1,
    CAB_FOLDER_CONTINUED = 0xFFFD,         /* iFolder values from here up: continued elsewhere */
};

typedef struct {
    uint32_t first;                    /* coffCabStart */
    uint32_t blocks;                   /* cCFData */
    uint32_t type;                     /* typeCompress & 0xF */
    uint8_t *data;                     /* the decompressed folder, once used */
    size_t size;                       /* its length */
} cab_folder;

typedef struct {
    uint32_t size;
    uint32_t offset;
    uint32_t folder;
    char name[CAB_NAME_MAX + 1];
} cab_file;

struct madeira_cab {
    const uint8_t *bytes;
    size_t length;                     /* bytes available */
    size_t cabinet;                    /* cbCabinet */
    unsigned data_reserve;             /* cbCFData */
    unsigned folder_count, file_count;
    cab_folder *folders;
    cab_file *files;
};

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

/* Skips a NUL-terminated string at *pos (bounded); 0 if it runs off the end. */
static int skip_string(const madeira_cab *cab, size_t *pos)
{
    size_t p = *pos;
    while (p < cab->length && cab->bytes[p]) p++;
    if (p >= cab->length) return 0;
    *pos = p + 1;
    return 1;
}

int madeira_cab_open(const void *bytes, size_t length, madeira_cab **out)
{
    const uint8_t *b = bytes;
    *out = NULL;
    if (!b || length < CAB_HEADER_BYTES) return MADEIRA_CAB_BAD_HEADER;
    if (memcmp(b, "MSCF", 4) != 0 || rd32(b + 4) != 0 || rd32(b + 12) != 0 || rd32(b + 20) != 0) return MADEIRA_CAB_BAD_HEADER;
    uint32_t cabinet = rd32(b + 8), files_at = rd32(b + 16);
    unsigned minor = b[24], major = b[25];
    unsigned folders = rd16(b + 26), files = rd16(b + 28), flags = rd16(b + 30);
    if (major != 1 || minor != 3 || folders == 0 || files == 0 || files > CAB_FILES_MAX) return MADEIRA_CAB_BAD_HEADER;
    if (cabinet < CAB_HEADER_BYTES || cabinet > length) return MADEIRA_CAB_TRUNCATED;

    madeira_cab *cab = calloc(1, sizeof *cab);
    if (!cab) return MADEIRA_CAB_NO_MEMORY;
    cab->bytes = b;
    cab->length = cabinet;             /* nothing past cbCabinet belongs to this cabinet */
    cab->cabinet = cabinet;

    size_t pos = CAB_HEADER_BYTES;
    unsigned folder_reserve = 0;
    if (flags & CAB_FLAG_RESERVE) {
        if (pos + 4 > cab->length) { free(cab); return MADEIRA_CAB_TRUNCATED; }
        unsigned header_reserve = rd16(b + pos);
        folder_reserve = b[pos + 2];
        cab->data_reserve = b[pos + 3];
        pos += 4;
        if (pos + header_reserve > cab->length) { free(cab); return MADEIRA_CAB_TRUNCATED; }
        pos += header_reserve;
    }
    if (flags & CAB_FLAG_PREV) { if (!skip_string(cab, &pos) || !skip_string(cab, &pos)) { free(cab); return MADEIRA_CAB_TRUNCATED; } }
    if (flags & CAB_FLAG_NEXT) { if (!skip_string(cab, &pos) || !skip_string(cab, &pos)) { free(cab); return MADEIRA_CAB_TRUNCATED; } }

    cab->folders = calloc(folders, sizeof *cab->folders);
    cab->files = calloc(files, sizeof *cab->files);
    if (!cab->folders || !cab->files) { madeira_cab_close(cab); return MADEIRA_CAB_NO_MEMORY; }
    cab->folder_count = folders;
    cab->file_count = files;

    for (unsigned i = 0; i < folders; i++) {
        if (pos + CAB_FOLDER_BYTES + folder_reserve > cab->length) { madeira_cab_close(cab); return MADEIRA_CAB_TRUNCATED; }
        cab->folders[i].first = rd32(b + pos);
        cab->folders[i].blocks = rd16(b + pos + 4);
        cab->folders[i].type = rd16(b + pos + 6) & 0xF;
        pos += CAB_FOLDER_BYTES + folder_reserve;
    }

    pos = files_at;
    for (unsigned i = 0; i < files; i++) {
        if (pos + CAB_FILE_BYTES > cab->length) { madeira_cab_close(cab); return MADEIRA_CAB_TRUNCATED; }
        cab_file *f = &cab->files[i];
        f->size = rd32(b + pos);
        f->offset = rd32(b + pos + 4);
        f->folder = rd16(b + pos + 8);
        pos += CAB_FILE_BYTES;
        size_t n = 0;
        while (pos + n < cab->length && b[pos + n] && n < CAB_NAME_MAX) n++;
        if (pos + n >= cab->length || b[pos + n]) { madeira_cab_close(cab); return MADEIRA_CAB_BAD_HEADER; }   /* no NUL within 255 bytes */
        memcpy(f->name, b + pos, n);
        f->name[n] = 0;
        pos += n + 1;
    }
    *out = cab;
    return MADEIRA_CAB_OK;
}

void madeira_cab_close(madeira_cab *cab)
{
    if (!cab) return;
    if (cab->folders) {
        for (unsigned i = 0; i < cab->folder_count; i++) free(cab->folders[i].data);
        free(cab->folders);
    }
    free(cab->files);
    free(cab);
}

size_t madeira_cab_length(const madeira_cab *cab) { return cab ? cab->cabinet : 0; }
unsigned madeira_cab_file_count(const madeira_cab *cab) { return cab ? cab->file_count : 0; }
const char *madeira_cab_file_name(const madeira_cab *cab, unsigned index)
{
    return cab && index < cab->file_count ? cab->files[index].name : NULL;
}
uint32_t madeira_cab_file_size(const madeira_cab *cab, unsigned index)
{
    return cab && index < cab->file_count ? cab->files[index].size : 0;
}

/* Decompresses a folder's blocks into folder->data. */
static int unpack_folder(madeira_cab *cab, cab_folder *folder)
{
    if (folder->data) return MADEIRA_CAB_OK;
    if (folder->type != CAB_COMPRESS_NONE && folder->type != CAB_COMPRESS_MSZIP) return MADEIRA_CAB_UNSUPPORTED;

    /* First pass: the output size from the block headers. */
    size_t pos = folder->first, total = 0;
    for (uint32_t i = 0; i < folder->blocks; i++) {
        if (pos + CAB_DATA_BYTES + cab->data_reserve > cab->length) return MADEIRA_CAB_TRUNCATED;
        unsigned packed = rd16(cab->bytes + pos + 4), unpacked = rd16(cab->bytes + pos + 6);
        if (unpacked > CAB_BLOCK_MAX) return MADEIRA_CAB_BAD_DATA;
        pos += CAB_DATA_BYTES + cab->data_reserve;
        if (pos + packed > cab->length) return MADEIRA_CAB_TRUNCATED;
        pos += packed;
        total += unpacked;
        if (total > CAB_FOLDER_MAX) return MADEIRA_CAB_TOO_LARGE;
    }
    uint8_t *out = malloc(total ? total : 1);
    if (!out) return MADEIRA_CAB_NO_MEMORY;

    z_stream z;
    memset(&z, 0, sizeof z);
    int z_ready = 0, result = MADEIRA_CAB_OK;
    size_t done = 0;
    pos = folder->first;
    for (uint32_t i = 0; i < folder->blocks && result == MADEIRA_CAB_OK; i++) {
        const uint8_t *block = cab->bytes + pos;
        unsigned packed = rd16(block + 4), unpacked = rd16(block + 6);
        const uint8_t *payload = block + CAB_DATA_BYTES + cab->data_reserve;
        pos += CAB_DATA_BYTES + cab->data_reserve + packed;
        if (folder->type == CAB_COMPRESS_NONE) {
            if (packed != unpacked) { result = MADEIRA_CAB_BAD_DATA; break; }
            memcpy(out + done, payload, unpacked);
            done += unpacked;
            continue;
        }
        /* MSZIP: "CK", then a raw deflate stream. */
        if (packed < 2 || payload[0] != 'C' || payload[1] != 'K') { result = MADEIRA_CAB_BAD_DATA; break; }
        if (!z_ready) {
            if (inflateInit2(&z, -MAX_WBITS) != Z_OK) { result = MADEIRA_CAB_NO_MEMORY; break; }
            z_ready = 1;
        } else if (inflateReset(&z) != Z_OK) { result = MADEIRA_CAB_BAD_DATA; break; }
        if (done > 0) {
            size_t history = done < CAB_BLOCK_MAX ? done : CAB_BLOCK_MAX;
            if (inflateSetDictionary(&z, out + done - history, (uInt)history) != Z_OK) { result = MADEIRA_CAB_BAD_DATA; break; }
        }
        z.next_in = (Bytef *)(payload + 2);
        z.avail_in = packed - 2;
        z.next_out = out + done;
        z.avail_out = unpacked;
        int zr = inflate(&z, Z_FINISH);
        if ((zr != Z_STREAM_END && zr != Z_OK && zr != Z_BUF_ERROR) || z.avail_out != 0) { result = MADEIRA_CAB_BAD_DATA; break; }
        done += unpacked;
    }
    if (z_ready) inflateEnd(&z);
    if (result != MADEIRA_CAB_OK || done != total) { free(out); return result != MADEIRA_CAB_OK ? result : MADEIRA_CAB_BAD_DATA; }
    folder->data = out;
    folder->size = total;
    return MADEIRA_CAB_OK;
}

int madeira_cab_extract(madeira_cab *cab, unsigned index, void *out, size_t capacity)
{
    if (!cab || index >= cab->file_count || !out) return MADEIRA_CAB_BAD_INDEX;
    cab_file *file = &cab->files[index];
    if (file->folder >= CAB_FOLDER_CONTINUED) return MADEIRA_CAB_CONTINUED;
    if (file->folder >= cab->folder_count) return MADEIRA_CAB_BAD_HEADER;
    if (capacity < file->size) return MADEIRA_CAB_BAD_INDEX;
    cab_folder *folder = &cab->folders[file->folder];
    int rc = unpack_folder(cab, folder);
    if (rc != MADEIRA_CAB_OK) return rc;
    if ((size_t)file->offset + file->size > folder->size) return MADEIRA_CAB_BAD_DATA;
    memcpy(out, folder->data + file->offset, file->size);
    return MADEIRA_CAB_OK;
}

const char *madeira_cab_strerror(int code)
{
    switch (code) {
    case MADEIRA_CAB_OK: return "ok";
    case MADEIRA_CAB_BAD_HEADER: return "not a cabinet this reader understands";
    case MADEIRA_CAB_TRUNCATED: return "the cabinet is cut short";
    case MADEIRA_CAB_UNSUPPORTED: return "a folder uses a compression this reader does not have";
    case MADEIRA_CAB_BAD_DATA: return "a data block does not unpack";
    case MADEIRA_CAB_NO_MEMORY: return "out of memory";
    case MADEIRA_CAB_BAD_INDEX: return "no such file, or the buffer is too small";
    case MADEIRA_CAB_CONTINUED: return "the file continues in another cabinet";
    case MADEIRA_CAB_TOO_LARGE: return "a folder is too large to unpack in memory";
    default: return "unknown error";
    }
}
