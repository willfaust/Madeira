// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Signed, data-only fixes keyed by Triage signature. A pack can only set the allowlisted settings below, to allowed values.
enum CuratorFixPack {
    static let publicKeyBase64 = "KF/HCPQPrzcQe1h17d7584B5HAPFr+MySMYmmOdt/cI="

    enum Value: Codable, Equatable {
        case bool(Bool)
        case int(Int)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else { self = .int(try c.decode(Int.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let b): try c.encode(b)
            case .int(let i): try c.encode(i)
            }
        }

        var description: String {
            switch self {
            case .bool(let b): return b ? "on" : "off"
            case .int(let i): return String(i)
            }
        }
    }

    struct Change: Codable, Equatable {
        let key: String
        let value: Value
    }

    struct Fix: Codable, Equatable, Identifiable {
        let id: String
        let signature: String
        let title: String
        let summary: String
        let source: String?
        let changes: [Change]
    }

    struct Pack: Codable, Equatable {
        let version: Int
        let fixes: [Fix]
    }

    enum PackError: Error, Equatable {
        case malformed
        case badSignature
        case unsupportedVersion
        case disallowedChange(String)
    }

    private struct Envelope: Decodable {
        let payload: String
        let signature: String
    }

    /// Settings a fix may change, with the values each accepts.
    private static let allowed: [String: (Value) -> Bool] = [
        JITBootstrap.codeCacheKey: { [.int(512), .int(1024), .int(1536)].contains($0) },
        JITCoordinator.autoEnableKey: { if case .bool = $0 { return true } else { return false } },
        EngineTuning.refreshKey: { [.int(30), .int(60), .int(120)].contains($0) },
        EngineTuning.superblocksKey: { if case .bool = $0 { return true } else { return false } },
        EngineTuning.wfiSpinKey: { if case .bool = $0 { return true } else { return false } },
        EngineTuning.fastFlushKey: { if case .bool = $0 { return true } else { return false } },
    ]

    /// Checks the Curve25519 signature over the payload bytes, then every change against the allowlist.
    static func verify(_ envelope: Data, publicKeyBase64: String = publicKeyBase64) throws -> Pack {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: envelope),
              let payload = Data(base64Encoded: env.payload),
              let signature = Data(base64Encoded: env.signature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw PackError.malformed }
        guard key.isValidSignature(signature, for: payload) else { throw PackError.badSignature }
        guard let pack = try? JSONDecoder().decode(Pack.self, from: payload) else { throw PackError.malformed }
        guard pack.version == 1 else { throw PackError.unsupportedVersion }
        for change in pack.fixes.flatMap(\.changes) {
            guard let accepts = allowed[change.key], accepts(change.value) else { throw PackError.disallowedChange(change.key) }
        }
        return pack
    }

    /// The bundled pack. A pack that fails verification is ignored.
    static func bundled(in bundle: Bundle = .main) -> Pack? {
        guard let url = bundle.url(forResource: "curator-fixpack", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? verify(data)
    }

    static func fix(for signature: String, in pack: Pack?) -> Fix? {
        pack?.fixes.first { $0.signature == signature }
    }

    private static func backupKey(_ fix: Fix) -> String { "curator.fixpack.backup.\(fix.id)" }

    private struct Backup: Codable {
        struct Entry: Codable { let key: String; let value: Value? }
        let entries: [Entry]
    }

    private static func current(_ key: String, _ defaults: UserDefaults) -> Value? {
        guard let object = defaults.object(forKey: key) as? NSNumber else { return nil }
        return CFGetTypeID(object) == CFBooleanGetTypeID() ? .bool(object.boolValue) : .int(object.intValue)
    }

    static func isApplied(_ fix: Fix, defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: backupKey(fix)) != nil
    }

    /// Saves the current value of every setting the fix touches (or its absence), then sets the new values.
    static func apply(_ fix: Fix, defaults: UserDefaults = .standard) {
        guard !isApplied(fix, defaults: defaults) else { return }
        let backup = Backup(entries: fix.changes.map { Backup.Entry(key: $0.key, value: current($0.key, defaults)) })
        defaults.set(try? JSONEncoder().encode(backup), forKey: backupKey(fix))
        for change in fix.changes {
            switch change.value {
            case .bool(let b): defaults.set(b, forKey: change.key)
            case .int(let i): defaults.set(i, forKey: change.key)
            }
        }
        TriptychLog.log("curator", "applied fix pack \(fix.id)")
    }

    /// Puts back what apply saved: old values return and settings that did not exist are removed.
    static func revert(_ fix: Fix, defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: backupKey(fix)),
              let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return }
        for entry in backup.entries {
            switch entry.value {
            case .bool(let b)?: defaults.set(b, forKey: entry.key)
            case .int(let i)?: defaults.set(i, forKey: entry.key)
            case nil: defaults.removeObject(forKey: entry.key)
            }
        }
        defaults.removeObject(forKey: backupKey(fix))
        TriptychLog.log("curator", "reverted fix pack \(fix.id)")
    }
}
