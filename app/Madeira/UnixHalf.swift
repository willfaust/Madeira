import Foundation

/// The Wine unix half, loaded from a `.wcp` component instead of being linked in.
///
/// FEX (`libarm64ecfex.dll`) and the Wine PE half (`ntdll.dll`, `kernel32.dll`, ...) are
/// PE images and already arrive as components, so a change to either is a package install.
/// The unix half is Mach-O — `libntdll_unix`, `libwineserver`, `libwin32u_unix` — and in the
/// stock layout it is a static archive in the IPA, which is why every change to it has cost
/// an app rebuild. It is also the half FH6 work keeps touching (`virtual_ios.c`,
/// `signal_arm64_ios.c`, `request_ios.c`).
///
/// What makes a swap coherent is that the half is reached through a function-pointer table
/// the PE ntdll owns (`__wine_unixlib_handle`), and that table is installed by the half's own
/// `load_ntdll_functions` while `__wine_main` bootstraps. Two consequences, both measured:
///
///   * Installing a table earlier — from app `init()`, before Wine starts — cannot work.
///     `load_ntdll_functions` runs later and overwrites it. So this does not try to; it
///     prefers the loaded half's `__wine_main`, and that half installs its own table at the
///     normal point. One half runs, one table exists.
///   * Mixing halves would be incoherent, because the half holds its own state (server
///     pointers, registry handles, the WoW64 main-image flag). That is why `ios_main_image_i386`
///     is written through this type as well: writing the archive's copy while the dylib runs
///     would set a variable the running half never reads.
///
/// Signing is not optional and not an entitlement question. Measured on device (build 14):
///
///   | signing                | dlopen result              |
///   | unsigned               | "missing code signature"   |
///   | ad-hoc (`ldid -S`)     | "code signature invalid"   |
///   | Apple Development      | loads                      |
///
/// LiveContainer re-signs the guest bundle with this project's own team (4CDWTGR84Z), so a
/// library signed with the same development identity passes validation. Ad-hoc has no team.
/// The entitlements plist never reaches the device — the installed guest binary is
/// `flags=0x0(none)`, so `disable-library-validation` is not part of the answer.
///
/// When no component is installed, the linked archive runs and every function below forwards
/// to it, so a fresh install with no packages behaves exactly like stock.
enum UnixHalf {
    /// Name of the library a component provides. Kept in sync with `build/ntdll-unix/build-dylib.sh`.
    static let libraryName = "libntdll_unix.dylib"

    /// Entry points the dylib exports. They are accessors rather than Wine's own symbols
    /// because the half is compiled with `-fvisibility=hidden`; `unixhalf_entry.c` is the
    /// single default-visible object and forwards to the hidden ones.
    private static let mainSymbol = "madeira_unix_half_main"
    private static let logSetFileSymbol = "madeira_unix_half_log_set_file"
    private static let mainI386Symbol = "madeira_unix_half_main_i386_addr"
    /// Optional: a component built before this existed has no child-table reader, and the
    /// caller then falls back to the linked archive's copy as before.
    private static let liveGameChildrenSymbol = "madeira_unix_half_live_game_children"

    /// Optional wineserver half bundled inside `libntdll_unix.dylib` alongside `ntdll_unix`
    /// and `win32u_unix`. When all 8 symbols are present, `WineServerBridge.m` and
    /// `WineProcessBridge.m` run the wineserver from this image so `madsync`,
    /// `madeira_sync_cells`, `ios_srv_direct_call`, `ios_wineserver_ring`, and server state
    /// live in one image with zero split-brain. Older components fall back to `libwineserver.a`.
    private static let wsMainSymbol = "madeira_unix_half_wineserver_main"
    private static let wsLogSetFileSymbol = "madeira_unix_half_wineserver_log_set_file"
    private static let wsSetNlsDirSymbol = "madeira_unix_half_wineserver_set_nls_dir"
    private static let wsInjectClientFdSymbol = "madeira_unix_half_wineserver_inject_client_fd"
    private static let wsForegroundAddrSymbol = "madeira_unix_half_wineserver_foreground_addr"
    private static let wsReadyAddrSymbol = "madeira_unix_half_wineserver_ready_addr"
    private static let wsLogQuietAddrSymbol = "madeira_unix_half_wineserver_log_quiet_addr"
    private static let wsSetUILogCallbackSymbol = "madeira_unix_half_wineserver_set_ui_log_callback"

