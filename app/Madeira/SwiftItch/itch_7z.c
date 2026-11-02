// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// A streaming .7z reader for itch.io downloads; see itch_7z.h. Written for Madeira
// from the published 7z format description (7-Zip's DOC/7zFormat.txt). The archive's
// header is read whole (it is small: names and sizes), the data never is: each folder
// is a chain of pull readers (packed bytes -> decoders -> the folder's output), and the
// output is cut into the folder's files as it comes.

#include "itch_7z.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

// ---- liblzma: the SDK ships liblzma.tbd without headers (as SwiftSteam/lzma_shim.c) ----

typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;
    const void *allocator;
    void *internal;
    void *reserved_ptr1, *reserved_ptr2, *reserved_ptr3, *reserved_ptr4;
    uint64_t reserved_int1, reserved_int2;
    size_t reserved_int3, reserved_int4;
    int reserved_enum1, reserved_enum2;
} i7z_lzma_stream;

typedef struct {
    uint64_t id;
    void *options;
} i7z_lzma_filter;

extern int lzma_raw_decoder(i7z_lzma_stream *strm, const i7z_lzma_filter *filters);
extern int lzma_properties_decode(i7z_lzma_filter *filter, const void *allocator, const uint8_t *props, size_t props_size);
extern int lzma_code(i7z_lzma_stream *strm, int action);
extern void lzma_end(i7z_lzma_stream *strm);

#define LZMA_OK_ 0
#define LZMA_STREAM_END_ 1
#define LZMA_MEM_ERROR_ 5
#define LZMA_OPTIONS_ERROR_ 8
#define LZMA_BUF_ERROR_ 10
#define LZMA_RUN_ 0
#define LZMA_FINISH_ 3
#define LZMA_VLI_UNKNOWN_ UINT64_MAX
#define LZMA_FILTER_LZMA1_ 0x4000000000000001ULL
#define LZMA_FILTER_LZMA2_ 0x21ULL

// ---- limits ----

#define MAX_HEADER (256u << 20)
#define MAX_ITEMS 2000000u
#define MAX_FOLDERS 1000000u
#define MAX_CODERS 32u
#define MAX_CHAIN 4
#define CHUNK (1u << 16)

// ---- errors ----

typedef struct {
    int code;
    char reason[64];
} status_t;

static int fail(status_t *s, int code, const char *reason) {
    if (s->code == I7Z_OK) {
        s->code = code;
        snprintf(s->reason, sizeof(s->reason), "%s", reason);
    }
    return code;
}

// ---- the archive ----

typedef struct {
    uint8_t id[15];
    uint8_t id_size;
    uint32_t num_in;      // packed side; every coder has one unpacked output
    uint32_t first_in;    // the coder's first in-stream index within the folder
    const uint8_t *props; // into the header buffer
    size_t props_size;
} coder_t;

typedef struct {
    uint32_t in_index, out_index;
} bind_t;

typedef struct {
    uint32_t num_coders;
    coder_t coders[MAX_CODERS];
    uint32_t num_binds;
    bind_t binds[MAX_CODERS];
    uint32_t num_packed;
    uint32_t packed[MAX_CODERS];
    uint64_t unpack[MAX_CODERS]; // per coder
    uint32_t total_in;
    uint32_t main;               // the coder whose output is the folder's
    uint32_t first_pack;         // the folder's first pack stream
    uint32_t num_sub;            // files in this folder
    uint32_t crc;
    int crc_defined;
} folder_t;

typedef struct {
    uint64_t pack_pos;
    uint32_t num_pack;
    uint64_t *pack_sizes;
    uint64_t *pack_offsets;      // absolute file offsets
    uint32_t num_folders;
    folder_t *folders;
    uint32_t num_sub_total;
    uint64_t *sub_sizes;
    uint32_t *sub_crcs;
    uint8_t *sub_crc_defined;
} streams_t;

typedef struct {
    char *name;
    uint64_t size;
    int flags;
} item_t;

struct i7z {
    int fd;
    uint64_t length;
    uint8_t *header;          // the (decoded) header; coder props point into it
    uint8_t *raw_header;
    streams_t streams;
    uint32_t count;
    item_t *items;
    uint64_t total;
};

static void streams_free(streams_t *s) {
    free(s->pack_sizes); free(s->pack_offsets); free(s->folders);
    free(s->sub_sizes); free(s->sub_crcs); free(s->sub_crc_defined);
    memset(s, 0, sizeof(*s));
}

// ---- header bytes ----

typedef struct {
    const uint8_t *p, *end;
    status_t *st;
} buf_t;

static int bad(buf_t *b) { return b->st->code != I7Z_OK; }

static uint8_t rd_byte(buf_t *b) {
    if (b->p >= b->end) { fail(b->st, I7Z_DAMAGED, "header-short"); return 0; }
    return *b->p++;
}

static uint64_t rd_number(buf_t *b) {
    uint8_t first = rd_byte(b), mask = 0x80;
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) {
        if ((first & mask) == 0) {
            uint64_t high = first & (mask - 1u);
            return value | (high << (8 * i));
        }
        value |= (uint64_t)rd_byte(b) << (8 * i);
        mask >>= 1;
    }
    return value;
}

static uint32_t rd_u32(buf_t *b) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v |= (uint32_t)rd_byte(b) << (8 * i);
    return v;
}

static void rd_skip(buf_t *b, uint64_t n) {
    if (n > (uint64_t)(b->end - b->p)) { fail(b->st, I7Z_DAMAGED, "header-short"); b->p = b->end; return; }
    b->p += n;
}

static uint8_t *rd_bits(buf_t *b, uint32_t count) {
    uint8_t *v = calloc(count ? count : 1, 1);
    if (!v) { fail(b->st, I7Z_MEMORY, "memory"); return NULL; }
    uint8_t byte = 0, mask = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (mask == 0) { byte = rd_byte(b); mask = 0x80; }
        v[i] = (byte & mask) != 0;
        mask >>= 1;
    }
    return v;
}

// Digests: "all defined" or a bit vector, then a CRC for every defined one.
static int rd_digests(buf_t *b, uint32_t count, uint32_t *crcs, uint8_t *defined) {
    uint8_t all = rd_byte(b);
    uint8_t *set = all ? NULL : rd_bits(b, count);
    if (!all && !set) return -1;
    for (uint32_t i = 0; i < count; i++) {
        int d = all ? 1 : set[i];
        if (defined) defined[i] = (uint8_t)d;
        uint32_t crc = d ? rd_u32(b) : 0;
        if (crcs) crcs[i] = crc;
    }
    free(set);
    return bad(b) ? -1 : 0;
}

