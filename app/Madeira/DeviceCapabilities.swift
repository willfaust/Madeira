import Foundation
import Darwin
import os

/// What *this* device can give the emulator, measured at launch.
///
/// Every number that decides how much headroom Madeira gets was a constant
/// lifted from the development device (an A15 / iPhone 13 Pro) and then applied
/// unchanged to every device that ran the app:
///
///   - The JIT pool is pinned at 896MB because that is what a 4096MB jetsam
///     budget can afford (ml423). A device with twice the memory therefore ran
///     the same translation cache and hit the same pool-exhaustion wall --
///     ml363 and ml420 both died with the pool full, and the fix each time was
///     another hand-tuned absolute number.
///   - The desktop is pinned at 1024x768 regardless of the panel behind it.
///
/// None of it was ever re-derived because nothing ever asked the device. This
/// does, and the pool policy below is expressed as the *ratio* the A15 proved
/// safe rather than as the A15's absolute number -- the ratio is the part that
/// transfers.
enum DeviceCapabilities {

    // MARK: - Identity

    /// `hw.machine`, e.g. "iPhone14,2" or "iPad13,4". Marketing names are
    /// deliberately not mapped: such a table rots, and the raw identifier is
    /// what the logs already key on.
    static let machine: String = sysctlString("hw.machine") ?? "unknown"

    /// `hw.model`, e.g. "D63AP" -- the board id, useful when `machine` alone is
    /// ambiguous across a refresh.
    static let model: String = sysctlString("hw.model") ?? "unknown"

    // MARK: - Memory

    /// Total installed RAM.
    static let physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// The jetsam budget this process may use before the kernel kills it.
    ///
    /// `os_proc_available_memory()` reports `limit - current footprint`, which
    /// at launch -- before the pool exists -- is effectively the whole budget.
    /// Zero means no limit is in force; we report that as 0 (unknown) and never
    /// as "unlimited", because sizing a pool off an absent limit is exactly how
    /// a process gets killed.
    static var availableMemoryBytes: UInt64 {
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : 0
    }

    // MARK: - CPU

    /// Performance-core and efficiency-core counts. Both are 0 on a host that
    /// does not publish perf levels (older iOS, the simulator).
    static let performanceCores: Int = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
    static let efficiencyCores: Int = sysctlInt("hw.perflevel1.physicalcpu") ?? 0

    // MARK: - JIT pool sizing

    /// The configuration the development device proved out: a 896MB pool inside
    /// a 4096MB budget (ml421-423 -- both larger and the same size were tried
    /// against a real workload, and 1024 was killed by jetsam twice). Both
    /// halves matter, which is why the policy below is the ratio between them.
    private static let provenPoolMB = 896
    private static let provenBudgetMB = 4096

    /// Ceiling on what we will hand out on our own. The translation-cache
    /// benefit of a larger pool flattens well before this, and past it we would
    /// be risking a jetsam kill (ml422) to buy nothing measurable.
    private static let maxAutoPoolMB = 1792

    /// Smallest pool worth allocating. Matches the low end of the
    /// `madeira-pool.txt` override, and is below the proven value on purpose:
    /// a device that reports less budget than the A15 keeps what is known to
    /// work rather than trusting the measurement.
    private static let minPoolMB = 896

    /// Pool size in MB for this device.
    ///
    /// Scales the proven configuration by this device's real budget over the
    /// development device's, so more memory buys a proportionally larger
    /// translation cache instead of the A15's. Clamped to
    /// [`minPoolMB`, `maxAutoPoolMB`] and rounded to 32MB steps.
    ///
    /// The result is deliberately conservative: at the proven budget it returns
    /// exactly 896, and because the fixed non-pool cost of a run (~2.9GB of
    /// Wine, CEF and the game, observed as the ml420 peak) does not grow with
    /// the device, every larger budget lands *further* from its ceiling than
    /// the A15 does -- so the bigger the device, the more slack it keeps.
    static func recommendedPoolMB() -> Int {
        let budgetMB = Int(availableMemoryBytes / (1024 * 1024))
        guard budgetMB > 0 else { return provenPoolMB }

        let scaled = budgetMB * provenPoolMB / provenBudgetMB
        let clamped = min(max(scaled, minPoolMB), maxAutoPoolMB)
        return clamped / 32 * 32
    }

    // MARK: - Display

    /// Parse `WIDTHxHEIGHT`, case-insensitively, tolerating whitespace around
    /// either number. Returns nil outside the bounds below, so a stray file
    /// cannot request a desktop size the guest will not accept.
    static func parseDesktopResolution(_ text: String) -> (w: Int, h: Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              w >= 320, w <= 4096, h >= 240, h <= 4096
        else {
            return nil
        }
        return (w, h)
    }

