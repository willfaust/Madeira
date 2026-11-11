// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// What a Windows program says about itself in its resources: its product name and its icon.
/// Reads only the headers and the .rsrc section of the file, so a multi-gigabyte game costs a few
/// kilobytes. Foundation only (tests/host/check-game-candidate.py compiles it).
struct PEResources {
    private let rsrc: Data
    private let rsrcVA: UInt32

    /// nil when the file is not a PE or has no resources.
    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        let dos = read(0, 64)
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return nil }
        let base = UInt64(Self.u32(dos, 60))
        guard base >= 64, base < 16 * 1024 * 1024 else { return nil }
        let header = read(base, 264)
        guard header.count == 264, Self.u32(header, 0) == 0x4550 else { return nil }
        let sections = Int(Self.u16(header, 6)), optional = Int(Self.u16(header, 20))
        guard sections > 0, sections <= 96, optional >= 112 else { return nil }
        let pe64 = Self.u16(header, 24) == 0x20b
        guard pe64 || Self.u16(header, 24) == 0x10b else { return nil }
        // Data directory 2 is the resource table: 96 (PE32) or 112 (PE32+) bytes into the optional header.
        let dirAt = 24 + (pe64 ? 112 : 96) + 2 * 8
        guard dirAt + 8 <= header.count else { return nil }
        let resourceRVA = Self.u32(header, dirAt)
        guard resourceRVA != 0 else { return nil }
        let table = read(base + 24 + UInt64(optional), sections * 40)
        guard table.count == sections * 40 else { return nil }
        for i in 0..<sections {
            let o = i * 40
            let va = Self.u32(table, o + 12), virtualSize = Self.u32(table, o + 8)
            let rawSize = Self.u32(table, o + 16), rawAt = Self.u32(table, o + 20)
            guard resourceRVA >= va, resourceRVA < va + max(virtualSize, rawSize) else { continue }
            // The resource directory starts somewhere in its section: keep the whole section.
            guard rawSize > 0, rawSize <= 64 * 1024 * 1024 else { return nil }
            let data = read(UInt64(rawAt), Int(rawSize))
            guard data.count == Int(rawSize) else { return nil }
            rsrc = data; rsrcVA = va
            self.directory = Int(resourceRVA - va)
            return
        }
        return nil
    }

    private let directory: Int

    // MARK: Product name

    /// ProductName from the version resource, else FileDescription; nil when there is none.
    var productName: String? {
        guard let blob = resources(type: 16).first?.data else { return nil }
        for key in ["ProductName", "FileDescription"] {
            if let value = Self.string(key, in: blob), !value.isEmpty { return value }
        }
        return nil
    }

    private static func string(_ key: String, in blob: Data) -> String? {
        let needle = Data((key + "\0").utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        guard let r = blob.range(of: needle) else { return nil }
        // The value starts at the next 4-byte boundary of the version resource.
        var p = r.upperBound
        while p % 4 != 0 { p += 1 }
        var units: [UInt16] = []
        while p + 1 < blob.count {
            let u = u16(blob, p)
            if u == 0 { break }
            units.append(u); p += 2
            if units.count > 256 { break }
        }
        return String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Icon

    /// The largest icon as an .ico file (UIImage reads those): nil when the program has none.
    var icon: Data? {
        guard let group = resources(type: 14).first?.data, group.count >= 6 else { return nil }
        let count = Int(Self.u16(group, 4))
        var best: (id: UInt16, size: Int, w: UInt8, h: UInt8, colors: UInt8, planes: UInt16, bits: UInt16)?
        for i in 0..<min(count, 64) {
            let o = 6 + i * 14
            guard o + 14 <= group.count else { break }
            let size = Int(Self.u32(group, o + 8))
            if best == nil || size > best!.size {
                best = (Self.u16(group, o + 12), size, group[o], group[o + 1], group[o + 2], Self.u16(group, o + 4), Self.u16(group, o + 6))
            }
        }
        guard let b = best, let image = resources(type: 3).first(where: { $0.id == UInt32(b.id) })?.data, !image.isEmpty else { return nil }
        var ico = Data([0, 0, 1, 0, 1, 0, b.w, b.h, b.colors, 0])
        ico.append(contentsOf: [UInt8(b.planes & 0xff), UInt8(b.planes >> 8), UInt8(b.bits & 0xff), UInt8(b.bits >> 8)])
        for shift in [0, 8, 16, 24] { ico.append(UInt8((image.count >> shift) & 0xff)) }
        for shift in [0, 8, 16, 24] { ico.append(UInt8((22 >> shift) & 0xff)) }
        return ico + image
    }

    // MARK: Resource tree (type -> id -> language -> data)

    /// Every resource of one type, with its id.
    func resources(type: UInt32) -> [(id: UInt32, data: Data)] {
        var out: [(UInt32, Data)] = []
        for typeEntry in entries(at: directory) where typeEntry.id == type && typeEntry.isDirectory {
            for idEntry in entries(at: directory + typeEntry.offset) {
                var leaf = idEntry
                if idEntry.isDirectory, let lang = entries(at: directory + idEntry.offset).first { leaf = lang }
                guard !leaf.isDirectory, let data = leafData(directory + leaf.offset) else { continue }
                out.append((idEntry.id, data))
            }
        }
        return out
    }

    private struct Entry { var id: UInt32; var offset: Int; var isDirectory: Bool }

    private func entries(at offset: Int) -> [Entry] {
        guard offset >= 0, offset + 16 <= rsrc.count else { return [] }
        let count = Int(Self.u16(rsrc, offset + 12)) + Int(Self.u16(rsrc, offset + 14))
        var out: [Entry] = []
        for i in 0..<min(count, 512) {
            let o = offset + 16 + i * 8
            guard o + 8 <= rsrc.count else { break }
            let name = Self.u32(rsrc, o), target = Self.u32(rsrc, o + 4)
            out.append(Entry(id: name, offset: Int(target & 0x7fffffff), isDirectory: target & 0x80000000 != 0))
        }
        return out
    }

    private func leafData(_ offset: Int) -> Data? {
        guard offset >= 0, offset + 16 <= rsrc.count else { return nil }
        let rva = Self.u32(rsrc, offset), size = Int(Self.u32(rsrc, offset + 4))
        guard rva >= rsrcVA else { return nil }
        let start = Int(rva - rsrcVA)
        guard size > 0, size <= 16 * 1024 * 1024, start >= 0, start + size <= rsrc.count else { return nil }
        return rsrc.subdata(in: start..<start + size)
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { o >= 0 && o + 2 <= d.count ? UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 : 0 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return (0..<4).reduce(0) { $0 | UInt32(d[d.startIndex + o + $1]) << ($1 * 8) }
    }
}
