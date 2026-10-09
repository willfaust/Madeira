// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 David Brookes
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Darwin

/// Ordinary data only. A pass is not evidence of Windows executable loading.
enum SteamStorageProbe {
    static func run(root: URL, largeFile: Bool = false) throws -> String {
        let fm = FileManager.default
        let scratch = try SteamStoragePath.native(".madeira-probe-" + UUID().uuidString, root: root)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        do {
            let original = scratch.appendingPathComponent("data.bin")
            let renamed = scratch.appendingPathComponent("renamed.bin")
            let fd = open(original.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw posixError() }
            do {
                defer { close(fd) }
                let size = Int(getpagesize())
                guard ftruncate(fd, off_t(size)) == 0 else { throw posixError() }
                let bytes: [UInt8] = [0x4d, 0x53, 0x53, 0x44]
                let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 128) }
                guard wrote == bytes.count, lseek(fd, 128, SEEK_SET) == 128 else { throw posixError() }
                var readback = [UInt8](repeating: 0, count: bytes.count)
                let got = readback.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard got == bytes.count, readback == bytes else { throw CocoaError(.fileReadCorruptFile) }
                guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { throw posixError() }
                do {
                    defer { munmap(mapped, size) }
                    guard mapped.load(fromByteOffset: 128, as: UInt8.self) == bytes[0] else { throw CocoaError(.fileReadCorruptFile) }
                    mapped.storeBytes(of: UInt8(0x7f), toByteOffset: 129, as: UInt8.self)
                    guard msync(mapped, size, MS_SYNC) == 0 else { throw posixError() }
                }
                if largeFile {
                    // Sparse boundary probe, not a throughput or physical-capacity test.
                    // Some filesystems allocate this fully; the UI explicitly opts in.
                    let offset: off_t = 4 * 1024 * 1024 * 1024 + 17
                    var byte: UInt8 = 0x42
                    guard pwrite(fd, &byte, 1, offset) == 1 else { throw posixError() }
                    byte = 0
                    guard pread(fd, &byte, 1, offset) == 1, byte == 0x42 else { throw CocoaError(.fileReadCorruptFile) }
                }
                guard fsync(fd) == 0 else { throw posixError() }
            }
            try fm.moveItem(at: original, to: renamed)
            let reopened = open(renamed.path, O_RDONLY | O_NOFOLLOW)
            guard reopened >= 0 else { throw posixError() }
            var byte: UInt8 = 0
            let got = pread(reopened, &byte, 1, 129)
            close(reopened)
            guard got == 1, byte == 0x7f else { throw CocoaError(.fileReadCorruptFile) }
            try fm.removeItem(at: scratch)
            return "PASS: create, write, read, seek, shared mmap, msync, rename, close/reopen and cleanup" +
                (largeFile ? "; offset beyond 4 GiB" : "") + ". Windows EXE/DLL loading is not tested."
        } catch {
            // Do not mask the operation error with a secondary cleanup failure.
            // Only this unique scratch directory is eligible for cleanup.
            try? fm.removeItem(at: scratch)
            throw error
        }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
