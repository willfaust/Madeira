/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * WCPZstd.c — streaming Zstandard decompression for .wcp component packages.
 * The decoder itself is WCP/zstddeclib.c (facebook/zstd, BSD).
 */

#include "WCPZstd.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The subset of zstd.h the decoder exports. ZSTD_inBuffer and ZSTD_outBuffer
 * are part of the stable public ABI; keep these layouts in step with zstd.h. */
typedef struct {
    const void *src;
    size_t size;
    size_t pos;
} ZSTD_inBuffer;

typedef struct {
    void *dst;
    size_t size;
    size_t pos;
} ZSTD_outBuffer;

typedef struct ZSTD_DCtx_s ZSTD_DStream;

extern ZSTD_DStream *WCP_ZSTD_createDStream(void);
extern size_t WCP_ZSTD_freeDStream(ZSTD_DStream *zds);
extern size_t WCP_ZSTD_initDStream(ZSTD_DStream *zds);
extern size_t WCP_ZSTD_decompressStream(ZSTD_DStream *zds, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
extern unsigned ZSTD_isError(size_t code);
extern const char *WCP_ZSTD_getErrorName(size_t code);

#define WCP_IO_SIZE (1024u * 1024u)

static void wcp_set_error(char *err, size_t err_len, const char *text)
{
    if (err && err_len) {
        snprintf(err, err_len, "%s", text);
        err[err_len - 1] = 0;
    }
}

static int wcp_write_all(FILE *out, const void *bytes, size_t count)
{
    const unsigned char *p = (const unsigned char *)bytes;
    while (count) {
        size_t written = fwrite(p, 1, count, out);
        if (!written) return -1;
        p += written;
        count -= written;
    }
    return 0;
}

int wcp_zstd_decompress_path(const char *source, const char *destination,
                             uint64_t max_output, uint64_t *out_size,
                             char *err, size_t err_len)
{
    FILE *in = NULL, *out = NULL;
    ZSTD_DStream *stream = NULL;
    unsigned char *in_buffer = NULL, *out_buffer = NULL;
    uint64_t total = 0;
    int saw_frame_end = 0;
    int result = -1;

    if (out_size) *out_size = 0;
    if (!source || !destination) {
        wcp_set_error(err, err_len, "missing source or destination");
        return -1;
    }

    in = fopen(source, "rb");
    if (!in) {
        wcp_set_error(err, err_len, "cannot open the .wcp file");
        goto done;
    }
    out = fopen(destination, "wb");
    if (!out) {
        wcp_set_error(err, err_len, "cannot create the decompressed file");
        goto done;
    }
    stream = WCP_ZSTD_createDStream();
    if (!stream) {
        wcp_set_error(err, err_len, "cannot create a zstd stream");
        goto done;
    }
    if (ZSTD_isError(WCP_ZSTD_initDStream(stream))) {
        wcp_set_error(err, err_len, "cannot initialise the zstd stream");
        goto done;
    }
    in_buffer = (unsigned char *)malloc(WCP_IO_SIZE);
    out_buffer = (unsigned char *)malloc(WCP_IO_SIZE);
    if (!in_buffer || !out_buffer) {
        wcp_set_error(err, err_len, "out of memory");
        goto done;
    }

    for (;;) {
        size_t got = fread(in_buffer, 1, WCP_IO_SIZE, in);
        if (!got) break;
        ZSTD_inBuffer input = { in_buffer, got, 0 };
        while (input.pos < input.size) {
            ZSTD_outBuffer output = { out_buffer, WCP_IO_SIZE, 0 };
            size_t status = WCP_ZSTD_decompressStream(stream, &output, &input);
            if (ZSTD_isError(status)) {
                wcp_set_error(err, err_len, WCP_ZSTD_getErrorName(status));
                goto done;
            }
            if (status == 0) saw_frame_end = 1;
            if (output.pos) {
                if (max_output && total + output.pos > max_output) {
                    wcp_set_error(err, err_len, "the package expands past the size limit");
                    goto done;
                }
                if (wcp_write_all(out, out_buffer, output.pos) != 0) {
                    wcp_set_error(err, err_len, "cannot write the decompressed package");
                    goto done;
                }
                total += output.pos;
            }
        }
    }
    if (ferror(in)) {
        wcp_set_error(err, err_len, "cannot read the .wcp file");
        goto done;
    }

    /* A frame ends with status 0. If the final output filled the buffer, the
     * stream can still hold bytes: drain with empty input until it produces
     * nothing. A stream that never reached a frame end is truncated. */
    {
        int guard = 64;
        for (;;) {
            ZSTD_inBuffer input = { NULL, 0, 0 };
            ZSTD_outBuffer output = { out_buffer, WCP_IO_SIZE, 0 };
            size_t status = WCP_ZSTD_decompressStream(stream, &output, &input);
            if (ZSTD_isError(status)) {
                wcp_set_error(err, err_len, WCP_ZSTD_getErrorName(status));
                goto done;
            }
            if (status == 0) saw_frame_end = 1;
            if (output.pos) {
                if (max_output && total + output.pos > max_output) {
                    wcp_set_error(err, err_len, "the package expands past the size limit");
                    goto done;
                }
                if (wcp_write_all(out, out_buffer, output.pos) != 0) {
                    wcp_set_error(err, err_len, "cannot write the decompressed package");
                    goto done;
                }
                total += output.pos;
            }
            if (output.pos == 0 || --guard <= 0) break;
        }
    }
    if (!saw_frame_end) {
        wcp_set_error(err, err_len, "the .wcp file is truncated");
        goto done;
    }

    if (fflush(out) != 0) {
        wcp_set_error(err, err_len, "cannot flush the decompressed package");
        goto done;
    }
    if (out_size) *out_size = total;
    result = 0;

done:
    if (in) fclose(in);
    if (out) fclose(out);
    if (stream) WCP_ZSTD_freeDStream(stream);
    free(in_buffer);
    free(out_buffer);
    if (result != 0 && destination) remove(destination);
    return result;
}