enum {
    kEnd = 0x00, kHeader = 0x01, kArchiveProperties = 0x02, kAdditionalStreamsInfo = 0x03,
    kMainStreamsInfo = 0x04, kFilesInfo = 0x05, kPackInfo = 0x06, kUnpackInfo = 0x07,
    kSubStreamsInfo = 0x08, kSize = 0x09, kCRC = 0x0A, kFolder = 0x0B, kCodersUnpackSize = 0x0C,
    kNumUnpackStream = 0x0D, kEmptyStream = 0x0E, kEmptyFile = 0x0F, kAnti = 0x10, kName = 0x11,
    kWinAttributes = 0x15, kEncodedHeader = 0x17, kDummy = 0x19,
};

static int parse_folder(buf_t *b, folder_t *f) {
    memset(f, 0, sizeof(*f));
    uint64_t n = rd_number(b);
    if (bad(b)) return -1;
    if (n == 0 || n > MAX_CODERS) return fail(b->st, I7Z_UNSUPPORTED, "coders");
    f->num_coders = (uint32_t)n;
    uint32_t total_in = 0;
    for (uint32_t i = 0; i < f->num_coders; i++) {
        coder_t *c = &f->coders[i];
        uint8_t flags = rd_byte(b);
        if (flags & 0x80) return fail(b->st, I7Z_UNSUPPORTED, "coder-alternatives");
        c->id_size = flags & 0x0f;
        if (c->id_size > sizeof(c->id)) return fail(b->st, I7Z_DAMAGED, "coder-id");
        for (uint8_t k = 0; k < c->id_size; k++) c->id[k] = rd_byte(b);
        c->num_in = 1;
        if (flags & 0x10) {
            uint64_t ins = rd_number(b), outs = rd_number(b);
            if (bad(b)) return -1;
            if (outs != 1 || ins == 0 || ins > MAX_CODERS) return fail(b->st, I7Z_UNSUPPORTED, "coder-streams");
            c->num_in = (uint32_t)ins;
        }
        if (flags & 0x20) {
            uint64_t size = rd_number(b);
            if (bad(b)) return -1;
            c->props = b->p;
            c->props_size = (size_t)size;
            rd_skip(b, size);
        }
        c->first_in = total_in;
        total_in += c->num_in;
        if (total_in > MAX_CODERS) return fail(b->st, I7Z_UNSUPPORTED, "coder-streams");
    }
    f->total_in = total_in;
    f->num_binds = f->num_coders - 1;
    for (uint32_t i = 0; i < f->num_binds; i++) {
        uint64_t in = rd_number(b), out = rd_number(b);
        if (bad(b)) return -1;
        if (in >= total_in || out >= f->num_coders) return fail(b->st, I7Z_DAMAGED, "bind");
        f->binds[i].in_index = (uint32_t)in;
        f->binds[i].out_index = (uint32_t)out;
    }
    if (total_in < f->num_binds) return fail(b->st, I7Z_DAMAGED, "bind");
    f->num_packed = total_in - f->num_binds;
    if (f->num_packed == 1) {
        uint32_t i;
        for (i = 0; i < total_in; i++) {
            int bound = 0;
            for (uint32_t k = 0; k < f->num_binds; k++) if (f->binds[k].in_index == i) bound = 1;
            if (!bound) break;
        }
        if (i == total_in) return fail(b->st, I7Z_DAMAGED, "packed");
        f->packed[0] = i;
    } else {
        for (uint32_t i = 0; i < f->num_packed; i++) {
            uint64_t v = rd_number(b);
            if (bad(b)) return -1;
            if (v >= total_in) return fail(b->st, I7Z_DAMAGED, "packed");
            f->packed[i] = (uint32_t)v;
        }
    }
    // The folder's output: the one coder output no bind pair consumes.
    uint32_t mains = 0;
    for (uint32_t i = 0; i < f->num_coders; i++) {
        int bound = 0;
        for (uint32_t k = 0; k < f->num_binds; k++) if (f->binds[k].out_index == i) bound = 1;
        if (!bound) { f->main = i; mains++; }
    }
    if (mains != 1) return fail(b->st, I7Z_DAMAGED, "folder-output");
    return bad(b) ? -1 : 0;
}

static int skip_property(buf_t *b) {
    uint64_t size = rd_number(b);
    rd_skip(b, size);
    return bad(b) ? -1 : 0;
}

