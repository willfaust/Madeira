// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation
import CommonCrypto
import Compression
import zlib

/// Decrypts, decompresses and checks the chunks and manifest strings that
/// Steam's content servers deliver.
///
/// Chunk pipeline, as the content servers define it: AES-256 with the depot's
/// key, then one of Steam's compression containers, then Steam's Adler-32.
/// Decompression uses liblzma, a zstd decoder and zlib; nothing here writes
/// files.
struct ContentDecryptor {

    // MARK: - AES

    /// Decrypts a depot chunk or an encrypted manifest string.
    ///
    /// The first 16 bytes are the IV, itself encrypted with the depot key in
    /// ECB mode (no padding). The rest is AES-256-CBC with PKCS7 padding under
    /// that IV.
    static func decryptChunk(encryptedData: Data, depotKey: Data) throws -> Data {
        guard depotKey.count == 32 else {
            throw SteamError.decryptionFailed("Invalid depot key size: \(depotKey.count), expected 32")
        }
        // CBC ciphertext must contain complete AES blocks. CommonCrypto can
        // return decoded prefix bytes for some truncated inputs; reject them
        // before asking the platform crypto implementation to decrypt.
        guard encryptedData.count >= 32, (encryptedData.count - 16) % kCCBlockSizeAES128 == 0 else {
            throw SteamError.decryptionFailed("Encrypted data is not a complete AES payload")
        }

        let ivCipher = encryptedData.prefix(16)
        let ciphertext = encryptedData.dropFirst(16)

        var derivedIV = Data(count: 16)
        var ivLen = 0
        let ivStatus = depotKey.withUnsafeBytes { keyPtr in
            ivCipher.withUnsafeBytes { inPtr in
                derivedIV.withUnsafeMutableBytes { outPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress!, depotKey.count, nil,
                            inPtr.baseAddress!, 16, outPtr.baseAddress!, 16, &ivLen)
                }
            }
        }
        guard ivStatus == kCCSuccess, ivLen == 16 else {
            throw SteamError.decryptionFailed("IV derivation failed: \(ivStatus)")
        }

        let outputBufferSize = ciphertext.count + kCCBlockSizeAES128
        var decryptedData = Data(count: outputBufferSize)
        var decryptedLength = 0

