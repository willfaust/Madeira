// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 David Brookes
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Query the actual destination while its security scope is held. Some volumes
/// report zero for important-usage capacity despite having ordinary free space.
enum SteamStorageCapacity {
    nonisolated static func resolve(important: Int64?, ordinary: Int64?, filesystem: Int64?) throws -> Int64 {
        let known = [important, ordinary, filesystem].compactMap { $0 }.filter { $0 >= 0 }
        guard let available = known.max() else { throw CocoaError(.fileReadUnknown) }
        return available
    }

    nonisolated static func availableBytes(at destination: URL) throws -> Int64 {
        // Start with a fresh URL so a previous capacity observation is not cached.
        let url = URL(fileURLWithPath: destination.path)
        var important: Int64?
        #if canImport(Darwin)
        important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #endif
        if let important, important > 0 { return important }
        let ordinary = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map { Int64($0) }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        let filesystem = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        // A genuine zero remains zero. Failed queries never become unlimited space.
        return try resolve(important: important, ordinary: ordinary, filesystem: filesystem)
    }
}

enum SteamStorageOperation {
    /// A network/depot failure is not evidence that a healthy volume vanished.
    /// Cancellation must not trigger another provider lookup or change availability.
    static func run<Value>(_ operation: () async throws -> Value,
                           validate: () async throws -> Void) async throws -> Value {
        let value: Value
        do { value = try await operation() }
        catch {
            if error is CancellationError { throw error }
            try await validate()
            throw error
        }
        try await validate()
        return value
    }
}

/// Persistent identity is independent of the removable volume's current mount path.
struct SteamStorageLibrary: Codable, Equatable, Identifiable, Sendable {
    static let internalID = "internal"
    let id: String
    var name: String
    var bookmark: Data?
    var windowsDrive: String { id == Self.internalID ? "C" : "E" }
    static let internalLibrary = Self(id: internalID, name: "iPad", bookmark: nil)
}

/// A saved location never contains a removable volume's native mount path.
/// Missing library IDs in older records mean the existing internal library.
struct SteamStorageLocation: Codable, Equatable, Sendable {
    let libraryID: String
    let relativePath: String

    init(libraryID: String = SteamStorageLibrary.internalID, relativePath: String) throws {
        guard libraryID == SteamStorageLibrary.internalID || UUID(uuidString: libraryID) != nil else {
            throw SteamStorageError.invalidRecord
        }
        _ = try SteamStoragePath.components(relativePath)
        self.libraryID = libraryID
        self.relativePath = relativePath
    }

    private enum CodingKeys: String, CodingKey { case libraryID, relativePath }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(libraryID: fields.decodeIfPresent(String.self, forKey: .libraryID) ?? SteamStorageLibrary.internalID,
                      relativePath: fields.decode(String.self, forKey: .relativePath))
    }

    func windowsPath(in library: SteamStorageLibrary) throws -> String {
        guard library.id == libraryID else { throw SteamStorageError.unavailable(.identityMismatch) }
        return try SteamStoragePath.windows(relativePath, library: library)
    }

    /// `root` must come from the matching library's live access operation.
    func nativeURL(in library: SteamStorageLibrary, root: URL) throws -> URL {
        guard library.id == libraryID else { throw SteamStorageError.unavailable(.identityMismatch) }
        if libraryID != SteamStorageLibrary.internalID { try SteamStorageIdentity.verify(libraryID, root: root) }
        return try SteamStoragePath.native(relativePath, root: root)
    }
}

/// Persisted before queueing the first byte. A partial install keeps its original
/// library after restart; updates and repairs cannot silently change it either.
struct SteamStorageAssignment: Codable, Equatable, Sendable {
    let appID: Int
    let location: SteamStorageLocation
    var name: String
    var installed: Bool
    var buildID: Int?
    var bytes: Int64?
    /// Optional for catalogs written before queue-state persistence. A paused
    /// update remains pending even though its old install record still exists.
    var pending: Bool?
    /// Display snapshot only; the downloader still verifies its SSD journals on resume.
    var transferProgress: SteamStorageTransferProgress?
}

struct SteamStorageTransferProgress: Codable, Equatable, Sendable {
    let doneBytes: UInt64
    let totalBytes: UInt64
}