static int parse_streams(buf_t *b, streams_t *s, uint64_t length) {
    memset(s, 0, sizeof(*s));
    uint64_t type = rd_number(b);
    if (type == kPackInfo) {
        s->pack_pos = rd_number(b);
        uint64_t n = rd_number(b);
        if (bad(b)) return -1;
        if (n > MAX_FOLDERS * 4ull) return fail(b->st, I7Z_DAMAGED, "pack-count");
        s->num_pack = (uint32_t)n;
        s->pack_sizes = calloc(n ? n : 1, sizeof(uint64_t));
        s->pack_offsets = calloc(n ? n : 1, sizeof(uint64_t));
        if (!s->pack_sizes || !s->pack_offsets) return fail(b->st, I7Z_MEMORY, "memory");
        for (type = rd_number(b); type != kEnd && !bad(b); type = rd_number(b)) {
            if (type == kSize) {
                for (uint32_t i = 0; i < s->num_pack; i++) s->pack_sizes[i] = rd_number(b);
            } else if (type == kCRC) {
                if (rd_digests(b, s->num_pack, NULL, NULL) != 0) return -1;
            } else if (skip_property(b) != 0) return -1;
        }
        uint64_t at = 32 + s->pack_pos;
        for (uint32_t i = 0; i < s->num_pack; i++) {
            s->pack_offsets[i] = at;
            if (s->pack_sizes[i] > length || at > length - s->pack_sizes[i]) return fail(b->st, I7Z_DAMAGED, "pack-range");
            at += s->pack_sizes[i];
        }
        type = rd_number(b);
    }
    if (type == kUnpackInfo) {
        if (rd_number(b) != kFolder) return fail(b->st, I7Z_DAMAGED, "folders");
        uint64_t n = rd_number(b);
        if (bad(b)) return -1;
        if (n > MAX_FOLDERS) return fail(b->st, I7Z_DAMAGED, "folder-count");
        if (rd_byte(b) != 0) return fail(b->st, I7Z_UNSUPPORTED, "external");
        s->num_folders = (uint32_t)n;
        s->folders = calloc(n ? n : 1, sizeof(folder_t));
        if (!s->folders) return fail(b->st, I7Z_MEMORY, "memory");
        uint32_t pack = 0;
        for (uint32_t i = 0; i < s->num_folders; i++) {
            if (parse_folder(b, &s->folders[i]) != 0) return -1;
            s->folders[i].first_pack = pack;
            pack += s->folders[i].num_packed;
            if (pack > s->num_pack) return fail(b->st, I7Z_DAMAGED, "pack-count");
        }
        if (rd_number(b) != kCodersUnpackSize) return fail(b->st, I7Z_DAMAGED, "unpack-sizes");
        for (uint32_t i = 0; i < s->num_folders; i++)
            for (uint32_t k = 0; k < s->folders[i].num_coders; k++) s->folders[i].unpack[k] = rd_number(b);
        for (type = rd_number(b); type != kEnd && !bad(b); type = rd_number(b)) {
            if (type == kCRC) {
                uint32_t *crcs = calloc(s->num_folders ? s->num_folders : 1, 4);
                uint8_t *def = calloc(s->num_folders ? s->num_folders : 1, 1);
                if (!crcs || !def) { free(crcs); free(def); return fail(b->st, I7Z_MEMORY, "memory"); }
                if (rd_digests(b, s->num_folders, crcs, def) != 0) { free(crcs); free(def); return -1; }
                for (uint32_t i = 0; i < s->num_folders; i++) { s->folders[i].crc = crcs[i]; s->folders[i].crc_defined = def[i]; }
                free(crcs); free(def);
            } else if (skip_property(b) != 0) return -1;
        }
        type = rd_number(b);
    }
    for (uint32_t i = 0; i < s->num_folders; i++) s->folders[i].num_sub = 1;
    int have_sizes = 0;
    if (type == kSubStreamsInfo) {
        type = rd_number(b);
        if (type == kNumUnpackStream) {
            for (uint32_t i = 0; i < s->num_folders; i++) {
                uint64_t v = rd_number(b);
                if (v > MAX_ITEMS) return fail(b->st, I7Z_DAMAGED, "substreams");
                s->folders[i].num_sub = (uint32_t)v;
            }
            type = rd_number(b);
        }
        uint64_t total = 0;
        for (uint32_t i = 0; i < s->num_folders; i++) total += s->folders[i].num_sub;
        if (total > MAX_ITEMS) return fail(b->st, I7Z_DAMAGED, "substreams");
        s->num_sub_total = (uint32_t)total;
        s->sub_sizes = calloc(total ? total : 1, sizeof(uint64_t));
        s->sub_crcs = calloc(total ? total : 1, 4);
        s->sub_crc_defined = calloc(total ? total : 1, 1);
        if (!s->sub_sizes || !s->sub_crcs || !s->sub_crc_defined) return fail(b->st, I7Z_MEMORY, "memory");
        uint32_t at = 0;
        if (type == kSize) {
            for (uint32_t i = 0; i < s->num_folders; i++) {
                folder_t *f = &s->folders[i];
                if (f->num_sub == 0) continue;
                uint64_t sum = 0;
                for (uint32_t k = 1; k < f->num_sub; k++) { uint64_t v = rd_number(b); s->sub_sizes[at++] = v; sum += v; }
                if (sum > f->unpack[f->main]) return fail(b->st, I7Z_DAMAGED, "substream-size");
                s->sub_sizes[at++] = f->unpack[f->main] - sum;
            }
            have_sizes = 1;
            type = rd_number(b);
        } else {
            for (uint32_t i = 0; i < s->num_folders; i++) {
                folder_t *f = &s->folders[i];
                if (f->num_sub > 1) return fail(b->st, I7Z_DAMAGED, "substream-size");
                if (f->num_sub == 1) s->sub_sizes[at++] = f->unpack[f->main];
            }
            have_sizes = 1;
        }
        // CRCs: the folder's own for a folder of one file with a CRC, else from kCRC in order.
        uint32_t wanted = 0;
        for (uint32_t i = 0; i < s->num_folders; i++)
            if (!(s->folders[i].num_sub == 1 && s->folders[i].crc_defined)) wanted += s->folders[i].num_sub;
        uint32_t *crcs = calloc(wanted ? wanted : 1, 4);
        uint8_t *def = calloc(wanted ? wanted : 1, 1);
        if (!crcs || !def) { free(crcs); free(def); return fail(b->st, I7Z_MEMORY, "memory"); }
        for (; type != kEnd && !bad(b); type = rd_number(b)) {
            if (type == kCRC) {
                if (rd_digests(b, wanted, crcs, def) != 0) { free(crcs); free(def); return -1; }
            } else if (skip_property(b) != 0) { free(crcs); free(def); return -1; }
        }
        at = 0;
        uint32_t k = 0;
        for (uint32_t i = 0; i < s->num_folders; i++) {
            folder_t *f = &s->folders[i];
            if (f->num_sub == 1 && f->crc_defined) {
                s->sub_crcs[at] = f->crc; s->sub_crc_defined[at] = 1; at++;
            } else {
                for (uint32_t j = 0; j < f->num_sub; j++, at++, k++) { s->sub_crcs[at] = crcs[k]; s->sub_crc_defined[at] = def[k]; }
            }
        }
        free(crcs); free(def);
        type = rd_number(b);
    }
    if (!have_sizes) {
        s->num_sub_total = s->num_folders;
        s->sub_sizes = calloc(s->num_folders ? s->num_folders : 1, sizeof(uint64_t));
        s->sub_crcs = calloc(s->num_folders ? s->num_folders : 1, 4);
        s->sub_crc_defined = calloc(s->num_folders ? s->num_folders : 1, 1);
        if (!s->sub_sizes || !s->sub_crcs || !s->sub_crc_defined) return fail(b->st, I7Z_MEMORY, "memory");
        for (uint32_t i = 0; i < s->num_folders; i++) {
            folder_t *f = &s->folders[i];
            s->sub_sizes[i] = f->unpack[f->main];
            s->sub_crcs[i] = f->crc;
            s->sub_crc_defined[i] = (uint8_t)f->crc_defined;
        }
    }
    if (type != kEnd) return fail(b->st, I7Z_DAMAGED, "streams-end");
    return bad(b) ? -1 : 0;
}

// ---- pull readers ----

typedef struct reader reader;
struct reader {
    long (*read)(reader *r, uint8_t *out, size_t n); // > 0 bytes, 0 at the end, < 0 failed
    void (*close)(reader *r);
    status_t *st;
};

static void reader_close(reader *r) { if (r) r->close(r); }

typedef struct {
    reader base;
    int fd;
    uint64_t at, left;
} pack_reader;

static long pack_read(reader *r, uint8_t *out, size_t n) {
    pack_reader *p = (pack_reader *)r;
    if (p->left == 0) return 0;
    if (n > p->left) n = (size_t)p->left;
    ssize_t got;
    do { got = pread(p->fd, out, n, (off_t)p->at); } while (got < 0 && errno == EINTR);
    if (got < 0) { fail(r->st, I7Z_IO, "read"); return -1; }
    if (got == 0) { fail(r->st, I7Z_DAMAGED, "short-read"); return -1; }
    p->at += (uint64_t)got; p->left -= (uint64_t)got;
    return got;
}

static void pack_close(reader *r) { free(r); }

typedef struct {
    reader base;
    reader *up;
    i7z_lzma_stream strm;
    int up_end, ended;
    uint64_t left;
    uint8_t in[CHUNK];
} lzma_reader;