    /// Signature of the loaded half's `__wine_main`, as the app calls it.
    private typealias MainFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias LogSetFileFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias MainI386AddrFn = @convention(c) () -> UnsafeMutablePointer<Int32>?
    private typealias LiveGameChildrenFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int32, Double) -> Int32
    private typealias WSMainFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    private typealias WSPathFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias WSInjectFdFn = @convention(c) (Int32) -> Void
    private typealias WSIntAddrFn = @convention(c) () -> UnsafeMutablePointer<Int32>?
    typealias UILogCallbackFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias WSSetUILogCallbackFn = @convention(c) (UILogCallbackFn?) -> Void

    private static var handle: UnsafeMutableRawPointer?
    private static var mainFn: MainFn?
    private static var logSetFileFn: LogSetFileFn?
    private static var mainI386AddrFn: MainI386AddrFn?
    private static var liveGameChildrenFn: LiveGameChildrenFn?
    private static var wsMainFn: WSMainFn?
    private static var wsLogSetFileFn: WSPathFn?
    private static var wsSetNlsDirFn: WSPathFn?
    private static var wsInjectClientFdFn: WSInjectFdFn?
    private static var wsForegroundAddrFn: WSIntAddrFn?
    private static var wsReadyAddrFn: WSIntAddrFn?
    private static var wsLogQuietAddrFn: WSIntAddrFn?
    private static var wsSetUILogCallbackFn: WSSetUILogCallbackFn?

    /// Whether a component's half is in use. When false, the linked archive is.
    static private(set) var componentLoaded = false
    /// Whether the loaded component also carries the bundled wineserver half.
    static private(set) var wineserverLoaded = false

    /// Directory holding the enabled native component's files, if one provides this library.
    ///
    /// This reads `state.json`, the same list `WineProcessBridge` applies at session start, so
    /// "enabled" and the component kind mean the same thing here as everywhere else. Scanning
    /// for the file directly would load a component the user had switched off, or one of two
    /// copies left behind by an earlier install.
    static func componentDirectory(providing filename: String = libraryName) -> URL? {
        guard !filename.isEmpty, !filename.contains("/"), !filename.contains("..") else { return nil }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let components = docs.appendingPathComponent("Components", isDirectory: true)
        guard let data = try? Data(contentsOf: components.appendingPathComponent("state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = state["components"] as? [[String: Any]] else { return nil }

        // Newest enabled native component wins, so a replacement release takes effect
        // without the previous one having to be removed by hand.
        let native = entries
            .filter { ($0["kind"] as? String) == Kind.native }
            .filter { ($0["enabled"] as? Bool) == true }
            .sorted { ($0["installedAt"] as? Double ?? 0) > ($1["installedAt"] as? Double ?? 0) }

        for entry in native {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  !id.contains("/"), !id.contains("..") else { continue }
            let directory = components.appendingPathComponent(id, isDirectory: true)
            let candidate = directory.appendingPathComponent("files").appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) { return directory }
        }
        return nil
    }

    /// Full path to a `.dylib` shipped by an enabled native component (e.g.
    /// `libMoltenVK.dylib`, `libvulkan_kosmickrisp.dylib`, `libOSMesa.dylib`,
    /// `libmetalirconverter.dylib`), or `nil` when none overrides it.
    static func overrideDylibPath(named filename: String) -> String? {
        guard let directory = componentDirectory(providing: filename) else { return nil }
        return directory.appendingPathComponent("files").appendingPathComponent(filename).path
    }

    /// The component kind this loader serves, matching `WCPComponent.Kind.native`.
    private enum Kind { static let native = "native" }

    /// Load a component's unix half, if one is installed. Returns a one-line verdict for the
    /// log; safe to call when no component provides it.
    @discardableResult
    static func install() -> String {
        guard let directory = componentDirectory() else {
            return report("[unix-half] no component provides \(libraryName); using the linked archive")
        }
        let path = directory.appendingPathComponent("files")
            .appendingPathComponent(libraryName).path
        // RTLD_LOCAL: nothing else resolves against it. Its own host symbols still bind,
        // because those come from the app by name and are already loaded.
        guard let loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "dlerror returned nothing"
            return report("[unix-half] dyld REFUSED \(path): \(reason)")
        }

        guard let main = dlsym(loaded, mainSymbol),
              let logSetFile = dlsym(loaded, logSetFileSymbol),
              let mainI386Addr = dlsym(loaded, mainI386Symbol) else {
            // A library with the right name but the wrong surface is not a unix half. Refuse
            // it and keep the archive rather than starting Wine against a partial one.
            let missing = [
                dlsym(loaded, mainSymbol) == nil ? mainSymbol : nil,
                dlsym(loaded, logSetFileSymbol) == nil ? logSetFileSymbol : nil,
                dlsym(loaded, mainI386Symbol) == nil ? mainI386Symbol : nil,
            ].compactMap { $0 }
            dlclose(loaded)
            return report("[unix-half] \(path) is missing \(missing.joined(separator: ", ")); using the linked archive")
        }

        handle = loaded
        mainFn = unsafeBitCast(main, to: MainFn.self)
        logSetFileFn = unsafeBitCast(logSetFile, to: LogSetFileFn.self)
        mainI386AddrFn = unsafeBitCast(mainI386Addr, to: MainI386AddrFn.self)
        if let children = dlsym(loaded, liveGameChildrenSymbol) {
            liveGameChildrenFn = unsafeBitCast(children, to: LiveGameChildrenFn.self)
        }
        if let wsMain = dlsym(loaded, wsMainSymbol),
           let wsLogSetFile = dlsym(loaded, wsLogSetFileSymbol),
           let wsSetNlsDir = dlsym(loaded, wsSetNlsDirSymbol),
           let wsInjectFd = dlsym(loaded, wsInjectClientFdSymbol),
           let wsForegroundAddr = dlsym(loaded, wsForegroundAddrSymbol),
           let wsReadyAddr = dlsym(loaded, wsReadyAddrSymbol),
           let wsLogQuietAddr = dlsym(loaded, wsLogQuietAddrSymbol),
           let wsSetUILogCallback = dlsym(loaded, wsSetUILogCallbackSymbol) {
            wsMainFn = unsafeBitCast(wsMain, to: WSMainFn.self)
            wsLogSetFileFn = unsafeBitCast(wsLogSetFile, to: WSPathFn.self)
            wsSetNlsDirFn = unsafeBitCast(wsSetNlsDir, to: WSPathFn.self)
            wsInjectClientFdFn = unsafeBitCast(wsInjectFd, to: WSInjectFdFn.self)
            wsForegroundAddrFn = unsafeBitCast(wsForegroundAddr, to: WSIntAddrFn.self)
            wsReadyAddrFn = unsafeBitCast(wsReadyAddr, to: WSIntAddrFn.self)
            wsLogQuietAddrFn = unsafeBitCast(wsLogQuietAddr, to: WSIntAddrFn.self)
            wsSetUILogCallbackFn = unsafeBitCast(wsSetUILogCallback, to: WSSetUILogCallbackFn.self)
            wineserverLoaded = true
        }
        componentLoaded = true
        let wsNote = wineserverLoaded ? " (with bundled wineserver)" : " (wineserver fallback: linked archive)"
        return report("[unix-half] component half INSTALLED from \(path)\(wsNote)")
    }

    // MARK: - Dispatch used by the Objective-C bridge

    /// Start Wine from the loaded half. Returns false when nothing was loaded, so the caller
    /// can fall back to the linked symbol instead of calling through a null pointer.
    static func startWine(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
        guard let mainFn else { return false }
        mainFn(argc, argv)
        return true
    }

    /// Point the half's log at `path`. Returns false when the linked half should do it.
    static func setLogFile(_ path: UnsafePointer<CChar>) -> Bool {
        guard let logSetFileFn else { return false }
        logSetFileFn(path)
        return true
    }

    /// Publish the main image's machine to the half that will actually run.
    static func setMainImageI386(_ value: Int32) -> Bool {
        guard let mainI386AddrFn, let address = mainI386AddrFn() else { return false }
        address.pointee = value
        return true
    }

    /// Ask the running half which child pseudo-processes it started are still alive.
    ///
    /// The table is filled by `spawn_process`, which is unix side, so it exists in the
    /// loaded half's image. The linked archive's copy is a different array and is empty
    /// while a component runs — reading it made `MADEIRA_WAIT_CHILDREN` and the
    /// launcher-stub protection silently do nothing (a Dock session ended when
    /// `dockhost.exe` exited even though the game it had started was still loading).
    ///
    /// Returns `nil` when no component is loaded or it predates this accessor: the caller
    /// then uses the linked symbol, which is correct when the archive is what runs.
    static func liveGameChildren(_ buffer: UnsafeMutablePointer<CChar>?,
                                 _ length: Int32, _ maxAge: Double) -> Int32? {
        guard let liveGameChildrenFn else { return nil }
        return liveGameChildrenFn(buffer, length, maxAge)
    }

    /// Resolve an exported symbol from the loaded unix-half dylib, or `nil` when running
    /// the linked archive (or if an older component does not export the symbol).
    static func symbol(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    // MARK: - Bundled wineserver dispatch

    static func startWineserver(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                outRet: UnsafeMutablePointer<Int32>?) -> Bool {
        guard let wsMainFn else { return false }
        let ret = wsMainFn(argc, argv)
        outRet?.pointee = ret
        return true
    }

    static func setWineserverLogFile(_ path: UnsafePointer<CChar>) -> Bool {
        guard let wsLogSetFileFn else { return false }
        wsLogSetFileFn(path)
        return true
    }

    static func setWineserverNlsDir(_ path: UnsafePointer<CChar>) -> Bool {
        guard let wsSetNlsDirFn else { return false }
        wsSetNlsDirFn(path)
        return true
    }

    static func injectWineserverClientFd(_ fd: Int32) -> Bool {
        guard let wsInjectClientFdFn else { return false }
        wsInjectClientFdFn(fd)
        return true
    }

    static func setWineserverForeground(_ value: Int32) -> Bool {
        guard let wsForegroundAddrFn, let addr = wsForegroundAddrFn() else { return false }
        addr.pointee = value
        return true
    }

    static func wineserverReadyAddr() -> UnsafeMutablePointer<Int32>? {
        wsReadyAddrFn?()
    }

    static func setWineserverLogQuiet(_ value: Int32) {
        ws_log_quiet = value
        if let wsLogQuietAddrFn, let addr = wsLogQuietAddrFn() {
            addr.pointee = value
        }
    }

    static func setWineserverUILogCallback(_ cb: UILogCallbackFn?) {
        wsSetUILogCallbackFn?(cb)
    }

    /// One line to both channels: the app log, which is what a session is read from, and
    /// stderr, which catches the case where the log is not writable yet at launch.
    @discardableResult
    private static func report(_ verdict: String) -> String {
        LogStore.shared.log(verdict)
        fputs("\(verdict)\n", stderr)
        return verdict
    }
}