/// Metadata stays internal so unavailable games and partial downloads remain
/// visible. Payloads, manifests, journals and depot caches stay at `location`.
/// All mutation is transactional: a failed save leaves the prior catalog intact.
struct SteamStorageCatalog: Codable, Equatable {
    private(set) var version = 1
    private(set) var external: SteamStorageLibrary?
    private(set) var assignments: [Int: SteamStorageAssignment] = [:]

    init() {}

    func library(_ id: String) throws -> SteamStorageLibrary {
        if id == SteamStorageLibrary.internalID { return .internalLibrary }
        guard let external, external.id == id else { throw SteamStorageError.invalidRecord }
        return external
    }

    mutating func register(_ library: SteamStorageLibrary) throws {
        guard UUID(uuidString: library.id) != nil, let bookmark = library.bookmark, !bookmark.isEmpty,
              external == nil || external?.id == library.id else { throw SteamStorageError.invalidRecord }
        external = library
    }

    mutating func assign(_ assignment: SteamStorageAssignment) throws {
        guard assignment.appID > 0, assignment.appID < Int(UInt32.max) else { throw SteamStorageError.invalidRecord }
        _ = try library(assignment.location.libraryID)
        if let existing = assignments[assignment.appID], existing.location != assignment.location {
            throw SteamStorageError.invalidRecord
        }
        var next = assignment
        if next.pending == nil { next.pending = assignments[assignment.appID]?.pending }
        if next.pending == true, next.transferProgress == nil {
            next.transferProgress = assignments[assignment.appID]?.transferProgress
        }
        if next.pending == false { next.transferProgress = nil }
        assignments[assignment.appID] = next
    }

    /// Only call after successful payload/record deletion under live access.
    mutating func remove(appID: Int) { assignments.removeValue(forKey: appID) }

    func validate() throws {
        guard version == 1, assignments.count <= 100_000 else { throw SteamStorageError.invalidRecord }
        if let external {
            guard UUID(uuidString: external.id) != nil, let bookmark = external.bookmark,
                  !bookmark.isEmpty, bookmark.count <= 1 << 20 else { throw SteamStorageError.invalidRecord }
        }
        for (key, value) in assignments {
            guard key == value.appID, key > 0, key < Int(UInt32.max),
                  value.name.utf8.count <= 4096, (value.bytes ?? 0) >= 0 else { throw SteamStorageError.invalidRecord }
            _ = try library(value.location.libraryID)
            _ = try SteamStoragePath.components(value.location.relativePath)
        }
    }

    static func load(from file: URL) throws -> Self {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Self()
        }
        guard data.count <= 16 << 20 else { throw SteamStorageError.invalidRecord }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    mutating func transaction(file: URL, _ edit: (inout Self) throws -> Void) throws {
        var next = self
        try edit(&next)
        try next.validate()
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        self = next
    }
}

enum SteamStorageAvailability: String, Codable {
    case available, disconnected, permissionDenied, readOnly, identityMismatch
}

enum SteamStorageError: Error, LocalizedError {
    case unavailable(SteamStorageAvailability), unsafePath, unsupportedLocation, invalidRecord, mappingConflict
    var errorDescription: String? {
        switch self {
        case .unavailable(.disconnected): return "Reconnect the registered SSD and try again."
        case .unavailable(.permissionDenied): return "Select the registered folder again to renew access."
        case .unavailable(.readOnly): return "The SSD is read-only."
        case .unavailable(.identityMismatch): return "This is not the registered library folder. Select the original folder."
        case .unavailable(.available): return "The library could not be accessed."
        case .unsafePath: return "The requested path leaves the registered library."
        case .unsupportedLocation: return "Select a dedicated folder on a locally attached drive. Cloud and network folders are unsupported."
        case .invalidRecord: return "The saved library registration is invalid."
        case .mappingConflict: return "The Windows SSD drive mapping is already in use. The registered library folder is unchanged."
        }
    }
}