static long lzma_read(reader *r, uint8_t *out, size_t n) {
    lzma_reader *z = (lzma_reader *)r;
    if (z->left == 0 || z->ended) return 0;
    if (n > z->left) n = (size_t)z->left;
    z->strm.next_out = out;
    z->strm.avail_out = n;
    for (;;) {
        if (z->strm.avail_in == 0 && !z->up_end) {
            long got = z->up->read(z->up, z->in, sizeof(z->in));
            if (got < 0) return -1;
            if (got == 0) z->up_end = 1;
            z->strm.next_in = z->in;
            z->strm.avail_in = (size_t)got;
        }
        size_t before = z->strm.avail_out;
        // LZMA without an end marker gives its last bytes only once told the input ended.
        int ret = lzma_code(&z->strm, z->up_end ? LZMA_FINISH_ : LZMA_RUN_);
        if (ret == LZMA_STREAM_END_) { z->ended = 1; break; }
        if (ret == LZMA_MEM_ERROR_) { fail(r->st, I7Z_MEMORY, "lzma-memory"); return -1; }
        if (ret != LZMA_OK_ && ret != LZMA_BUF_ERROR_) { fail(r->st, I7Z_DAMAGED, "lzma"); return -1; }
        if (z->strm.avail_out == 0) break;
        if (z->strm.avail_out < before && z->strm.avail_in == 0) break; // hand over what is there
        if (z->up_end && z->strm.avail_in == 0 && z->strm.avail_out == before) break;
    }
    size_t produced = n - z->strm.avail_out;
    z->left -= produced;
    return (long)produced;
}

static void lzma_close(reader *r) {
    lzma_reader *z = (lzma_reader *)r;
    lzma_end(&z->strm);
    reader_close(z->up);
    free(z);
}

typedef struct {
    reader base;
    reader *up;
    z_stream strm;
    int up_end, ended;
    uint64_t left;
    uint8_t in[CHUNK];
} inflate_reader;

static long inflate_read(reader *r, uint8_t *out, size_t n) {
    inflate_reader *z = (inflate_reader *)r;
    if (z->left == 0 || z->ended) return 0;
    if (n > z->left) n = (size_t)z->left;
    if (n > UINT32_MAX) n = UINT32_MAX;
    z->strm.next_out = out;
    z->strm.avail_out = (uInt)n;
    for (;;) {
        if (z->strm.avail_in == 0 && !z->up_end) {
            long got = z->up->read(z->up, z->in, sizeof(z->in));
            if (got < 0) return -1;
            if (got == 0) z->up_end = 1;
            z->strm.next_in = z->in;
            z->strm.avail_in = (uInt)got;
        }
        uInt before = z->strm.avail_out;
        int ret = inflate(&z->strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) { z->ended = 1; break; }
        if (ret != Z_OK && ret != Z_BUF_ERROR) { fail(r->st, I7Z_DAMAGED, "inflate"); return -1; }
        if (z->strm.avail_out == 0) break;
        if (z->strm.avail_out < before && z->strm.avail_in == 0) break;
        if (z->up_end && z->strm.avail_in == 0 && z->strm.avail_out == before) break;
    }
    size_t produced = n - z->strm.avail_out;
    z->left -= produced;
    return (long)produced;
}

static void inflate_close(reader *r) {
    inflate_reader *z = (inflate_reader *)r;
    inflateEnd(&z->strm);
    reader_close(z->up);
    free(z);
}

// Branch filters over data that is not LZMA (Copy, Deflate, BCJ2): liblzma runs filters
// only in front of LZMA or LZMA2, so the data goes in as LZMA2 "uncompressed" chunks
// (control byte 1 or 2, the size less one big-endian, the bytes) and an end byte.
typedef struct {
    reader base;
    reader *up;
    uint8_t chunk[3 + CHUNK];
    size_t pos, len;
    int first, ended;
} wrap_reader;

static long wrap_read(reader *r, uint8_t *out, size_t n) {
    wrap_reader *w = (wrap_reader *)r;
    if (w->pos == w->len) {
        if (w->ended) return 0;
        long got = w->up->read(w->up, w->chunk + 3, CHUNK);
        if (got < 0) return -1;
        if (got == 0) { w->chunk[0] = 0; w->pos = 0; w->len = 1; w->ended = 1; }
        else {
            w->chunk[0] = w->first ? 1 : 2;
            w->chunk[1] = (uint8_t)((got - 1) >> 8);
            w->chunk[2] = (uint8_t)((got - 1) & 0xff);
            w->first = 0; w->pos = 0; w->len = 3 + (size_t)got;
        }
    }
    size_t k = w->len - w->pos;
    if (k > n) k = n;
    memcpy(out, w->chunk + w->pos, k);
    w->pos += k;
    return (long)k;
}

static void wrap_close(reader *r) {
    wrap_reader *w = (wrap_reader *)r;
    reader_close(w->up);
    free(w);
}

// BCJ2: x86 CALL/JMP/Jcc targets moved into their own streams, a range-coded bit per
// candidate opcode saying whether it was converted. Inputs: 0 main, 1 CALL, 2 JMP, 3 bits.
typedef struct {
    reader *up;
    uint8_t buf[CHUNK];
    size_t pos, len;
    int end;
} byte_in;

static int next_byte(byte_in *in, uint8_t *b) {
    if (in->pos == in->len) {
        if (in->end) return 0;
        long got = in->up->read(in->up, in->buf, sizeof(in->buf));
        if (got < 0) return -1;
        if (got == 0) { in->end = 1; return 0; }
        in->pos = 0; in->len = (size_t)got;
    }
    *b = in->buf[in->pos++];
    return 1;
}

typedef struct {
    reader base;
    byte_in in[4];
    uint16_t probs[258];
    uint32_t range, code;
    int started;
    uint8_t prev;
    uint8_t pending[4];
    int pend, pend_at;
    uint64_t done, size;
} bcj2_reader;

static int bcj2_rc_byte(bcj2_reader *j, uint8_t *b) {
    int r = next_byte(&j->in[3], b);
    if (r == 0) fail(j->base.st, I7Z_DAMAGED, "bcj2");
    return r == 1 ? 0 : -1;
}

