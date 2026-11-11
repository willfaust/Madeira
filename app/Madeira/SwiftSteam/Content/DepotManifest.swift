// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// A parsed Steam depot manifest: the files of one depot and their chunks.
struct DepotManifest {
    /// EDepotFileFlag.CustomExecutable: a file Valve's client customizes per user before it runs.
    static let customExecutableFlag: UInt32 = 0x80
    let depotID: UInt32
    let manifestGID: UInt64
    let creationTime: UInt32
    var totalUncompressedSize: UInt64
    var totalCompressedSize: UInt64
    var files: [FileEntry] = []

    struct FileEntry {
        let filename: String
        let size: UInt64
        let flags: UInt32
        var chunks: [ChunkEntry]

        var isDirectory: Bool { flags & 0x40 != 0 }
    }

    struct ChunkEntry {
        let sha: Data           // 20-byte SHA-1 hash (used as chunk ID)
        let crc: UInt32         // Adler-32 checksum of uncompressed data
        let offset: UInt64      // Offset within the file
        let compressedSize: UInt32
        let uncompressedSize: UInt32

        /// Hex string of SHA hash (used in CDN URLs)
        var shaHex: String {
            sha.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Parsing

    /// Parse a depot manifest from binary data. Modern CDN payloads have an
    /// 8-byte binary header before the ContentManifestPayload protobuf, and
    /// filenames may be base64(AES-CBC depot-key) — pass depotKey to decode them.
    static func parse(depotID: UInt32, manifestGID: UInt64, data: Data, depotKey: Data? = nil) throws -> DepotManifest {
        guard data.count >= 4 else {
            throw SteamError.manifestFetchFailed("Manifest data too small")
        }

        // ContentManifestPayload starts with tag 0x0a (field 1, length-delimited).
        // Otherwise the blob is: 8B header (4B magic + 4B payloadLen) + protobuf
        // + a signature trailer — bound the payload by the header's length.
        let payload: Data
        if data.first == 0x0A {
            payload = data
        } else {
            let len = data.count >= 8
                ? Int(data[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
                : 0
            let end = (len > 0 && 8 + len <= data.count) ? 8 + len : data.count
            guard end >= 8 else { throw SteamError.manifestFetchFailed("Manifest data too small") }
            payload = Data(data[8..<end])
        }

        var manifest = DepotManifest(
            depotID: depotID,
            manifestGID: manifestGID,
            creationTime: 0,
            totalUncompressedSize: 0,
            totalCompressedSize: 0
        )

        try parseManifestPayload(data: Data(payload), manifest: &manifest, depotKey: depotKey)

        return manifest
    }

    /// Parse the manifest's serialized file list
    private static func parseManifestPayload(data: Data, manifest: inout DepotManifest, depotKey: Data?) throws {
        // The manifest is a protobuf message: ContentManifestPayload
        // Field 1 (repeated): ContentManifestPayload.FileMapping
        //   Field 1: filename (string)
        //   Field 2: size (uint64)
        //   Field 3: flags (uint32)
        //   Field 6 (repeated): ContentManifestPayload.FileMapping.ChunkData
        //     Field 1: sha (bytes, 20)
        //     Field 2: crc (fixed32)
        //     Field 3: offset (uint64)
        //     Field 4: cb_compressed (uint32)
        //     Field 5: cb_original (uint32)

        var decoder = ProtobufDecoder(data)
        var totalUncompressed: UInt64 = 0
        var totalCompressed: UInt64 = 0

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: // FileMapping
                let fileData = try decoder.readBytes()
                if let entry = try parseFileEntry(from: fileData, depotKey: depotKey) {
                    guard entry.size <= UInt64(Int64.max) - totalUncompressed else {
                        throw SteamError.manifestFetchFailed("Manifest size is too large")
                    }
                    totalUncompressed += entry.size
                    for chunk in entry.chunks {
                        totalCompressed += UInt64(chunk.compressedSize)
                    }
                    manifest.files.append(entry)
                }
            default:
                try decoder.skip(wireType: tag.wireType)
            }
        }

        manifest.totalUncompressedSize = totalUncompressed
        manifest.totalCompressedSize = totalCompressed
    }

    /// Encrypted filenames are base64'd AES-256-CBC ciphertext (depot key,
    /// embedded IV). Base64 can legitimately contain '/', so don't guard on
    /// separators — attempt the decode and keep it only if the result is sane.
    private static func decryptFilename(_ name: String, depotKey: Data?) -> String {
        let stripped = name.filter { !$0.isWhitespace }
        func fail(_ why: String) -> String {
            SteamLog.trace("filename decrypt failed (\(why))")
            return name
        }
        guard let depotKey else { return fail("no key") }
        guard let cipher = Data(base64Encoded: stripped, options: .ignoreUnknownCharacters),
              cipher.count > 16 else { return fail("b64") }
        guard let plain = try? ContentDecryptor.decryptChunk(encryptedData: cipher, depotKey: depotKey) else { return fail("aes") }
        // Plaintext is NUL-padded after PKCS7 unpadding — strip trailing nulls
        var bytes = plain
        while bytes.last == 0 { bytes.removeLast() }
        guard let decoded = String(data: bytes, encoding: .utf8), !decoded.isEmpty else {
            return fail("utf8")
        }
        guard !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return fail("ctrl") }
        return decoded
    }

    private static func parseFileEntry(from data: Data, depotKey: Data?) throws -> FileEntry? {
        var decoder = ProtobufDecoder(data)
        var filename = ""
        var size: UInt64 = 0
        var flags: UInt32 = 0
        var chunks: [ChunkEntry] = []

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: filename = try decoder.readString()
            case 2: size = try decoder.readVarint()
            case 3: flags = UInt32(truncatingIfNeeded: try decoder.readVarint())
            case 6: // ChunkData
                let chunkData = try decoder.readBytes()
                if let chunk = try parseChunkEntry(from: chunkData) {
                    chunks.append(chunk)
                }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        guard !filename.isEmpty else { return nil }

        let decoded = decryptFilename(filename, depotKey: depotKey)
        // Normalize path separators (Steam uses backslashes)
        let normalizedFilename = decoded.replacingOccurrences(of: "\\", with: "/")

        return FileEntry(filename: normalizedFilename, size: size, flags: flags, chunks: chunks)
    }

    private static func parseChunkEntry(from data: Data) throws -> ChunkEntry? {
        var decoder = ProtobufDecoder(data)
        var sha = Data()
        var crc: UInt32 = 0
        var offset: UInt64 = 0
        var compressedSize: UInt32 = 0
        var uncompressedSize: UInt32 = 0

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: sha = try decoder.readBytes()
            case 2: crc = try decoder.readFixed32()
            case 3: offset = try decoder.readVarint()
            case 4: uncompressedSize = UInt32(truncatingIfNeeded: try decoder.readVarint()) // cb_original
            case 5: compressedSize = UInt32(truncatingIfNeeded: try decoder.readVarint())   // cb_compressed
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        guard !sha.isEmpty else { return nil }

        return ChunkEntry(
            sha: sha,
            crc: crc,
            offset: offset,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )
    }
}