// MARK: - C entry points
//
// The bridge is Objective-C and starts Wine on a background thread at a point this Swift
// code does not control, so the hand-off is plain C functions rather than a Swift call into
// files that cannot import Swift.

/// Resolve a component's unix half. Call once, before any Wine code runs.
@_cdecl("madeira_unix_half_prepare")
public func madeiraUnixHalfPrepare() {
    UnixHalf.install()
}

/// Run the loaded half's `__wine_main`. Returns 0 when no component is loaded, and the
/// caller must then use the linked symbol.
@_cdecl("madeira_unix_half_start")
public func madeiraUnixHalfStart(_ argc: Int32,
                                 _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    UnixHalf.startWine(argc: argc, argv: argv) ? 1 : 0
}

/// Set the loaded half's log file. Returns 0 when no component is loaded.
@_cdecl("madeira_unix_half_set_log_file")
public func madeiraUnixHalfSetLogFile(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return 0 }
    return UnixHalf.setLogFile(path) ? 1 : 0
}

/// Write the main image's machine into the loaded half. Returns 0 when no component is loaded.
@_cdecl("madeira_unix_half_set_main_i386")
public func madeiraUnixHalfSetMainI386(_ value: Int32) -> Int32 {
    UnixHalf.setMainImageI386(value) ? 1 : 0
}