static long bcj2_read(reader *r, uint8_t *out, size_t n) {
    bcj2_reader *j = (bcj2_reader *)r;
    if (!j->started) {
        j->started = 1;
        j->code = 0; j->range = 0xffffffffu;
        for (int i = 0; i < 5; i++) {
            uint8_t b;
            if (bcj2_rc_byte(j, &b) != 0) return -1;
            j->code = (j->code << 8) | b;
        }
    }
    size_t got = 0;
    while (got < n && j->done < j->size) {
        if (j->pend_at < j->pend) { out[got++] = j->pending[j->pend_at++]; j->done++; continue; }
        uint8_t b;
        int rc = next_byte(&j->in[0], &b);
        if (rc < 0) return -1;
        if (rc == 0) break;
        out[got++] = b; j->done++;
        int candidate = (b & 0xfe) == 0xe8 || (j->prev == 0x0f && (b & 0xf0) == 0x80);
        if (!candidate) { j->prev = b; continue; }
        if (j->done == j->size) break;
        uint16_t *prob = b == 0xe8 ? &j->probs[j->prev] : b == 0xe9 ? &j->probs[256] : &j->probs[257];
        uint32_t ttt = *prob, bound = (j->range >> 11) * ttt;
        int converted;
        if (j->code < bound) { j->range = bound; *prob = (uint16_t)(ttt + ((2048 - ttt) >> 5)); converted = 0; }
        else { j->range -= bound; j->code -= bound; *prob = (uint16_t)(ttt - (ttt >> 5)); converted = 1; }
        if (j->range < (1u << 24)) {
            uint8_t x;
            if (bcj2_rc_byte(j, &x) != 0) return -1;
            j->range <<= 8; j->code = (j->code << 8) | x;
        }
        if (!converted) { j->prev = b; continue; }
        byte_in *src = b == 0xe8 ? &j->in[1] : &j->in[2];
        uint32_t v = 0;
        for (int i = 0; i < 4; i++) {
            uint8_t x;
            int k = next_byte(src, &x);
            if (k < 0) return -1;
            if (k == 0) { fail(r->st, I7Z_DAMAGED, "bcj2"); return -1; }
            v = (v << 8) | x;
        }
        uint32_t dest = v - (uint32_t)(j->done + 4);
        for (int i = 0; i < 4; i++) j->pending[i] = (uint8_t)(dest >> (8 * i));
        j->pend = 4; j->pend_at = 0;
        j->prev = (uint8_t)(dest >> 24);
    }
    return (long)got;
}

static void bcj2_close(reader *r) {
    bcj2_reader *j = (bcj2_reader *)r;
    for (int i = 0; i < 4; i++) reader_close(j->in[i].up);
    free(j);
}

// ---- a folder's readers ----

typedef struct {
    int fd;
    const streams_t *s;
    const folder_t *f;
    status_t *st;
    int depth;
} plan_t;

static int id_is(const coder_t *c, const uint8_t *id, uint8_t size) {
    return c->id_size == size && memcmp(c->id, id, size) == 0;
}

static const uint8_t ID_COPY[] = {0x00};
static const uint8_t ID_DELTA[] = {0x03};
static const uint8_t ID_X86[] = {0x03, 0x03, 0x01, 0x03};
static const uint8_t ID_BCJ2[] = {0x03, 0x03, 0x01, 0x1b};
static const uint8_t ID_PPC[] = {0x03, 0x03, 0x02, 0x05};
static const uint8_t ID_IA64[] = {0x03, 0x03, 0x04, 0x01};
static const uint8_t ID_ARM[] = {0x03, 0x03, 0x05, 0x01};
static const uint8_t ID_ARMT[] = {0x03, 0x03, 0x07, 0x01};
static const uint8_t ID_SPARC[] = {0x03, 0x03, 0x08, 0x05};
static const uint8_t ID_ARM64[] = {0x0a};
static const uint8_t ID_LZMA[] = {0x03, 0x01, 0x01};
static const uint8_t ID_LZMA2[] = {0x21};
static const uint8_t ID_DEFLATE[] = {0x04, 0x01, 0x08};
static const uint8_t ID_BZIP2[] = {0x04, 0x02, 0x02};
static const uint8_t ID_PPMD[] = {0x03, 0x04, 0x01};
static const uint8_t ID_AES[] = {0x06, 0xf1, 0x07, 0x01};

#define IS(c, ID) id_is((c), (ID), (uint8_t)sizeof(ID))

/// The liblzma filter for a coder, or 0 when liblzma does not decode it.
static uint64_t lzma_filter_id(const coder_t *c) {
    if (IS(c, ID_LZMA)) return LZMA_FILTER_LZMA1_;
    if (IS(c, ID_LZMA2)) return LZMA_FILTER_LZMA2_;
    if (IS(c, ID_X86)) return 0x04;
    if (IS(c, ID_PPC)) return 0x05;
    if (IS(c, ID_IA64)) return 0x06;
    if (IS(c, ID_ARM)) return 0x07;
    if (IS(c, ID_ARMT)) return 0x08;
    if (IS(c, ID_SPARC)) return 0x09;
    if (IS(c, ID_ARM64)) return 0x0a;
    if (IS(c, ID_DELTA)) return 0x03;
    return 0;
}

static reader *out_reader(plan_t *p, uint32_t coder);

static reader *in_reader(plan_t *p, uint32_t in_index) {
    const folder_t *f = p->f;
    for (uint32_t k = 0; k < f->num_binds; k++)
        if (f->binds[k].in_index == in_index) return out_reader(p, f->binds[k].out_index);
    for (uint32_t k = 0; k < f->num_packed; k++) {
        if (f->packed[k] != in_index) continue;
        uint32_t index = f->first_pack + k;
        if (index >= p->s->num_pack) { fail(p->st, I7Z_DAMAGED, "pack-index"); return NULL; }
        pack_reader *r = calloc(1, sizeof(*r));
        if (!r) { fail(p->st, I7Z_MEMORY, "memory"); return NULL; }
        r->base.read = pack_read; r->base.close = pack_close; r->base.st = p->st;
        r->fd = p->fd; r->at = p->s->pack_offsets[index]; r->left = p->s->pack_sizes[index];
        return &r->base;
    }
    fail(p->st, I7Z_DAMAGED, "stream-unbound");
    return NULL;
}