/// Replace only an owned symlink; never replace a directory or payload. The
/// caller establishes ownership from internal metadata before calling this.
enum SteamStorageMapping {
    static func replace(_ link: URL, root: URL, libraryID: String, ownerID: String?) throws {
        try SteamStorageIdentity.verify(libraryID, root: root)
        let fm = FileManager.default
        do {
            let attributes = try fm.attributesOfItem(atPath: link.path)
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw SteamStorageError.mappingConflict
            }
            let sameTarget = link.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path
            guard ownerID == libraryID || sameTarget else { throw SteamStorageError.mappingConflict }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".madeira-link-" + UUID().uuidString)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: root)
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, link.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Paths within a registered game library.
/// Callers must keep external access and coordination active while using URLs.
enum SteamStoragePath {
    static let externalAlias = "MadeiraExternalLibrary"
    static let externalWindowsRoot = "C:\\" + externalAlias

    static func components(_ relative: String) throws -> [String] {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, normalized.utf8.count < 4096,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.contains(":") && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else {
            throw SteamStorageError.unsafePath
        }
        return parts
    }

    static func native(_ relative: String, root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let parts = try components(relative)
        var candidate = base
        for part in parts {
            candidate.appendPathComponent(part)
            // Resolving a whole nonexistent leaf can leave an existing symlink
            // ancestor unresolved on Darwin. Check each component, including
            // dangling links, before appending the next one.
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw SteamStorageError.unsafePath
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { }
        }

        return candidate
    }

    static func windows(_ relative: String, library: SteamStorageLibrary) throws -> String {
        library.windowsDrive + ":\\" + (try components(relative)).joined(separator: "\\")
    }
}

/// The marker prevents a different disk mounted at the old URL from inheriting
/// an install identity. It is not an authentication secret. Never recreate a
/// missing marker during reconnect: that requires an explicit new registration.
enum SteamStorageIdentity {
    static let marker = ".madeira-library-id"

    static func verify(_ id: String, root: URL) throws {
        let url = try SteamStoragePath.native(marker, root: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 1024) <= 128,
              try String(contentsOf: url, encoding: .utf8) == id else {
            throw SteamStorageError.unavailable(.identityMismatch)
        }
    }

    static func register(root: URL) throws -> String {
        let url = try SteamStoragePath.native(marker, root: root)
        // A registration can adopt an existing valid marker, never overwrite it.
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 1024) <= 128 else {
                throw SteamStorageError.invalidRecord
            }
            let id = try String(contentsOf: url, encoding: .utf8)
            guard UUID(uuidString: id) != nil else { throw SteamStorageError.invalidRecord }
            try verify(id, root: root)
            return id
        }
        let id = UUID().uuidString
        try Data(id.utf8).write(to: url, options: .withoutOverwriting)
        return id
    }
}

/// Bridges a coordinated synchronous accessor to an async downloader/save task.
/// Cancellation reaches the task, but the accessor cannot return (and release
/// access) until that task has actually finished closing its files.
final class SteamStorageAsyncWork<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var started = false
    private var outcome: Result<Value, Error>?

    func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
    }

    /// Invoke exactly once, from a worker, inside the coordinated accessor.
    func execute(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        lock.lock()
        precondition(!started, "An access operation can only execute once")
        started = true
        if cancelled { lock.unlock(); throw CancellationError() }
        let work = Task.detached { [self] in
            let result: Result<Value, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await operation())
            } catch { result = .failure(error) }
            lock.withLock { outcome = result }
            finished.signal()
        }
        task = work
        if cancelled { work.cancel() }
        lock.unlock()
        finished.wait()
        return try lock.withLock {
            task = nil
            return try outcome!.get()
        }
    }
}

#if os(iOS) || os(macOS)
/// Shared operation/session access. The coordinator's worker retains only the
/// completion semaphore; the last client releases access when its lease dies.
final class SteamExternalLease: @unchecked Sendable {
    let root: URL
    let library: SteamStorageLibrary
    let writable: Bool
    private let finished: DispatchSemaphore
    private init(root: URL, library: SteamStorageLibrary, writable: Bool, finished: DispatchSemaphore) {
        self.root = root; self.library = library; self.writable = writable; self.finished = finished
    }
    deinit { finished.signal() }
    /// Use in defer to keep the lease alive across every await and final handle close.
    func keepAlive() {}
    func validate() throws { try SteamStorageIdentity.verify(library.id, root: root) }