    /// Desktop resolution, defaulting to `fallback` when
    /// `Documents/madeira-resolution.txt` is absent or malformed.
    ///
    /// Both desktops the app hardcodes (1024x768 for the Steam shell, 960x540
    /// for services) predate every non-A15 device, and pixel work is the one
    /// cost that does not improve with a faster CPU. This is an override, not
    /// an auto-selection: the hardcoded sizes are load-bearing for window
    /// fitting and cannot be validated here, so the default is left alone.
    static func desktopResolution(fallback: (w: Int, h: Int)) -> (w: Int, h: Int) {
        guard let txt = documentsFile("madeira-resolution.txt"),
              let parsed = parseDesktopResolution(txt)
        else {
            return fallback
        }
        return parsed
    }

    // MARK: - Config passthrough

    /// Parse a `madeira-fex.txt` body into `FEX_`-prefixed environment pairs.
    ///
    /// Entries are separated by newlines or commas, so whitespace *around* `=`
    /// is tolerated; a line with no `=` at all is treated as a comment and
    /// skipped quietly. An entry that names a key but carries no usable value
    /// -- empty, or containing whitespace, which no FEX value does -- is
    /// returned in `rejected` rather than applied. It is returned rather than
    /// dropped because a wrong value here does not fail loudly: it silently
    /// produces a bad run, which is how "TSOENABLED = 0" and
    /// "TSOENABLED=0 MULTIBLOCK=1" both used to be accepted as one bogus pair.
    static func fexConfigEntries(from text: String)
        -> (applied: [(key: String, value: String)], rejected: [String]) {
        var applied: [(key: String, value: String)] = []
        var rejected: [String] = []

        for entry in text.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let parts = entry.split(separator: "=", maxSplits: 1,
                                    omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty,
                  !value.contains(where: { $0.isWhitespace }) else {
                rejected.append(entry.trimmingCharacters(in: .whitespaces))
                continue
            }
            applied.append((key: "FEX_" + key, value: value))
        }
        return (applied, rejected)
    }

    /// Does a `madeira-dxmt.txt` body ask for MetalFX upscaling?
    ///
    /// DXMT gates its MetalFX spatial scaler on the `DXMT_METALFX_SPATIAL_SWAPCHAIN`
    /// environment variable and reads the *factor* from `DXMT_CONFIG`, so the
    /// documented option is inert on its own: a user who writes
    /// `d3d11.metalSpatialUpscaleFactor=1.5` into the file gets nothing, silently,
    /// because the two halves arrive through different channels. The launch
    /// sequence asks this function and exports the variable to match, which makes
    /// the file channel whole and the Settings toggle possible.
    ///
    /// True only for a value above 1.0: DXMT clamps the factor with
    /// `max(factor, 1.0)`, so `=1` means "no upscale" and arming the variable for
    /// it would take the scaler path to do a 1:1 blit and nothing else.
    ///
    /// The split accepts both separators because it is called with either form:
    /// the raw file body, which is one option per line, or the folded inline
    /// form from `dxmtConfigInline`, which is what actually reaches DXMT (it
    /// splits on `;`). A comment line cannot match either way, since DXMT's
    /// config grammar has no comments and the leading `#` is not part of the key.
    static func dxmtConfigArmsMetalFX(_ text: String) -> Bool {
        for entry in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let parts = entry.split(separator: "=", maxSplits: 1,
                                    omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "d3d11.metalSpatialUpscaleFactor" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let factor = Double(value), factor > 1.0 { return true }
        }
        return false
    }