        let status = depotKey.withUnsafeBytes { keyPtr in
            derivedIV.withUnsafeBytes { ivPtr in
                ciphertext.withUnsafeBytes { dataPtr in
                    decryptedData.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress!, depotKey.count,
                            ivPtr.baseAddress!,
                            dataPtr.baseAddress!, ciphertext.count,
                            outPtr.baseAddress!, outputBufferSize,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw SteamError.decryptionFailed("AES decryption failed with status: \(status)")
        }

        decryptedData.count = decryptedLength
        return decryptedData
    }

    // MARK: - Decompression

    /// Upper bound for one decoded chunk or manifest payload. Steam chunks are
    /// at most 1 MiB; the bound only rejects hostile size fields.
    static let maximumChunkBytes = 64 * 1024 * 1024

    /// Undoes the compression container of a decrypted chunk. Steam serves
    /// three, told apart by their first bytes: "VSZa" (zstd), "VZ" (LZMA) and,
    /// for older content, a single-entry PKZip archive. Anything else is tried
    /// as a bare LZMA stream, then accepted as-is if it already has the
    /// expected size.
    static func decompressChunk(compressedData: Data, expectedSize: Int) throws -> Data {
        // "VSZa": zstd frame between an 8-byte header and a 15-byte footer.
        if compressedData.count > 23, compressedData.prefix(4).elementsEqual([0x56, 0x53, 0x5A, 0x61]) {
            do { return try decompressVZstd(compressedData, expectedSize: expectedSize) }
            catch { throw SteamError.chunkDecodeFailed("vzstd") }
        }

        // "VZ": LZMA stream with Steam's header and footer.
        if compressedData.count >= 2 {
            let header = compressedData.prefix(2)
            if header[0] == 0x56 && header[1] == 0x5A {
                do { return try decompressVZip(compressedData, expectedSize: expectedSize) }
                catch { throw SteamError.chunkDecodeFailed("vzip") }
            }
        }

        // Older content: a single-entry PKZip archive.
        if compressedData.count >= 30, compressedData.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) {
            guard expectedSize > 0, expectedSize <= maximumChunkBytes else { throw SteamError.chunkDecodeFailed("zip-size") }
            var output = Data(count: expectedSize)
            var produced = 0
            let rc = compressedData.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    chunk_zip_decode(inPtr.bindMemory(to: UInt8.self).baseAddress, compressedData.count,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, expectedSize, &produced)
                }
            }
            guard rc == 0 else { throw SteamError.chunkDecodeFailed("zip\(rc)") }
            output.count = produced
            return output
        }

        if compressedData.count > 5, let decompressed = decompressLZMA(compressedData, expectedSize: expectedSize) {
            return decompressed
        }

        // Not compressed.
        if compressedData.count == expectedSize {
            return compressedData
        }

        throw SteamError.chunkDecodeFailed(formatTag(compressedData))
    }

    /// Printable form of a chunk's first four bytes, for diagnostics (they are
    /// a format tag, not content).
    static func formatTag(_ data: Data) -> String {
        data.prefix(4).map { $0 >= 0x30 && $0 <= 0x7A ? String(UnicodeScalar($0)) : String(format: "%02x", $0) }.joined()
    }

    /// "VZa" container: 'VZ' 'a' + crc32(4) | LZMA properties(5) | raw LZMA1 |
    /// crc32(4) + uncompressed size(4) + 'zv'.
    private static func decompressVZip(_ data: Data, expectedSize: Int) throws -> Data {
        guard data.count > 22 else {
            throw SteamError.decompressionFailed
        }

        let props = data[7..<12]
        let compressed = data[12..<(data.count - 10)]
        let size = Int(data[(data.count - 6)..<(data.count - 2)]
            .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        // The footer's size is untrusted: it must agree with the manifest when
        // the manifest supplies one, and it may never request an unbounded buffer.
        guard size > 0, size <= maximumChunkBytes, expectedSize <= 0 || size == expectedSize else {
            throw SteamError.decompressionFailed
        }

        var output = Data(count: size)
        var produced = 0
        let ret = props.withUnsafeBytes { propsPtr in
            compressed.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    lzma_shim_decode(propsPtr.baseAddress!, props.count,
                                     inPtr.baseAddress!, compressed.count,
                                     outPtr.baseAddress!, size, &produced)
                }
            }
        }
        guard ret == 0 else {
            throw SteamError.decompressionFailed
        }
        output.count = produced
        return output
    }

    /// "VSZa" container: 'VSZa' + crc32(4) | zstd frame | crc32(4) + size(4) +
    /// 'zsv' footer (15 bytes).
    private static func decompressVZstd(_ data: Data, expectedSize: Int) throws -> Data {
        let zstdData = data[8..<(data.count - 15)]
        // The capacity comes from the manifest's cb_original. The decoder's own
        // frame-size query runs outside its error-safe wrapper and exits the
        // process on a malformed header, so it is not used; an undersized buffer
        // is reported as an error by the wrapper.
        guard expectedSize > 0, expectedSize <= maximumChunkBytes else {
            throw SteamError.decompressionFailed
        }
        let capacity = expectedSize
        var output = Data(count: capacity)
        let produced = zstdData.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                zstd_safe_decompress(outPtr.baseAddress!, capacity,
                                     inPtr.baseAddress!, zstdData.count)
            }
        }
        // The wrapper returns (size_t)-1 on error, which Swift imports as -1.
        guard produced >= 0, produced <= capacity else {
            throw SteamError.decompressionFailed
        }
        output.count = produced
        return output
    }

    /// A bare LZMA stream, through the Compression framework.
    private static func decompressLZMA(_ data: Data, expectedSize: Int) -> Data? {
        let outputSize = expectedSize > 0 ? expectedSize : data.count * 10
        var outputBuffer = Data(count: outputSize)

        let decompressedSize = data.withUnsafeBytes { srcPtr -> Int in
            outputBuffer.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress,
                      let dst = dstPtr.baseAddress else { return 0 }

                let result = compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), outputSize,
                    src.assumingMemoryBound(to: UInt8.self), data.count,
                    nil,
                    COMPRESSION_LZMA
                )

                return result > 0 ? result : 0
            }
        }

        guard decompressedSize > 0 else { return nil }
        outputBuffer.count = decompressedSize
        return outputBuffer
    }

    // MARK: - Checksum

    /// Steam's chunk checksum: Adler-32 seeded with 0 instead of the usual 1.
    /// zlib's `adler32(0, ...)` starts from exactly that state.
    static func adler32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else { return 0 }
            return UInt32(truncatingIfNeeded: zlib.adler32(0, base, uInt(raw.count)))
        }
    }

    // MARK: - Full pipeline

    /// Decrypts, decompresses and checks a chunk (the checksum is skipped
    /// when the manifest gives none).
    static func processChunk(
        encryptedData: Data,
        depotKey: Data,
        expectedCRC: UInt32,
        expectedSize: Int
    ) throws -> Data {
        let decrypted = try decryptChunk(encryptedData: encryptedData, depotKey: depotKey)
        let decompressed = try decompressChunk(compressedData: decrypted, expectedSize: expectedSize)

        if expectedCRC != 0, adler32(decompressed) != expectedCRC {
            throw SteamError.checksumMismatch
        }

        return decompressed
    }
}
