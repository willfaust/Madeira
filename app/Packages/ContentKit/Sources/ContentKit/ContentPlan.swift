// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A chunk of content as a store serves it: fetched once, verified, then
/// written to every place a file uses it. What a chunk's plain bytes are
/// checked against is the store's (`check`); how it is fetched and decoded is
/// its `ContentChunkSource`'s, from `group` and `locator`.
///
///   Steam  key = SHA-1, check = sha1 (the source also checks Adler-32), group = depot ID
///   GOG    key = the chunk's md5, check = md5, locator = its compressed md5
///   Epic   key = the chunk GUID, check = sha1 of the whole chunk, locator = its CDN path
public struct ContentChunk: Sendable, Hashable {
    public enum Check: Sendable, Hashable {
        case sha1([UInt8])
        case md5([UInt8])
        case none
    }

    /// Unique within a plan: chunks with the same key are one download.
    public var key: [UInt8]
    /// Plain (decoded) bytes.
    public var size: UInt32
    public var compressedSize: UInt32
    public var check: Check
    public var group: UInt32
    public var locator: String?
    /// A store-specific checksum the source verifies (Steam: Adler-32).
    public var checksum: UInt32?

    public init(key: [UInt8], size: UInt32, compressedSize: UInt32, check: Check, group: UInt32 = 0,
                locator: String? = nil, checksum: UInt32? = nil) {
        self.key = key
        self.size = size
        self.compressedSize = compressedSize
        self.check = check
        self.group = group
        self.locator = locator
        self.checksum = checksum
    }

    /// The 20 bytes a journal record holds for this chunk.
    public var journalKey: [UInt8] { ContentPlan.key20(key) }

    /// Whether `plain` is this chunk's content.
    public func matches(_ plain: [UInt8]) -> Bool {
        guard plain.count == Int(size) else { return false }
        switch check {
        case let .sha1(want): return SHA1.hash(plain) == want
        case let .md5(want): return MD5.hash(plain) == want
        case .none: return true
        }
    }
}

/// One stretch of a file: `length` bytes of chunk `chunk` from `offsetInChunk`,
/// at `fileOffset` in the file. Steam's and GOG's parts are whole chunks;
/// Epic's take slices.
public struct ContentPart: Sendable, Hashable {
    /// Index into `ContentPlan.chunks`.
    public var chunk: Int
    public var offsetInChunk: UInt32
    public var length: UInt32
    public var fileOffset: UInt64

    public init(chunk: Int, offsetInChunk: UInt32 = 0, length: UInt32, fileOffset: UInt64) {
        self.chunk = chunk
        self.offsetInChunk = offsetInChunk
        self.length = length
        self.fileOffset = fileOffset
    }
}

public enum FileHash: Sendable, Hashable {
    case sha1([UInt8])
    case md5([UInt8])
    case none

    var bytes: [UInt8]? {
        switch self {
        case let .sha1(b), let .md5(b): b
        case .none: nil
        }
    }

    public var hex: String? { bytes?.hex }
}

public struct ContentFile: Sendable {
    public var path: String
    public var size: UInt64
    public var hash: FileHash
    public var parts: [ContentPart]
    /// Global index of this file's first part (the journal's numbering).
    public var firstPart: Int

    public init(path: String, size: UInt64, hash: FileHash, parts: [ContentPart], firstPart: Int = 0) {
        self.path = path
        self.size = size
        self.hash = hash
        self.parts = parts
        self.firstPart = firstPart
    }
}

/// Every file of a title in one directory, as the install engine stages it:
/// each file a list of parts, each part a stretch of a chunk. The store's
/// planner (Steam's InstallPlan, GOG's and Epic's) checks the paths and builds it.
public struct ContentPlan: Sendable {
    public var files: [ContentFile]
    public var directories: [String]
    public var chunks: [ContentChunk]
    public var totalBytes: UInt64
    public var partCount: Int
    /// Names the plan: a journal written for another plan never replays against this one.
    public var identity: [UInt8]

    /// Numbers the parts in file order and totals the sizes. `chunks` must be unique by key.
    public init(files: [ContentFile], directories: [String], chunks: [ContentChunk], identity: [UInt8]) {
        var files = files
        var next = 0
        for i in files.indices {
            files[i].firstPart = next
            next += files[i].parts.count
        }
        self.files = files
        self.directories = directories
        self.chunks = chunks
        self.totalBytes = files.reduce(0) { $0 + $1.size }
        self.partCount = next
        self.identity = identity
    }

    /// The file holding global part `k` (binary search over `firstPart`).
    public func fileIndex(forPart k: Int) -> Int? {
        guard k >= 0, k < partCount, !files.isEmpty else { return nil }
        var lo = 0, hi = files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if files[mid].firstPart <= k { lo = mid } else { hi = mid - 1 }
        }
        let f = files[lo]
        return k < f.firstPart + f.parts.count ? lo : nil
    }

    public func part(_ k: Int) -> ContentPart? {
        fileIndex(forPart: k).map { files[$0].parts[k - files[$0].firstPart] }
    }

    /// A key as a journal stores it: 20 bytes, zero-padded, or the SHA-1 of a longer one.
    static func key20(_ key: [UInt8]) -> [UInt8] {
        if key.count == 20 { return key }
        if key.count < 20 { return key + [UInt8](repeating: 0, count: 20 - key.count) }
        return SHA1.hash(key)
    }
}

/// Where the install engine gets a chunk's plain bytes. An implementation
/// returns bytes already checked against the chunk's size and `check`, or throws.
public protocol ContentChunkSource: Sendable {
    func chunk(_ c: ContentChunk) async throws -> [UInt8]
}