static reader *out_reader(plan_t *p, uint32_t coder) {
    if (++p->depth > (int)MAX_CODERS) { fail(p->st, I7Z_DAMAGED, "coder-loop"); return NULL; }
    const folder_t *f = p->f;
    const coder_t *c = &f->coders[coder];
    if (IS(c, ID_COPY)) return in_reader(p, c->first_in);
    if (IS(c, ID_BCJ2)) {
        if (c->num_in != 4) { fail(p->st, I7Z_DAMAGED, "bcj2-streams"); return NULL; }
        bcj2_reader *j = calloc(1, sizeof(*j));
        if (!j) { fail(p->st, I7Z_MEMORY, "memory"); return NULL; }
        j->base.read = bcj2_read; j->base.close = bcj2_close; j->base.st = p->st;
        j->size = f->unpack[coder];
        for (int i = 0; i < 258; i++) j->probs[i] = 1024;
        for (int i = 0; i < 4; i++) {
            j->in[i].up = in_reader(p, c->first_in + (uint32_t)i);
            if (!j->in[i].up) { bcj2_close(&j->base); return NULL; }
        }
        return &j->base;
    }
    if (IS(c, ID_DEFLATE)) {
        inflate_reader *z = calloc(1, sizeof(*z));
        if (!z) { fail(p->st, I7Z_MEMORY, "memory"); return NULL; }
        if (inflateInit2(&z->strm, -15) != Z_OK) { free(z); fail(p->st, I7Z_MEMORY, "inflate-init"); return NULL; }
        z->base.read = inflate_read; z->base.close = inflate_close; z->base.st = p->st;
        z->left = f->unpack[coder];
        z->up = in_reader(p, c->first_in);
        if (!z->up) { inflate_close(&z->base); return NULL; }
        return &z->base;
    }
    if (lzma_filter_id(c) == 0) {
        if (IS(c, ID_AES)) fail(p->st, I7Z_UNSUPPORTED, "encrypted");
        else if (IS(c, ID_PPMD)) fail(p->st, I7Z_UNSUPPORTED, "ppmd");
        else if (IS(c, ID_BZIP2)) fail(p->st, I7Z_UNSUPPORTED, "bzip2");
        else {
            char reason[48] = "method-";
            for (uint8_t k = 0; k < c->id_size && k < 8; k++) snprintf(reason + strlen(reason), sizeof(reason) - strlen(reason), "%02x", c->id[k]);
            fail(p->st, I7Z_UNSUPPORTED, reason);
        }
        return NULL;
    }
    // A run of liblzma filters ending in LZMA or LZMA2 is one raw decoder, outermost first.
    // Copy coders in the run are skipped; a run that ends without LZMA2 gets LZMA2 framing.
    uint32_t chain[MAX_CHAIN];
    int length = 0, wrap = 0;
    uint32_t at = coder, input;
    for (;;) {
        const coder_t *cc = &f->coders[at];
        uint64_t id = lzma_filter_id(cc);
        if (cc->num_in != 1 || length == MAX_CHAIN) { fail(p->st, I7Z_UNSUPPORTED, "filter-chain"); return NULL; }
        input = cc->first_in;
        if (id != 0) {
            chain[length++] = at;
            if (id == LZMA_FILTER_LZMA1_ || id == LZMA_FILTER_LZMA2_) break;
        }
        int found = 0;
        for (uint32_t k = 0; k < f->num_binds; k++)
            if (f->binds[k].in_index == input) { at = f->binds[k].out_index; found = 1; break; }
        if (!found) { wrap = 1; break; }                      // packed bytes
        const coder_t *next = &f->coders[at];
        if (!IS(next, ID_COPY) && lzma_filter_id(next) == 0) { wrap = 1; break; } // BCJ2, Deflate, ...
        // LZMA (not LZMA2) has no end marker in 7z, so filters over it would never hear
        // that the data ended and keep their last bytes: it decodes on its own, framed.
        if (length > 0 && lzma_filter_id(next) == LZMA_FILTER_LZMA1_) { wrap = 1; break; }
        if (++p->depth > (int)MAX_CODERS) { fail(p->st, I7Z_DAMAGED, "coder-loop"); return NULL; }
    }
    if (wrap && length == MAX_CHAIN) { fail(p->st, I7Z_UNSUPPORTED, "filter-chain"); return NULL; }
    lzma_reader *z = calloc(1, sizeof(*z));
    if (!z) { fail(p->st, I7Z_MEMORY, "memory"); return NULL; }
    z->base.read = lzma_read; z->base.close = lzma_close; z->base.st = p->st;
    z->left = f->unpack[coder];
    i7z_lzma_filter filters[MAX_CHAIN + 2];
    memset(filters, 0, sizeof(filters));
    int ok = 1;
    for (int i = 0; i < length && ok; i++) {
        const coder_t *cc = &f->coders[chain[i]];
        filters[i].id = lzma_filter_id(cc);
        if (lzma_properties_decode(&filters[i], NULL, cc->props, cc->props_size) != LZMA_OK_) ok = 0;
    }
    int count = length;
    if (wrap && ok) {
        static const uint8_t small_dictionary = 0; // 4 KiB: uncompressed chunks use none
        filters[count].id = LZMA_FILTER_LZMA2_;
        if (lzma_properties_decode(&filters[count], NULL, &small_dictionary, 1) != LZMA_OK_) ok = 0;
        count++;
    }
    filters[count].id = LZMA_VLI_UNKNOWN_;
    int ret = ok ? lzma_raw_decoder(&z->strm, filters) : LZMA_OPTIONS_ERROR_;
    for (int i = 0; i < count; i++) free(filters[i].options);
    if (ret != LZMA_OK_) {
        fail(p->st, ret == LZMA_MEM_ERROR_ ? I7Z_MEMORY : I7Z_UNSUPPORTED, ret == LZMA_MEM_ERROR_ ? "lzma-memory" : "lzma-options");
        lzma_end(&z->strm);
        free(z);
        return NULL;
    }
    reader *up = in_reader(p, input);
    if (up && wrap) {
        wrap_reader *w = calloc(1, sizeof(*w));
        if (!w) { reader_close(up); up = NULL; fail(p->st, I7Z_MEMORY, "memory"); }
        else { w->base.read = wrap_read; w->base.close = wrap_close; w->base.st = p->st; w->up = up; w->first = 1; up = &w->base; }
    }
    z->up = up;
    if (!z->up) { lzma_close(&z->base); return NULL; }
    return &z->base;
}

static reader *folder_reader(int fd, const streams_t *s, uint32_t index, status_t *st) {
    plan_t p = { fd, s, &s->folders[index], st, 0 };
    return out_reader(&p, s->folders[index].main);
}

/// Reads exactly `n` bytes (fewer only when the folder ends early: damaged).
static int read_full(reader *r, uint8_t *out, size_t n) {
    size_t got = 0;
    while (got < n) {
        long k = r->read(r, out + got, n - got);
        if (k < 0) return -1;
        if (k == 0) return fail(r->st, I7Z_DAMAGED, "truncated");
        got += (size_t)k;
    }
    return 0;
}

// ---- opening ----

