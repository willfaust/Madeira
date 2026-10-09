// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Valve's text KeyValues format is used for library folders and app manifests.
// Keep this reader independent of the UI. SteamLibraryFolders serializes only
// the explicitly registered library metadata; discovery remains read-only.
indirect enum SteamValue: Sendable {
    case text(String)
    case object([String: SteamValue])
    var fields: [String: SteamValue] { if case .object(let value) = self { return value }; return [:] }
    var string: String? { if case .text(let value) = self { return value }; return nil }
    subscript(_ key: String) -> SteamValue? { fields[key.lowercased()] }
}

enum SteamFileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

struct SteamKeyValues {
    private var bytes: [UInt8]
    private var position = 0
    private var tokens = 0
    init(_ data: Data) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw SteamFileError.invalid("Steam metadata is too large.") }
        bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { position = 3 }
    }
    private enum Token: Equatable { case word(String), open, close }
    private mutating func token() throws -> Token? {
        while position < bytes.count {
            if bytes[position] <= 32 { position += 1; continue }
            if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                while position < bytes.count && bytes[position] != 10 { position += 1 }
                continue
            }
            break
        }
        guard position < bytes.count else { return nil }
        tokens += 1
        guard tokens <= 100_000 else { throw SteamFileError.invalid("Steam metadata has too many entries.") }
        let first = bytes[position]; position += 1
        if first == 123 { return .open }; if first == 125 { return .close }
        var value: [UInt8] = []
        if first == 34 {
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 { return .word(String(decoding: value, as: UTF8.self)) }
                if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 {
                    value.append(bytes[position]); position += 1
                } else { value.append(byte) }
                guard value.count <= 16_384 else { throw SteamFileError.invalid("Steam metadata contains an oversized value.") }
            }
            throw SteamFileError.invalid("Steam metadata is incomplete. Refresh after the download finishes.")
        }
        value.append(first)
        while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 {
            value.append(bytes[position]); position += 1
            guard value.count <= 16_384 else { throw SteamFileError.invalid("Steam metadata contains an oversized value.") }
        }
        return .word(String(decoding: value, as: UTF8.self))
    }
    mutating func read() throws -> SteamValue { .object(try object(depth: 0)) }
    private mutating func object(depth: Int) throws -> [String: SteamValue] {
        guard depth < 32 else { throw SteamFileError.invalid("Steam metadata is nested too deeply.") }
        var result: [String: SteamValue] = [:]
        while let key = try token() {
            if key == .close {
                guard depth > 0 else { throw SteamFileError.invalid("Steam metadata has an unexpected closing brace.") }
                return result
            }
            guard case .word(let name) = key, let value = try token(), value != .close else {
                throw SteamFileError.invalid("Steam metadata is incomplete. Try refreshing it.")
            }
            switch value {
            case .open: result[name.lowercased()] = .object(try object(depth: depth + 1))
            case .word(let text): result[name.lowercased()] = .text(text)
            case .close: break
            }
        }
        guard depth == 0 else { throw SteamFileError.invalid("Steam metadata is incomplete. Try refreshing it.") }
        return result
    }
}