/// Count the child pseudo-processes the loaded half started that are still alive, and write
/// their names into `buffer`. Returns -1 when no component is loaded (the caller then reads
/// the linked archive's table), which is why 0 is a real answer here and not "unavailable".
@_cdecl("madeira_unix_half_live_game_children")
public func madeiraUnixHalfLiveGameChildren(_ buffer: UnsafeMutablePointer<CChar>?,
                                            _ length: Int32,
                                            _ maxAge: Double) -> Int32 {
    UnixHalf.liveGameChildren(buffer, length, maxAge) ?? -1
}

/// Run the loaded half's `wineserver_main`. Returns 0 when the loaded half does not carry
/// wineserver (or no component is loaded), so the caller falls back to `libwineserver.a`.
@_cdecl("madeira_unix_half_wineserver_start")
public func madeiraUnixHalfWineserverStart(_ argc: Int32,
                                           _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                           _ outRet: UnsafeMutablePointer<Int32>?) -> Int32 {
    UnixHalf.startWineserver(argc: argc, argv: argv, outRet: outRet) ? 1 : 0
}

@_cdecl("madeira_unix_half_wineserver_set_log_file")
public func madeiraUnixHalfWineserverSetLogFile(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return 0 }
    return UnixHalf.setWineserverLogFile(path) ? 1 : 0
}