static int parse_files(buf_t *b, i7z *z) {
    uint64_t n = rd_number(b);
    if (bad(b)) return -1;
    if (n > MAX_ITEMS) return fail(b->st, I7Z_DAMAGED, "item-count");
    z->count = (uint32_t)n;
    z->items = calloc(n ? n : 1, sizeof(item_t));
    uint8_t *empty_stream = calloc(n ? n : 1, 1), *empty_file = NULL, *anti = NULL;
    uint32_t *attrs = calloc(n ? n : 1, 4);
    uint8_t *attr_defined = calloc(n ? n : 1, 1);
    uint32_t empties = 0;
    if (!z->items || !empty_stream || !attrs || !attr_defined) { fail(b->st, I7Z_MEMORY, "memory"); goto done; }
    for (;;) {
        uint64_t type = rd_number(b);
        if (bad(b) || type == kEnd) break;
        uint64_t size = rd_number(b);
        if (bad(b)) break;
        if (size > (uint64_t)(b->end - b->p)) { fail(b->st, I7Z_DAMAGED, "header-short"); break; }
        buf_t prop = { b->p, b->p + size, b->st };
        b->p += size;
        if (type == kEmptyStream) {
            free(empty_stream);
            empty_stream = rd_bits(&prop, z->count);
            if (!empty_stream) break;
            empties = 0;
            for (uint32_t i = 0; i < z->count; i++) empties += empty_stream[i];
        } else if (type == kEmptyFile) {
            free(empty_file);
            empty_file = rd_bits(&prop, empties);
        } else if (type == kAnti) {
            free(anti);
            anti = rd_bits(&prop, empties);
        } else if (type == kName) {
            if (rd_byte(&prop) != 0) { fail(b->st, I7Z_UNSUPPORTED, "external"); break; }
            for (uint32_t i = 0; i < z->count && !bad(b); i++) {
                const uint8_t *start = prop.p;
                size_t units = 0;
                while (prop.p + 1 < prop.end && (prop.p[0] | prop.p[1])) { prop.p += 2; units++; }
                if (prop.p + 1 >= prop.end) { fail(b->st, I7Z_DAMAGED, "names"); break; }
                prop.p += 2;
                char *name = malloc(units * 3 + 1), *o = name;
                if (!name) { fail(b->st, I7Z_MEMORY, "memory"); break; }
                for (size_t k = 0; k < units; k++) {
                    uint32_t u = (uint32_t)start[2 * k] | (uint32_t)start[2 * k + 1] << 8;
                    if (u >= 0xd800 && u < 0xdc00 && k + 1 < units) {
                        uint32_t lo = (uint32_t)start[2 * k + 2] | (uint32_t)start[2 * k + 3] << 8;
                        if (lo >= 0xdc00 && lo < 0xe000) { u = 0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00); k++; }
                    }
                    if (u >= 0xd800 && u < 0xe000) u = 0xfffd;
                    if (u < 0x80) *o++ = (char)u;
                    else if (u < 0x800) { *o++ = (char)(0xc0 | (u >> 6)); *o++ = (char)(0x80 | (u & 0x3f)); }
                    else if (u < 0x10000) { *o++ = (char)(0xe0 | (u >> 12)); *o++ = (char)(0x80 | ((u >> 6) & 0x3f)); *o++ = (char)(0x80 | (u & 0x3f)); }
                    else { *o++ = (char)(0xf0 | (u >> 18)); *o++ = (char)(0x80 | ((u >> 12) & 0x3f)); *o++ = (char)(0x80 | ((u >> 6) & 0x3f)); *o++ = (char)(0x80 | (u & 0x3f)); }
                }
                *o = 0;
                // 4 UTF-8 bytes stand for 2 UTF-16 units, so units * 3 + 1 always fits.
                z->items[i].name = name;
            }
        } else if (type == kWinAttributes) {
            uint8_t all = rd_byte(&prop);
            uint8_t *set = all ? NULL : rd_bits(&prop, z->count);
            if (!all && !set) break;
            if (rd_byte(&prop) != 0) { free(set); fail(b->st, I7Z_UNSUPPORTED, "external"); break; }
            for (uint32_t i = 0; i < z->count; i++) {
                attr_defined[i] = all ? 1 : set[i];
                if (attr_defined[i]) attrs[i] = rd_u32(&prop);
            }
            free(set);
        }
        // Times, kDummy and the rest: skipped.
    }
    if (bad(b)) goto done;
    uint32_t e = 0, sub = 0;
    for (uint32_t i = 0; i < z->count; i++) {
        item_t *it = &z->items[i];
        if (!it->name) { it->name = strdup(""); if (!it->name) { fail(b->st, I7Z_MEMORY, "memory"); goto done; } }
        int flags = 0;
        if (empty_stream[i]) {
            int is_file = empty_file && empty_file[e];
            if (anti && anti[e]) flags |= I7Z_ITEM_ANTI;
            if (!is_file) flags |= I7Z_ITEM_DIR;
            e++;
        } else {
            flags |= I7Z_ITEM_STREAM;
            if (sub >= z->streams.num_sub_total) { fail(b->st, I7Z_DAMAGED, "stream-count"); goto done; }
            it->size = z->streams.sub_sizes[sub++];
            z->total += it->size;
        }
        if (attr_defined[i]) {
            if (attrs[i] & 0x10) flags |= I7Z_ITEM_DIR;
            if ((attrs[i] & 0x8000) && ((attrs[i] >> 16) & 0170000) == 0120000) flags |= I7Z_ITEM_LINK;
        }
        if ((flags & I7Z_ITEM_DIR) && (flags & I7Z_ITEM_STREAM)) flags &= ~I7Z_ITEM_DIR;
        it->flags = flags;
    }
    if (sub != z->streams.num_sub_total) fail(b->st, I7Z_DAMAGED, "stream-count");
done:
    free(empty_stream); free(empty_file); free(anti); free(attrs); free(attr_defined);
    return bad(b) ? -1 : 0;
}

static int parse_header(buf_t *b, i7z *z) {
    uint64_t type = rd_number(b);
    if (type == kArchiveProperties) {
        for (;;) {
            uint64_t t = rd_number(b);
            if (bad(b) || t == kEnd) break;
            if (skip_property(b) != 0) return -1;
        }
        type = rd_number(b);
    }
    if (type == kAdditionalStreamsInfo) {
        streams_t extra;
        int r = parse_streams(b, &extra, z->length);
        streams_free(&extra);
        if (r != 0) return -1;
        type = rd_number(b);
    }
    if (type == kMainStreamsInfo) {
        if (parse_streams(b, &z->streams, z->length) != 0) return -1;
        type = rd_number(b);
    }
    if (type == kFilesInfo) {
        if (parse_files(b, z) != 0) return -1;
        type = rd_number(b);
    } else if (z->streams.num_sub_total) {
        return fail(b->st, I7Z_DAMAGED, "no-files");
    }
    if (bad(b)) return -1;
    if (type != kEnd) return fail(b->st, I7Z_DAMAGED, "header-end");
    return 0;
}

static int read_at(int fd, uint8_t *out, size_t n, uint64_t at, status_t *st) {
    size_t got = 0;
    while (got < n) {
        ssize_t k = pread(fd, out + got, n - got, (off_t)(at + got));
        if (k < 0 && errno == EINTR) continue;
        if (k < 0) return fail(st, I7Z_IO, "read");
        if (k == 0) return fail(st, I7Z_DAMAGED, "short-read");
        got += (size_t)k;
    }
    return 0;
}

static const uint8_t SIGNATURE[6] = {'7', 'z', 0xbc, 0xaf, 0x27, 0x1c};

int i7z_is_7z(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    uint8_t head[6];
    ssize_t k = pread(fd, head, 6, 0);
    close(fd);
    return k == 6 && memcmp(head, SIGNATURE, 6) == 0;
}

static uint32_t crc_of(const uint8_t *p, size_t n) {
    uLong crc = crc32(0, Z_NULL, 0);
    while (n > 0) {
        uInt piece = n > (1u << 30) ? (1u << 30) : (uInt)n;
        crc = crc32(crc, p, piece);
        p += piece; n -= piece;
    }
    return (uint32_t)crc;
}

static uint64_t le64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | p[i]; return v; }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

