// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Security)
import Security
#endif

/// The credential-store seam. Session secrets (refresh token, guard data, the
/// machine id) are read and written only through this protocol; nothing else
/// in the client persists them.
///
/// - On device the implementation is `KeychainSecretStore` (Security.framework,
///   this-device-only, not synchronised).
/// - The Linux host's tests use `MemorySecretStore` or `FileSecretStore`.
public protocol SecretStore: Sendable {
    var backendName: String { get }
    func read(_ key: String) throws -> Secret<[UInt8]>?
    func write(_ key: String, _ value: Secret<[UInt8]>) throws
    func delete(_ key: String) throws
}

#if canImport(Security)
/// iOS/macOS Keychain generic-password items under one service name.
///
/// Every item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (never in
/// a backup restored to another device) and not synchronisable (never in
/// iCloud Keychain). With `accessGroup` nil, as the app uses it, Security
/// places items in the app's own default access group (its first
/// `keychain-access-groups` entry, else its application identifier), so no
/// other app can read them.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let accessGroup: String?
    public var backendName: String { "keychain" }
    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecAttrSynchronizable as String: false]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read(_ key: String) throws -> Secret<[UInt8]>? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw ClientError.credentialStore("keychain read \(status)") }
        return Secret([UInt8](data))
    }

    public func write(_ key: String, _ value: Secret<[UInt8]>) throws {
        let attrs: [String: Any] = [kSecValueData as String: Data(value.value),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientError.credentialStore("keychain write \(status)") }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientError.credentialStore("keychain delete \(status)") }
    }

    /// The protection attributes of a stored item, never its data: the access
    /// group it landed in, its accessibility class and whether it syncs. For
    /// the device check that the item is where this type says it is.
    public struct ItemProtection: Sendable {
        public var accessGroup: String
        public var accessible: String
        public var synchronizable: Bool
        /// True for `AfterFirstUnlockThisDeviceOnly` and no sync.
        public var isThisDeviceOnly: Bool {
            accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) && !synchronizable
        }
    }

    public func protection(_ key: String) throws -> ItemProtection? {
        var q = query(key)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let a = out as? [String: Any] else { throw ClientError.credentialStore("keychain attributes \(status)") }
        let sync = (a[kSecAttrSynchronizable as String] as? Bool) ?? ((a[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false)
        return ItemProtection(accessGroup: a[kSecAttrAccessGroup as String] as? String ?? "?",
                              accessible: a[kSecAttrAccessible as String] as? String ?? "?",
                              synchronizable: sync)
    }
}
#endif

/// A stand-in for the Linux host's tests: one 0600 file per key in a 0700
/// directory, replaced atomically. Never the on-device store.
public struct FileSecretStore: SecretStore {
    public let directory: URL
    public var backendName: String { "file-standin" }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func url(_ key: String) throws -> URL {
        guard key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw ClientError.credentialStore("bad key name")
        }
        return directory.appendingPathComponent(key)
    }

    public func read(_ key: String) throws -> Secret<[UInt8]>? {
        let u = try url(key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return Secret([UInt8](try Data(contentsOf: u)))
    }

    public func write(_ key: String, _ value: Secret<[UInt8]>) throws {
        let u = try url(key)
        let tmp = directory.appendingPathComponent(".\(key).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(value.value), attributes: [.posixPermissions: 0o600]) else {
            throw ClientError.credentialStore("cannot write \(key)")
        }
        guard rename(tmp.path, u.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ClientError.credentialStore("cannot commit \(key)")
        }
    }

    public func delete(_ key: String) throws {
        let u = try url(key)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }
}

/// Test double.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: [UInt8]] = [:]
    private let lock = NSLock()
    public var backendName: String { "memory" }
    public init() {}
    public func read(_ key: String) throws -> Secret<[UInt8]>? { lock.withLock { items[key].map(Secret.init) } }
    public func write(_ key: String, _ value: Secret<[UInt8]>) throws { lock.withLock { items[key] = value.value } }
    public func delete(_ key: String) throws { _ = lock.withLock { items.removeValue(forKey: key) } }
}
