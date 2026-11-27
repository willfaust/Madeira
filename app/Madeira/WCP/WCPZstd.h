/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * WCPZstd: streaming Zstandard decompression for .wcp component packages.
 *
 * GNU tar's --zstd output (and DroidDeck's packages) usually has no content
 * size in the frame header, so the size-in-advance decoder in SwiftSteam
 * cannot read it. This shim streams frames through zstd's ZSTD_decompressStream
 * and writes the result to a file, with a hard output cap.
 */
#ifndef WCP_ZSTD_H
#define WCP_ZSTD_H

#include <stddef.h>
#include <stdint.h>

/* Decompress `source` (zstd, one or more concatenated frames) into a new file
 * at `destination`. Returns 0 on success and stores the byte count in
 * *out_size; returns -1 and fills err (when err_len > 0) on failure. Stops
 * with an error rather than writing more than max_output bytes. */
int wcp_zstd_decompress_path(const char *source, const char *destination,
                             uint64_t max_output, uint64_t *out_size,
                             char *err, size_t err_len);

#endif /* WCP_ZSTD_H */