    static func open(_ library: SteamStorageLibrary) async throws -> SteamExternalLease {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var delivered = false
                func enter(write: Bool) throws {
                    var updated = library
                    _ = try SteamExternalAccess.withLibrary(library, write: write, registrationUpdated: { updated = $0 }) { root in
                        let finished = DispatchSemaphore(value: 0)
                        delivered = true
                        continuation.resume(returning: SteamExternalLease(root: root, library: updated, writable: write, finished: finished))
                        finished.wait()
                    }
                }
                do {
                    do { try enter(write: true) }
                    catch where !delivered && SteamExternalAccess.availability(for: error) == .readOnly { try enter(write: false) }
                } catch {
                    if !delivered { continuation.resume(throwing: error) }
                }
            }
        }
    }
}

/// One balanced scope and a coordinated accessor cover the *whole* synchronous
/// operation, including all POSIX handles and mappings. Run on a worker queue.
/// Never return an open handle, mmap pointer or task from this accessor.
/// A Wine session will require an accessor that ends only when Wine has stopped;
/// this data probe does not claim to have established that runtime contract.
enum SteamExternalAccess {
    /// Coordinates the entire async operation, including cancellation cleanup.
    /// The refreshed registration is returned only after the accessor has ended.
    /// Never let the closure return a live handle or a task using the root.
    static func perform<Value: Sendable>(_ library: SteamStorageLibrary, write: Bool,
                                         _ operation: @escaping @Sendable (URL) async throws -> Value) async throws -> (Value, SteamStorageLibrary) {
        let work = SteamStorageAsyncWork<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try withLibrary(library, write: write) { root in
                            try work.execute { try await operation(root) }
                        }
                    })
                }
            }
        } onCancel: { work.cancel() }
    }

    static func coordinate<T>(url: URL, write: Bool, _ body: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            throw SteamStorageError.unavailable(.permissionDenied)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        if write, try url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true {
            throw SteamStorageError.unavailable(.readOnly)
        }
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if write {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) {
                scoped in outcome = Result { try body(scoped) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
                scoped in outcome = Result { try body(scoped) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw SteamStorageError.unavailable(.disconnected) }
        return try outcome.get()
    }

    static func register(_ url: URL, replacing current: SteamStorageLibrary? = nil) throws -> SteamStorageLibrary {
        try coordinate(url: url, write: true) { root in
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
            guard values.isDirectory == true, values.isUbiquitousItem != true, values.volumeIsLocal == true else {
                throw SteamStorageError.unsupportedLocation
            }
            guard values.volumeIsReadOnly != true else { throw SteamStorageError.unavailable(.readOnly) }
            let id: String
            if let current {
                try SteamStorageIdentity.verify(current.id, root: root)
                id = current.id
            } else { id = try SteamStorageIdentity.register(root: root) }
            return SteamStorageLibrary(id: id, name: root.lastPathComponent,
                                       bookmark: try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
        }
    }

    /// Return refreshed bookmark data alongside the result; the caller persists it
    /// only after identity validation. No fallback to an internal path on failure.
    static func withLibrary<T>(_ library: SteamStorageLibrary, write: Bool,
                               registrationUpdated: ((SteamStorageLibrary) -> Void)? = nil,
                               _ body: (URL) throws -> T) throws -> (T, SteamStorageLibrary) {
        guard library.id != SteamStorageLibrary.internalID, let bookmark = library.bookmark else {
            throw SteamStorageError.invalidRecord
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        return try coordinate(url: url, write: write) { root in
            try SteamStorageIdentity.verify(library.id, root: root)
            let values = try root.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            if write && values.volumeIsReadOnly == true { throw SteamStorageError.unavailable(.readOnly) }
            var updated = library
            if stale { updated.bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
            registrationUpdated?(updated)
            return (try body(root), updated)
        }
    }

    static func availability(for error: Error) -> SteamStorageAvailability {
        if case SteamStorageError.unavailable(let state) = error { return state }
        var current: NSError? = error as NSError
        // Providers can wrap the filesystem error. Bound traversal in case a
        // malformed error chain repeats; don't turn permissions into "unplugged".
        for _ in 0..<8 {
            guard let e = current else { break }
            if e.domain == NSCocoaErrorDomain {
                if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(e.code) { return .permissionDenied }
                if e.code == NSFileWriteVolumeReadOnlyError { return .readOnly }
            }
            if e.domain == NSPOSIXErrorDomain {
                if [Int(EACCES), Int(EPERM)].contains(e.code) { return .permissionDenied }
                if e.code == Int(EROFS) { return .readOnly }
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .disconnected
    }
}
#endif