@_cdecl("madeira_unix_half_wineserver_set_nls_dir_bridge")
public func madeiraUnixHalfWineserverSetNlsDir(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return 0 }
    return UnixHalf.setWineserverNlsDir(path) ? 1 : 0
}

@_cdecl("madeira_unix_half_wineserver_inject_fd")
public func madeiraUnixHalfWineserverInjectFd(_ fd: Int32) -> Int32 {
    UnixHalf.injectWineserverClientFd(fd) ? 1 : 0
}

@_cdecl("madeira_unix_half_wineserver_set_foreground")
public func madeiraUnixHalfWineserverSetForeground(_ value: Int32) -> Int32 {
    UnixHalf.setWineserverForeground(value) ? 1 : 0
}

@_cdecl("madeira_unix_half_wineserver_ready_ptr")
public func madeiraUnixHalfWineserverReadyPtr() -> UnsafeMutablePointer<Int32>? {
    UnixHalf.wineserverReadyAddr()
}

/// Resolve an exported symbol from the loaded unix-half dylib, or NULL when running
/// against the linked archive (or if the component does not export `name`).
@_cdecl("madeira_unix_half_symbol")
public func madeiraUnixHalfSymbol(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return UnixHalf.symbol(name)
}

/// Resolve an override `.dylib` from an enabled native `.wcp` component (e.g.
/// `libmadeira_ir_unix.dylib`, `libmetalirconverter.dylib`, `libMoltenVK.dylib`).
/// Returns 1 and writes NUL-terminated path into `out` on hit, 0 otherwise.
@_cdecl("madeira_wcp_dylib_path")
public func madeiraWcpDylibPath(_ name: UnsafePointer<CChar>?,
                                _ out: UnsafeMutablePointer<CChar>?,
                                _ cap: Int32) -> Int32 {
    guard let name, let out, cap > 1 else { return 0 }
    let filename = String(cString: name)
    guard let path = UnixHalf.overrideDylibPath(named: filename) else { return 0 }
    let utf8 = Array(path.utf8)
    guard utf8.count < Int(cap) else { return 0 }
    for (i, b) in utf8.enumerated() {
        out[i] = CChar(bitPattern: b)
    }
    out[utf8.count] = 0
    return 1
}