    /// Fold a `madeira-dxmt.txt` body into the single line DXMT expects in
    /// `DXMT_CONFIG`.
    ///
    /// The file is written one option per line, which is what a person reading
    /// it in the Files app needs, but DXMT's inline form is not line-based: it
    /// splits the variable on `;` and its parser takes one `key=value` per
    /// chunk, ending the value at the first whitespace. Handed the file
    /// verbatim, the first line is applied and every line after it is discarded
    /// without a word -- so the moment a second option was added to this file,
    /// it would silently do nothing. Joining on `;` is the whole translation.
    static func dxmtConfigInline(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ";")
    }

    // MARK: - Renderer caches

    /// Where DXMT keeps its compiled shaders, and why it is not where it
    /// defaults to.
    ///
    /// DXMT compiles every shader twice: DXBC to AIR through its own
    /// LLVM-based translator, then AIR to a Metal library. Both halves are
    /// expensive, and both are cached keyed by the shader's SHA-1 -- but the
    /// cache's default location is a path relative to
    /// `_CS_DARWIN_USER_CACHE_DIR`, i.e. `Library/Caches`, which iOS is free to
    /// empty whenever the device is short of storage and never restores. A
    /// title with a few thousand shaders pays for that in load time, and again
    /// as a multi-second hitch the first time each effect appears on screen.
    ///
    /// Application Support is the correct home for data that is regenerable but
    /// must persist: iOS does not purge it. It *is* backed up, and a
    /// compiled-shader database can reach hundreds of megabytes, so the
    /// directory is excluded from backup explicitly.
    ///
    /// DXMT treats a path beginning with `/` as an absolute directory and
    /// appends `shaders_<version>.db` to it itself, which is why this hands back
    /// a directory rather than a file.
    enum DXMTShaderCache {
        static let directoryName = "DXMT"
        static let pathVariable = "DXMT_SHADER_CACHE_PATH"

        /// The directory, whether or not it exists yet. Nil only when the
        /// container has no Application Support directory to point at.
        static func directoryURL() -> URL? {
            FileManager.default.urls(for: .applicationSupportDirectory,
                                     in: .userDomainMask).first?
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        /// Create the directory and return its absolute path for the
        /// environment, or nil if it could not be prepared. A nil answer means
        /// the caller leaves the variable unset, so DXMT falls back to its own
        /// default instead of being pointed at a directory that is not there --
        /// which would disable the cache entirely rather than relocate it.
        static func preparedPath() -> String? {
            guard let url = directoryURL() else { return nil }
            do {
                try FileManager.default.createDirectory(at: url,
                                                        withIntermediateDirectories: true)
            } catch {
                return nil
            }
            // Excluded from backup: the cache is regenerated from the game's own
            // shaders, and the directory survives by design, so it would
            // otherwise be copied out of the device and grow with use.
            //
            // Deliberately not behind `#if canImport(Darwin)`. This file is
            // compiled off-device by the gate on Linux as well, so an
            // unconditional call is the only form that gets type-checked here;
            // a Darwin-only branch is precisely where a wrong API hides until
            // the IPA workflow fails.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var scoped = url
            try? scoped.setResourceValues(values)
            return url.path
        }

        /// SQLite's file header. Its presence is the whole test below.
        private static let sqliteMagic = Data("SQLite format 3\0".utf8)

        /// Delete any shader database in `directory` that is not a readable
        /// SQLite file, and return the names removed.
        ///
        /// DXMT opens the database read-only for lookups and treats a failure to
        /// open as "no cache": every shader then misses and is recompiled. That
        /// is the right failure mode, but it is not a self-healing one -- the
        /// bad file is simply ignored forever. In the default location that
        /// matters little, because iOS eventually empties Library/Caches and the
        /// next launch starts clean. A directory that survives by design has no
        /// such reset, so a database truncated by a jetsam kill mid-write (the
        /// normal way this app dies, per the JIT-pool notes) would silently cost
        /// a recompile of every shader on every launch from then on.
        ///
        /// A header check is enough to catch exactly that case: a partial write
        /// leaves either nothing or a short/invalid header, and no valid SQLite
        /// file starts with anything else. Anything unreadable is deleted, which
        /// is safe because every byte in this directory is derived from the
        /// game's own shaders and can be rebuilt.
        @discardableResult
        static func discardUnreadableDatabases(in directory: URL) -> [String] {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil)
            else { return [] }
            var discarded: [String] = []
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasPrefix("shaders_"), name.hasSuffix(".db") else { continue }
                let header = try? FileHandle(forReadingFrom: entry)
                let magic = header.map { handle -> Data in
                    defer { try? handle.close() }
                    return (try? handle.read(upToCount: sqliteMagic.count)) ?? Data()
                }
                if magic != sqliteMagic {
                    // DXMT runs the database in WAL mode, so the file is only
                    // part of it: a fresh database left next to a stale write-ahead
                    // log is how this ends up failing again on the next launch.
                    // The -lock file is a plain flock target and can stay.
                    for suffix in ["", "-wal", "-shm"] {
                        try? fm.removeItem(at: directory.appendingPathComponent(name + suffix))
                    }
                    discarded.append(name)
                }
            }
            return discarded.sorted()
        }
    }

    // MARK: - Reporting

    /// One-line device summary. A bug report that includes this says which
    /// device produced it without a second round-trip, which matters because
    /// every constant above was wrong in exactly that way.
    static func summary() -> String {
        let ramGB = Double(physicalMemoryBytes) / (1024 * 1024 * 1024)
        let budgetBytes = availableMemoryBytes
        let budget = budgetBytes > 0
            ? "\(budgetBytes / (1024 * 1024))MB"
            : "unlimited"
        let cores = (performanceCores > 0 || efficiencyCores > 0)
            ? "\(performanceCores)P+\(efficiencyCores)E"
            : "cores unknown"
        return "\(machine) (\(model)) · \(String(format: "%.0f", ramGB))GB RAM · "
            + "jetsam budget \(budget) · \(cores) · pool \(recommendedPoolMB())MB"
    }
}

// MARK: - Helpers

/// Read a string sysctl by name, or nil if it does not exist on this host.
private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

/// Read a 32-bit integer sysctl by name, or nil if it does not exist.
private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

/// Read a file from the app's Documents directory, trimmed. The
/// `madeira-*.txt` files are this project's established no-rebuild override
/// channel; see the launch sequence in ContentView for the others. Not private:
/// the launch sequence reads several of them.
func documentsFile(_ name: String) -> String? {
    guard let dir = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first,
          let text = try? String(contentsOf: dir.appendingPathComponent(name),
                                 encoding: .utf8)
    else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