int i7z_open(const char *path, i7z **out, char *reason, size_t reason_size) {
    status_t st = { I7Z_OK, "" };
    *out = NULL;
    i7z *z = calloc(1, sizeof(*z));
    if (!z) { fail(&st, I7Z_MEMORY, "memory"); goto failed; }
    z->fd = -1;
    z->fd = open(path, O_RDONLY);
    if (z->fd < 0) { fail(&st, I7Z_IO, "open"); goto failed; }
    off_t end = lseek(z->fd, 0, SEEK_END);
    if (end < 32) { fail(&st, I7Z_NOT_7Z, "not-7z"); goto failed; }
    z->length = (uint64_t)end;
    uint8_t start[32];
    if (read_at(z->fd, start, 32, 0, &st) != 0) goto failed;
    if (memcmp(start, SIGNATURE, 6) != 0) { fail(&st, I7Z_NOT_7Z, "not-7z"); goto failed; }
    if (start[6] != 0) { fail(&st, I7Z_UNSUPPORTED, "version"); goto failed; }
    if (crc_of(start + 12, 20) != le32(start + 8)) { fail(&st, I7Z_DAMAGED, "start-crc"); goto failed; }
    uint64_t next_offset = le64(start + 12), next_size = le64(start + 20);
    uint32_t next_crc = le32(start + 28);
    if (next_size == 0) { *out = z; return I7Z_OK; } // an empty archive
    if (next_size > MAX_HEADER || next_offset > z->length - 32 || next_size > z->length - 32 - next_offset) {
        // A download cut short ends before its header.
        fail(&st, I7Z_DAMAGED, "header-range"); goto failed;
    }
    z->raw_header = malloc((size_t)next_size);
    if (!z->raw_header) { fail(&st, I7Z_MEMORY, "memory"); goto failed; }
    if (read_at(z->fd, z->raw_header, (size_t)next_size, 32 + next_offset, &st) != 0) goto failed;
    if (crc_of(z->raw_header, (size_t)next_size) != next_crc) { fail(&st, I7Z_DAMAGED, "header-crc"); goto failed; }
    uint8_t *header = z->raw_header;
    size_t header_size = (size_t)next_size;
    // A packed header (7-Zip's default): decode it, maybe more than once.
    for (int round = 0; round < 4 && header_size > 0 && header[0] == kEncodedHeader; round++) {
        buf_t b = { header + 1, header + header_size, &st };
        streams_t s;
        if (parse_streams(&b, &s, z->length) != 0) { streams_free(&s); goto failed; }
        if (s.num_folders == 0) { streams_free(&s); fail(&st, I7Z_DAMAGED, "header-folder"); goto failed; }
        const folder_t *f = &s.folders[0];
        uint64_t size = f->unpack[f->main];
        if (size == 0 || size > MAX_HEADER) { streams_free(&s); fail(&st, I7Z_DAMAGED, "header-size"); goto failed; }
        uint8_t *decoded = malloc((size_t)size);
        if (!decoded) { streams_free(&s); fail(&st, I7Z_MEMORY, "memory"); goto failed; }
        reader *r = folder_reader(z->fd, &s, 0, &st);
        int ok = r && read_full(r, decoded, (size_t)size) == 0;
        reader_close(r);
        if (ok && f->crc_defined && crc_of(decoded, (size_t)size) != f->crc) { fail(&st, I7Z_DAMAGED, "header-crc"); ok = 0; }
        streams_free(&s);
        if (!ok) { free(decoded); goto failed; }
        if (header != z->raw_header) free(header);
        header = decoded;
        header_size = (size_t)size;
    }
    if (header != z->raw_header) { free(z->raw_header); z->raw_header = NULL; }
    z->header = header;
    if (header_size == 0 || header[0] != kHeader) { fail(&st, I7Z_DAMAGED, "header"); goto failed; }
    buf_t b = { header + 1, header + header_size, &st };
    if (parse_header(&b, z) != 0) goto failed;
    *out = z;
    return I7Z_OK;
failed:
    if (reason && reason_size) snprintf(reason, reason_size, "%s", st.reason);
    i7z_close(z);
    return st.code;
}

uint32_t i7z_count(const i7z *z) { return z->count; }
const char *i7z_name(const i7z *z, uint32_t item) { return item < z->count ? z->items[item].name : ""; }
int i7z_flags(const i7z *z, uint32_t item) { return item < z->count ? z->items[item].flags : 0; }
uint64_t i7z_size(const i7z *z, uint32_t item) { return item < z->count ? z->items[item].size : 0; }
uint64_t i7z_total(const i7z *z) { return z->total; }

int i7z_extract(i7z *z, i7z_sink sink, void *context, char *reason, size_t reason_size) {
    status_t st = { I7Z_OK, "" };
    const streams_t *s = &z->streams;
    uint8_t *chunk = malloc(1u << 20);
    if (!chunk) { fail(&st, I7Z_MEMORY, "memory"); goto finish; }
    uint32_t item = 0, sub = 0;
    for (uint32_t fi = 0; fi < s->num_folders && st.code == I7Z_OK; fi++) {
        const folder_t *f = &s->folders[fi];
        if (f->num_sub == 0) continue;
        reader *r = folder_reader(z->fd, s, fi, &st);
        if (!r) break;
        for (uint32_t k = 0; k < f->num_sub && st.code == I7Z_OK; k++, sub++) {
            while (item < z->count && !(z->items[item].flags & I7Z_ITEM_STREAM)) item++;
            if (item == z->count) { fail(&st, I7Z_DAMAGED, "stream-count"); break; }
            if (sink(context, I7Z_BEGIN, item, NULL, 0) != 0) { fail(&st, I7Z_ABORTED, "stopped"); break; }
            uint64_t left = s->sub_sizes[sub];
            uLong crc = crc32(0, Z_NULL, 0);
            while (left > 0) {
                size_t want = left > (1u << 20) ? (1u << 20) : (size_t)left;
                if (read_full(r, chunk, want) != 0) break;
                crc = crc32(crc, chunk, (uInt)want);
                if (sink(context, I7Z_DATA, item, chunk, want) != 0) { fail(&st, I7Z_ABORTED, "stopped"); break; }
                left -= want;
            }
            if (st.code != I7Z_OK) break;
            if (s->sub_crc_defined[sub] && (uint32_t)crc != s->sub_crcs[sub]) { fail(&st, I7Z_DAMAGED, "crc"); break; }
            if (sink(context, I7Z_END, item, NULL, 0) != 0) { fail(&st, I7Z_ABORTED, "stopped"); break; }
            item++;
        }
        reader_close(r);
    }
finish:
    free(chunk);
    if (st.code != I7Z_OK && reason && reason_size) snprintf(reason, reason_size, "%s", st.reason);
    return st.code;
}

void i7z_close(i7z *z) {
    if (!z) return;
    if (z->fd >= 0) close(z->fd);
    for (uint32_t i = 0; i < z->count; i++) free(z->items[i].name);
    free(z->items);
    streams_free(&z->streams);
    if (z->header != z->raw_header) free(z->header);
    free(z->raw_header);
    free(z);
}
