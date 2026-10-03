import UIKit

/// Helper to enable JIT via StikDebug/StikJIT URL scheme.
/// Opens StikDebug with Madeira's bundled script, polls for CS_DEBUGGED,
/// then allocates JIT memory and detaches the debugger.
enum StikJITHelper {

    // madeira-jit.js in Copy Bundle Resources is the only script source.

    enum RequestError: LocalizedError {
        case scriptMissing
        case invalidRequest
        case unavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .scriptMissing:
                return "Madeira's JIT script is missing from this installation. Reinstall Madeira."
            case .invalidRequest:
                return "Madeira could not create the StikDebug request."
            case .unavailable:
                return "StikDebug is not installed. Install it, or configure Built-in StikJIT."
            case .timedOut:
                return "StikDebug did not attach to Madeira within 90 seconds. Check its pairing file and LocalDevVPN, then try again."
            }
        }
    }

    /// The script in Copy Bundle Resources is the single source used by both
    /// StikDebug and Built-in StikJIT.
    static var scriptData: Data? {
        guard let url = Bundle.main.url(forResource: "madeira-jit", withExtension: "js") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Check whether StikDebug is installed. `stikdebug` is its canonical scheme;
    /// the older `stikjit` alias remains declared for compatibility.
    static var isAvailable: Bool {
        guard let url = URL(string: "stikdebug://enable-jit") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Open StikDebug with our JIT script embedded in the URL.
    /// PID targets this running process rather than asking StikDebug to launch a
    /// replacement instance by bundle ID.
    static func enableJIT(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let scriptData else {
            completion(.failure(RequestError.scriptMissing))
            return
        }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-data", value: scriptData.base64EncodedString()),
        ]
        guard let url = components.url else {
            LogStore.shared.log("Failed to build StikJIT URL", level: .error)
            completion(.failure(RequestError.invalidRequest))
            return
        }

        LogStore.shared.log("Opening StikDebug to enable JIT...")

        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                LogStore.shared.log("Failed to open StikDebug. Is it installed?", level: .error)
                completion(.failure(RequestError.unavailable))
                return
            }
            waitForDebugger(completion: completion)
        }
    }

    /// ml1235 (local, 2026-10-02) is folded in here: upstream's waitForDebugger
    /// waits for `ready` (CS_DEBUGGED and a live debugger), which is what ml1235's
    /// pollForJIT did; the flag-only poll reported success at once in the
    /// flagged-without-debugger state. `ready` reads the flag silently (below).
    /// Opening a URL only proves iOS accepted it. Readiness requires both the
    /// sticky CS_DEBUGGED flag and a live debugger that can answer Madeira's BRK.
    @discardableResult
    static func waitForDebugger(timeout: TimeInterval = 90,
                                completion: @escaping (Result<Void, Error>) -> Void) -> Timer {
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            if ready {
                timer.invalidate()
                LogStore.shared.log("JIT enabled and debugger attached.", level: .success)
                completion(.success(()))
            } else if Date() >= deadline {
                timer.invalidate()
                LogStore.shared.log(RequestError.timedOut.localizedDescription, level: .error)
                completion(.failure(RequestError.timedOut))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Allocate a JIT memory pool via BRK #0xf00d, then detach the debugger.
    /// Call this after CS_DEBUGGED is confirmed.
    /// Returns the allocated RX base address and RW mapping, or nil on failure.
    static func allocateAndDetach(poolSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        guard let result = allocatePool(poolSize: poolSize) else { return nil }
        // Don't detach yet — Wine needs the debugger to prepare PE DLL code pages.
        // Detach will happen later via detachDebugger().
        return result
    }

    /// Why the last allocatePool() returned nil, in words for the person playing
    /// (the library shows it); nil after a success.
    private(set) static var poolFailure: String?
    static let noDebuggerMessage = "JIT is switched on, but StikDebug is not attached to Madeira, so the JIT memory cannot "
        + "be set up. This happens when JIT is enabled from StikDebug's own app list. Tap Enable JIT: StikDebug then "
        + "reopens Madeira with Madeira's script, ready to play."

    /// This app run's pool exists. The debugger detaches right after the pool is
    /// made, by design, so from then on "no debugger attached" is the normal state.
    private(set) static var poolTaken = false

    // 0 treats JIT as ready whenever CS_DEBUGGED is set, as before, without asking whether a debugger is attached.
    private static let attachCheck = MadeiraConfig.flag("MADEIRA_JIT_ATTACH_CHECK")

    /// JIT can serve a launch: CS_DEBUGGED is set, and either a debugger is
    /// attached to answer the pool request or this run's pool exists already.
    /// CS_DEBUGGED alone is not enough: it stays set after a debugger leaves, which
    /// is the state StikDebug's own app list (attach, then detach) leaves behind.
    /// ml1235: the flag is read without jit_check_debugged's log line; the library
    /// polls this every 2 s for the whole app run (and waitForDebugger every 0.5 s).
    static var ready: Bool {
        guard SigningStatus.current.debugged else { return false }
        return !attachCheck || poolTaken || isDebuggerAttached()
    }

    /// CS_DEBUGGED is set but nothing can answer a pool request: JIT has to be
    /// enabled again, through Madeira, before a game can start.
    static var flaggedWithoutDebugger: Bool { SigningStatus.current.debugged && !ready }

    /// ml1234: the early pool placeholder is unmapped once per app run. A launch that
    /// fails without a debugger now leaves the app up, and a second pool request
    /// unmapped the placeholder's range again, under whatever had been mapped there
    /// since (malloc, Metal, IOSurface).
    private static var earlyPoolReleased = false

    /// Allocate a JIT memory pool via BRK #0xf00d WITHOUT detaching the debugger.
    /// The debugger stays attached so Wine can use BRK to prepare PE code pages.
    static func allocatePool(poolSize requestedPoolSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        var poolSize = requestedPoolSize      // ml1036: may shrink to fit, see the hole census below
        poolFailure = nil
        LogStore.shared.log("Allocating \(poolSize / 1024 / 1024)MB JIT pool via debugger...")

        let debuggerAttached = isDebuggerAttached()
        LogStore.shared.log("[jit-debugger] attached=\(debuggerAttached ? 1 : 0) at the pool request")
        // With no debugger attached, a JIT request fails the launch with a message; 0 lets it crash the app as before.
        // CS_DEBUGGED stays set after a debugger detaches (JIT enabled by a tool
        // that attaches and leaves, or without Madeira's script), and the pool
        // request below is a BRK only a debugger can answer: with nobody attached
        // it killed the app (EXC_BREAKPOINT in jit26_prepare_region). P_TRACED says
        // whether a debugger is attached now. The handler cannot take a BRK away
        // from an attached debugger, which sees the exception first, so a wrong
        // reading costs nothing.
        if !debuggerAttached && MadeiraConfig.flag("MADEIRA_JIT_TRAP_FALLBACK") {
            jit_arm_trap_fallback()
            LogStore.shared.log("[jit-debugger] no debugger is attached although CS_DEBUGGED is set: "
                + "an unanswered pool request now fails the launch instead of crashing the app", level: .error)
        }

        // iOS-Madeira: FEX's dispatcher emit has a position-dependent encoding
        // bug — only works when the JIT pool lands at a high enough address
        // (empirically ≥ 0x119000000, so dispatcher at +0x7ffc130 has top byte
        // 0x12). When iOS allocates 0x114-0x117xxx the dispatcher's literal-
        // pool fixups silently break and execution branches to zero memory
        // before the first compiled block runs. Pre-claim ~96MB of low address
        // space to push the next ANYWHERE allocation up.
        //
        // We keep these allocations alive for the lifetime of the process —
        // freeing them could let iOS reuse them and cause aliasing issues.
        var pinChunks: [vm_address_t] = []
        let chunkSize = 16 * 1024 * 1024  // 16 MB per chunk
        // Pin until the allocation frontier crosses the mode-A threshold
        // (0x119000000) instead of a fixed 96MB. A fixed count loses the
        // ASLR lottery whenever the base slide is low (observed 2026-07-03:
        // 6 chunks ended at 0x118790000, pool landed 8.4MB short of the
        // threshold and the run fast-failed). vm_allocate is zero-fill
        // reserve-only, so extra chunks don't add resident footprint.
        // The BAD POOL check below stays as the safety net for non-
        // sequential placements.
        let pinTarget: vm_address_t = 0x119000000
        let maxChunks = 32                 // safety cap (512 MB of reservation)
        for i in 0..<maxChunks {
            var addr: vm_address_t = 0
            let kr = vm_allocate(mach_task_self_, &addr, vm_size_t(chunkSize), VM_FLAGS_ANYWHERE)
            if kr == KERN_SUCCESS {
                // ml1036: if the frontier is ALREADY past the threshold this chunk
                // pins nothing useful and costs 16MB of the scarcest VA we have
                // (the low gap must hold the pool AND the 0x140000000 window).
                if addr >= pinTarget {
                    vm_deallocate(mach_task_self_, addr, vm_size_t(chunkSize))
                    LogStore.shared.log(String(format: "JIT-pool frontier already at 0x%lx — no pin needed", Int(addr)))
                    break
                }
                pinChunks.append(addr)
                LogStore.shared.log(String(format: "JIT-pool pin chunk %d at 0x%lx (16MB)", i, Int(addr)))
                if addr + vm_address_t(chunkSize) >= pinTarget { break }
            } else {
                LogStore.shared.log("JIT-pool pin chunk \(i) FAILED kr=\(kr)", level: .error)
                break
            }
        }

        // Ask debugger to allocate RX pages (x0=0 triggers _M allocation).
        // With pin chunks claimed, this should land at a higher address.
        //
        // Two placement constraints (violating either bricks the session):
        // - LOW BOUND: FEX has a position-dependent emit bug below
        //   0x119000000 (mode A: dispatcher branches to zero memory before
        //   block 0 runs; higher-address mode B is runtime-patched in
        //   signal_arm64_ios.c init_syscall_frame).
        // - GUEST WINDOW (ml78, 2026-07-13): with the 896MB pool the kernel
        //   often places the region at 0x7000000000 — inside the guest
        //   x86-64 64GB window [0x70,0x80)G where Wine packs PE images and
        //   the fault handlers classify PCs as guest addresses. Executing
        //   pool code there hangs the first pool call silently (black
        //   screen / wallpaper-only desktop).
        // Reject bad placements and re-roll: a bad region is freed when the
        // kernel allows, otherwise kept alive as a pin.
        // ⚠️ ml596: the old claim that the next pick "must land elsewhere" is FALSE.
        // ml595 freed and re-requested three times and the kernel handed back the
        // SAME 0x7000000000 hole each time, so the retry loop is not a strategy —
        // it is three identical attempts. Failure is therefore deterministic within
        // a launch and the caller must abort rather than run without a pool. A real
        // fix needs explicit placement (hinted allocation / reserve-and-carve),
        // not a re-roll; simply pinning the bad region to force a different address
        // costs another 896MB against the 4096MB jetsam ceiling.
        // ml1034: HOLD THE EXECUTABLE WINDOW BEFORE ALLOCATING RX.
        //
        // ml977 reserved [0x140000000,0x150000000) only AFTER the RX pool was
        // allocated, so on the iPhone 18 Pro the pool got there first and the
        // reservation could only report the loss:
        //
        //   ml977: could NOT reserve the executable window (kr=3)
        //   ml977: RX pool overlaps the executable window -- RX placement, not RW,
        //          would need changing
        //   ml977: RX=[0x122000000,0x142000000)          <- contains 0x140000000
        //   ml985: preferred base 0x140000000+0x70000 REFUSED status=0xc0000018
        //
        // RDR2.exe has BASERELOC rva=0 size=0, so it CANNOT be relocated: moved
        // to 0x146a90000, every absolute pointer in it stayed behind. Its TLS
        // AddressOfCallBacks still read 0x1432ba978 (relocated it would be
        // 0x14954a978), call_tls_callbacks walked that stale array and called
        // garbage:
        //
        //   CompileBlock: REFUSING low/invalid RIP=0x170
        //   [redeliv] 2000 identical redeliveries pc=0x0 -- unrecoverable host
        //             fault misdelivered to guest -> terminating
        //
        // The diagnosis was already in our own log; only the ORDER was wrong. So
        // reserve first: the debugger's allocator cannot hand back a range that
        // is already mapped, which removes the collision without naming an RX
        // address ourselves. Failure is still never fatal -- we log and continue
        // exactly as before, and MADEIRA_NO_EXE_WINDOW=1 skips it.
        let exeWinBase: vm_address_t = 0x140000000
        // ml1037: 128MB, not 256MB. The census on the iPhone 18 Pro read
        //   0x12067c000+505MB | [window 256MB] | 0x150000000+500MB | 0x16fa24000+261MB
        // i.e. the window itself was what split the low gap into pieces too small
        // for the pool, and the 496MB pool that did fit ran out mid-load
        // ("EXEC ALLOC FAILED ... JIT pool exhausted", exit 0xc000012d: 406MB of
        // image copies + 64MB of live code buffers). Halving the window gives the
        // hole above it ~628MB contiguous. The largest fixed-base image we ship
        // against ends at +117MB; ntdll hands the window to the first fixed map
        // of >=64MB that fits, and reads the size from WINE_IOS_EXE_WINDOW.
        let exeWinSize: vm_address_t = 0x8000000           // 128MB
        func overlapsExeWindow(_ base: vm_address_t, _ len: vm_address_t) -> Bool {
            return base < exeWinBase + exeWinSize && base + len > exeWinBase
        }
        let skipWindow = (ProcessInfo.processInfo.environment["MADEIRA_NO_EXE_WINDOW"].map { $0 != "0" } ?? false)
        var windowHeld = false
        if !skipWindow && madeira_early_window_base == UInt(exeWinBase) && madeira_early_window_size == UInt(exeWinSize) {
            // ml1040: already held since image load (JITAllocator.c constructor).
            windowHeld = true
            setenv("WINE_IOS_EXE_WINDOW", String(format: "%lx:%lx", Int(exeWinBase), Int(exeWinSize)), 1)
            LogStore.shared.log("ml1040: executable window [0x140000000,+128MB) held since image load", level: .success)
        } else if !skipWindow {
            var winAddr: vm_address_t = exeWinBase
            let krWin = vm_allocate(mach_task_self_, &winAddr, vm_size_t(exeWinSize), 0 /* VM_FLAGS_FIXED */)
            if krWin == KERN_SUCCESS && winAddr == exeWinBase {
                windowHeld = true
                setenv("WINE_IOS_EXE_WINDOW", String(format: "%lx:%lx", Int(exeWinBase), Int(exeWinSize)), 1)
                LogStore.shared.log("ml1034: reserved executable window [0x140000000,0x150000000) BEFORE "
                    + "RX allocation - a fixed-base main image can now load where it must; "
                    + "ntdll releases it on demand", level: .success)
            } else {
                if krWin == KERN_SUCCESS { vm_deallocate(mach_task_self_, winAddr, vm_size_t(exeWinSize)) }
                LogStore.shared.log("ml1034: could NOT reserve the executable window (kr=\(krWin)) BEFORE "
                    + "RX - something else already holds 0x140000000; a non-relocatable image will be "
                    + "displaced and its absolute pointers will be stale", level: .error)
                // ml1097: NAME the occupant. The ml1095 build hit this on every launch
                // (0x140000000+88MB taken before the image-load constructor ran)
                // and nothing said what it was.
                var pa = vm_address_t(exeWinBase)
                var ps: vm_size_t = 0
                var pinfo = vm_region_basic_info_data_64_t()
                var pcnt = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
                var pobj: mach_port_t = 0
                let pkr = withUnsafeMutablePointer(to: &pinfo) {
                    $0.withMemoryRebound(to: Int32.self, capacity: Int(pcnt)) {
                        vm_region_64(mach_task_self_, &pa, &ps, VM_REGION_BASIC_INFO_64, $0, &pcnt, &pobj)
                    }
                }
                var depth: natural_t = 0
                var sinfo = vm_region_submap_info_data_64_t()
                var scnt = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<Int32>.size)
                var sa = vm_address_t(exeWinBase)
                var ss: vm_size_t = 0
                _ = withUnsafeMutablePointer(to: &sinfo) {
                    $0.withMemoryRebound(to: Int32.self, capacity: Int(scnt)) {
                        vm_region_recurse_64(mach_task_self_, &sa, &ss, &depth, $0, &scnt)
                    }
                }
                var dl = Dl_info()
                let named = dladdr(UnsafeRawPointer(bitPattern: UInt(exeWinBase)), &dl) != 0
                let image = named && dl.dli_fname != nil ? String(cString: dl.dli_fname) : "(no dyld image)"
                LogStore.shared.log(String(format: "ml1097: occupant of 0x140000000: region 0x%lx+%luMB prot=%d/%d (kr=%d) user_tag=%u share=%d resident=%u pages; %@",
                                           Int(pa), Int(ps >> 20), pinfo.protection, pinfo.max_protection, pkr,
                                           sinfo.user_tag, Int(sinfo.share_mode), sinfo.pages_resident, image), level: .error)
            }
        }

        let goodLow = 0x119000000
        let guestLo = 0x7000000000
        let guestHi = 0x8000000000

        // ml1036: HOLE CENSUS, then size the pool to what can actually be placed.
        //
        // ml1034 held the window first, and the very next launch could not place
        // the pool at all: three identical "BAD POOL placement 0x7000000000"
        // and an abort. The debugger's allocator is first-fit with no address
        // hint, and on this phone the usable low gap is small -- from the slide-
        // dependent frontier (0x11ed.. to 0x1258.. observed) up to the window.
        // With the frontier at 0x1223d0000 that is 460MB: a 512MB pool does not
        // fit, so the kernel falls through to the guest window, which we refuse.
        // Before ml1034 the same launch would have "worked" by swallowing
        // 0x140000000 and then killing any fixed-base game -- so the choice is
        // between a smaller pool and a run that cannot survive. Measure the
        // holes, log them, and take the largest pool that fits.
        // ml1040: the run directly above the window has been held since image load
        // so that nothing of ours could land in it. Release it now -- the very
        // next allocation of this size is the debugger's.
        var plugs: [(vm_address_t, vm_size_t)] = []
        let earlyPoolBase = vm_address_t(madeira_early_pool_base)
        let earlyPoolSize = vm_address_t(madeira_early_pool_size)
        if earlyPoolBase != 0 && earlyPoolReleased {
            LogStore.shared.log(String(format: "ml1234: the early pool placeholder 0x%lx+%luMB was released by an earlier pool request in this run; not unmapped again",
                                       Int(earlyPoolBase), Int(earlyPoolSize >> 20)))
        } else if earlyPoolBase != 0 {
            vm_deallocate(mach_task_self_, earlyPoolBase, vm_size_t(earlyPoolSize))
            earlyPoolReleased = true
            LogStore.shared.log(String(format: "ml1040: released the early pool placeholder 0x%lx+%luMB for the debugger",
                                       Int(earlyPoolBase), Int(earlyPoolSize >> 20)))
        } else {
            LogStore.shared.log("ml1040: no early pool placeholder was obtained — placement is left to chance", level: .error)
            // ml1135: what was already mapped above the window at image load (user_tag
            // is the VM_MEMORY_* allocation tag; 0 = untagged anonymous memory).
            if madeira_early_intruder_base != 0 {
                LogStore.shared.log(String(format: "ml1135: the placeholder was blocked at image load by a mapping at 0x%lx+%luMB (VM tag %u, prot %u) -- this is what shrinks the JIT pool",
                                           Int(madeira_early_intruder_base), Int(madeira_early_intruder_size >> 20),
                                           madeira_early_intruder_tag, madeira_early_intruder_prot), level: .error)
            }
        }
        do {
            var holes: [(base: vm_address_t, size: vm_address_t)] = []
            var addr = vm_address_t(goodLow)
            var prevEnd = vm_address_t(goodLow)
            while addr < vm_address_t(guestLo) {
                var rsize: vm_size_t = 0
                var info = vm_region_basic_info_data_64_t()
                var cnt = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
                var obj: mach_port_t = 0
                let kr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: Int32.self, capacity: Int(cnt)) {
                        vm_region_64(mach_task_self_, &addr, &rsize, VM_REGION_BASIC_INFO_64, $0, &cnt, &obj)
                    }
                }
                if kr != KERN_SUCCESS { break }
                let start = min(addr, vm_address_t(guestLo))
                if start > prevEnd && start - prevEnd >= 64 << 20 { holes.append((prevEnd, start - prevEnd)) }
                prevEnd = max(prevEnd, addr + vm_address_t(rsize))
                addr = prevEnd
            }
            let desc = holes.map { String(format: "0x%lx+%luMB", Int($0.base), Int($0.size >> 20)) }.joined(separator: " ")
            LogStore.shared.log("ml1036: free holes >=64MB in [0x119000000,0x7000000000) with the window held: "
                + (desc.isEmpty ? "NONE" : desc))
            let largest = holes.map { $0.size }.max() ?? 0
            if largest < vm_address_t(poolSize) {
                let fit = Int(largest) & ~((16 << 20) - 1)
                if fit >= 256 << 20 {
                    LogStore.shared.log("ml1036: no hole fits a \(poolSize >> 20)MB pool — SHRINKING to \(fit >> 20)MB "
                        + "(the alternative is a pool in the guest window or on top of 0x140000000, "
                        + "both of which are fatal)", level: .error)
                    poolSize = fit
                    // ml1135: ~400MB of the pool is PE image copies, so below ~500MB FEX's
                    // code cache is starved and rolls over every few seconds in game
                    // (ph-rdr90: 432MB pool, 52 rollovers, a ~1 s freeze each).
                    if fit < 500 << 20 {
                        LogStore.shared.log("⚠️ SMALL JIT POOL (\(fit >> 20)MB) on this launch: expect ~1 s freezes in heavy games. "
                            + "Quit and relaunch the app for a smooth session.", level: .error)
                    }
                } else {
                    LogStore.shared.log("ml1036: largest hole is only \(largest >> 20)MB — cannot place a usable pool",
                                        level: .error)
                }
            }
            // ml1040: the debugger allocates first-fit. If a LOWER hole also fits
            // the final pool size it would win and strand the pool below the
            // window again, so plug those for the duration of the request.
            // ml1097: a hole that CONTAINS or ADJOINS the released placeholder is the
            // pool's own landing site, never a "lower hole" -- when the window was not
            // held, the placeholder's run merged with the free space below it and
            // the old test plugged the only hole that fit (every launch of ml1095
            // ended in the guest window). Plug only holes ending below the placeholder.
            if earlyPoolBase != 0 && windowHeld {
                for h in holes where h.base + h.size <= earlyPoolBase && h.size >= vm_address_t(poolSize) {
                    var a = h.base
                    if vm_allocate(mach_task_self_, &a, vm_size_t(h.size), 0 /* FIXED */) == KERN_SUCCESS && a == h.base {
                        plugs.append((a, vm_size_t(h.size)))
                        LogStore.shared.log(String(format: "ml1040: plugged lower hole 0x%lx+%luMB so first-fit lands above the window",
                                                   Int(h.base), Int(h.size >> 20)))
                    } else if a != h.base { vm_deallocate(mach_task_self_, a, vm_size_t(h.size)) }
                }
            }
        }

        var rxPtrOpt: UnsafeMutableRawPointer? = nil
        var requestUnanswered = false
        for attempt in 0..<3 {
            guard let p = jit26_prepare_region(nil, poolSize), p != UnsafeMutableRawPointer(bitPattern: 0) else {
                LogStore.shared.log("Debugger failed to allocate RX memory (attempt \(attempt))", level: .error)
                requestUnanswered = true
                break
            }
            let a = Int(bitPattern: p)
            let inGuestWindow = a + poolSize > guestLo && a < guestHi
            // ml1034: a pool covering 0x140000000 displaces a non-relocatable
            // main image, which is fatal later and unrecoverable.
            let hitsExeWindow = overlapsExeWindow(vm_address_t(a), vm_address_t(poolSize))
            if a >= goodLow && !inGuestWindow && !hitsExeWindow {
                rxPtrOpt = p
                break
            }
            LogStore.shared.log(String(format: "BAD POOL placement 0x%lx (%@) — re-rolling (attempt %d)",
                                       a,
                                       a < goodLow ? "mode A low"
                                         : (hitsExeWindow ? "swallows the 0x140000000 executable window"
                                                          : "guest 64G window"),
                                       attempt), level: .error)
            let dkr = vm_deallocate(mach_task_self_, vm_address_t(a), vm_size_t(poolSize))
            LogStore.shared.log(dkr == KERN_SUCCESS
                ? "  bad region freed"
                : "  bad region kept as pin (vm_deallocate kr=\(dkr))")
        }
        // ml1040: the plugs existed only to steer first-fit; give the VA back.
        for (a, sz) in plugs { vm_deallocate(mach_task_self_, a, sz) }
        guard let rxPtr = rxPtrOpt else {
            if requestUnanswered && !debuggerAttached {
                // Nothing answered the BRK: there is no pool and no placement to
                // re-roll, so the app stays up and says what to do.
                poolFailure = noDebuggerMessage
                LogStore.shared.log("[jit-debugger] the pool request was not answered: no debugger is attached. "
                    + "Enable JIT with Madeira's Enable JIT button, so that StikDebug attaches with Madeira's "
                    + "script and stays attached until the game starts.", level: .error)
                return nil
            }
            poolFailure = requestUnanswered
                ? "The debugger could not allocate the JIT memory. Restart Madeira, enable JIT and try again."
                : "The JIT memory landed at an address Madeira cannot use. Restart Madeira, enable JIT and try again."
            LogStore.shared.log("BAD POOL: no valid placement after retries. Killing in 10s — please relaunch.", level: .error)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10) {
                LogStore.shared.log("BAD POOL — exiting now. Relaunch the app.", level: .error)
                exit(0)
            }
            return nil
        }
        let rxAddr = Int(bitPattern: rxPtr)
        LogStore.shared.log("RX pool at \(String(format: "%p", rxAddr))")

        // Create RW mapping via vm_remap
        var rwAddr: vm_address_t = 0
        var curProt: vm_prot_t = 0
        var maxProt: vm_prot_t = 0

        // task #35: place the RW alias BELOW the 64GB carveout floor.
        // With VM_FLAGS_ANYWHERE the kernel picks the first free address above
        // the GPU carveout [64G,448G) — which is 0x7000000000 exactly. That is
        // the base of a 16GB jumbo slot, so this 896MB data-only mapping was
        // sterilizing a whole slot that CEF's PartitionAlloc needs. The top
        // window [448G,512G) holds only four such slots and CEF wants at least
        // four pools, so we cannot afford to spend one on ourselves.
        // Data-only (never executed — exec always goes through the RX alias),
        // so placement is unconstrained; fall back to ANYWHERE if all candidates
        // are taken, which restores the previous behaviour exactly.
        // ml91: six hand-picked candidates (8/12/16/24/32/48G) ALL failed —
        // sub-64G is far more crowded than assumed. Sweep the whole region on a
        // 1GB stride instead of guessing. Each failed vm_remap(FIXED) is cheap,
        // so ~58 probes at startup costs nothing and finds any real hole.
        // ml92 measured the real map: there is NO sub-64G space at all. The only
        // "free" region down there (0..0x102454000) is __PAGEZERO, and 4G-64G is
        // fully reserved (malloc xzone) — 58 probes on a 1GB stride found nothing.
        // Usable VA is exactly one ~63GB window, 0x7038000000..0x7fffdf0000.
        //
        // That window holds four 16GB-aligned slots (448/464/480/496G) and CEF's
        // PartitionAlloc wants one pool per slot. Landing here at 0x7000000000
        // spends the 448G slot on an 896MB mapping. Slot 496G is ALREADY ruined
        // by Wine furniture (PE images at ~0x7e874c0000 = 505.8G), so parking at
        // the very top costs nothing that isn't already lost and hands 448G back
        // to PartitionAlloc intact.
        // ml91/ml92/ml93: relocating this alias was tried and REVERTED. The map
        // says usable VA is a single ~63GB window (0x7038000000..0x7fffdf0000);
        // sub-64G is __PAGEZERO plus a fully-reserved 4G-64G band, so 58 probes
        // on a 1GB stride found nothing (ml92). Parking at the top of space
        // instead (0x7fc8000000) DID place, but Wine allocates its furniture
        // top-down — the TEB landed 1.25MB below us at 0x7fc7ec0000, pool copies
        // came out zero-filled, and libarm64ecfex died on 8 exec faults before
        // CEF was even reached (ml93). There is nowhere to put an 896MB mapping
        // that does not cost either a 16GB PartitionAlloc slot or Wine's own
        // furniture. The kernel pick (0x7000000000, base of the window) is the
        // least harmful: it spends the 448G slot but leaves the top — where Wine
        // clusters — alone.
        // ml96 census: CEF needs THREE 16GB pools (48GB), not the 144GB a naive
        // sum suggested — #3/#4/#5 are one pool re-rolling its hint, and the two
        // 32GB requests are that same pool over-reserving for 16GB ALIGNMENT.
        // 48GB fits in the 63GB window, so the third pool fails only because no
        // 16GB-ALIGNED slot is left: 464G and 480G are taken, 496G is broken by
        // Wine furniture, and 448G is spent on this 896MB alias.
        //
        // Freeing 448G should let pool 3 land. ml93 tried that and failed by
        // parking at 0x7fc8000000 — the extreme top, exactly where Wine
        // allocates its furniture top-down (the TEB landed 1.25MB below us and
        // pool copies came back zeroed). The map says 0x7c00000000..0x7e874c0000
        // is free, so take the BOTTOM of the already-broken 496G slot instead
        // and leave the top for Wine.
        // DO NOT relocate this alias without new evidence. Three placements were
        // measured against the default kernel pick (0x7000000000, which the
        // kernel picks because it is the first free address above the GPU
        // carveout):
        //   0x7000000000 (default)  ml94=8, ml96=1  exec faults, reaches libcef
        //   0x7fc8000000 (top)      ml93=8          exec faults, dies before CEF
        //   0x7c00000000 (496G)     ml97=16, ml98=16 exec faults, dies before CEF
        // Same fault class in every case (pool page loses content/exec, on a
        // recycled range) — relocation makes an EXISTING intermittent bug worse
        // rather than introducing a new one. Two mechanisms were proposed and
        // BOTH disproven: Wine furniture collision (ml93) and the reclaim-recover
        // band claiming the alias (ml97; the band exclusion landed in
        // signal_arm64_ios.c and did NOT change the count). Whatever couples the
        // alias base to pool stability is still unidentified.
        //
        // Cost of staying here: the alias occupies the base of the 448G slot, so
        // PartitionAlloc gets only two of the three 16GB-aligned pools it needs
        // (see the ml96 [jumbo#N] census). Freeing that slot is worth doing —
        // but by moving WINE's furniture out of 496G, not by moving this.
        // ml977: RESERVE the x64 executable window, then let the kernel place RW.
        //
        // Every x64 Windows executable defaults to ImageBase 0x140000000, and an
        // image with no relocation directory MUST have it. RDR2.exe is exactly
        // that (ImageBase 0x140000000, BASERELOC rva=0 size=0, DYNAMIC_BASE
        // clear). In rdr40/rdr41 the kernel placed this RW alias adjacent to the
        // RX pool -- RX=0x119eb0000, RW=RX+512MB -- so the alias covered
        // 0x140000000, the loader's no-clobber fixed map failed, the exe was
        // placed elsewhere WITHOUT relocations, and its TLS AddressOfCallBacks
        // stayed 0x1432ba978: an address inside this alias. call_tls_callbacks
        // then read its callback list out of pool backing memory.
        //
        // ml976 tried a list of FIXED candidates (0x150000000 upward) and every
        // one returned KERN_NO_SPACE (=3): those ranges are occupied, so a
        // non-overwriting remap correctly refused. ml976 then returned nil,
        // which aborted pool allocation and stopped Wine from starting at all --
        // "JIT pool allocation FAILED". A placement experiment must never brick
        // the launch; that was the bug, not the refusal.
        //
        // So invert it: RESERVE [0x140000000, +256MB) up front, then ask for RW
        // with VM_FLAGS_ANYWHERE exactly as before. The kernel cannot choose a
        // range that overlaps a mapping we already hold, so adjacency is ruled
        // out without naming any address ourselves, and the reservation also
        // stops unrelated allocations and earlier relocatable images from taking
        // the window first. rwAddr is seeded with 0x150000000 as a floor hint so
        // the search starts just above the window rather than jumping far away
        // (a large alias offset is legal -- FEX derives DualMap::WriteOffset from
        // the real RW-RX distance -- but a near placement stays closest to the
        // measured-good configuration).
        //
        // Failure is never fatal here: if the window cannot be reserved we log it
        // and continue with the kernel's choice, which is the pre-ml976 behaviour.
        // MADEIRA_NO_EXE_WINDOW=1 skips the reservation entirely.
        // ml1034: the reservation and the RX overlap rejection both happen before
        // the pool is allocated now (see above). This is a post-hoc assertion: if
        // it fires, the debugger handed back a range covering a window we held,
        // which should be impossible.
        let rxAddrV = vm_address_t(bitPattern: rxPtr)
        if overlapsExeWindow(rxAddrV, vm_address_t(poolSize)) {
            LogStore.shared.log("ml1034: RX pool STILL overlaps the executable window despite reserving "
                + "it first (windowHeld=\(windowHeld)) — a non-relocatable main image will be displaced",
                level: .error)
        }

        // ml1037: the hint used to be 0x150000000 ("just above the window"), and
        // the alias duly took the 500MB hole there -- the very hole the RX pool
        // now needs. The alias has no placement requirement of its own (FEX
        // derives WriteOffset from the real distance), so send it high, where it
        // lived in every run before ml977, and keep the scarce low gap for RX.
        // A process without the extended-virtual-addressing entitlement has a map
        // that ends at 0xfc0000000 (63 GB). The 0x7000000000 hint is past its end,
        // and an ANYWHERE search that starts past the end of the map does not
        // wrap: every alias failed with KERN_NO_SPACE although ~50 GB was free.
        // Upstream (ba3ab26) then retries once with no hint. The kernel's choice
        // is the LOWEST hole that fits: with a pool small enough for the hole
        // below the executable window, ml1040's plug there is released just
        // before this remap, so a hint-less alias would take [0x11e800000,..),
        // where Wine later maps sub-floor x64 images. So ask just above the RX
        // pool first (0x300000000 on the device's 2026-10-02 census), and only
        // then take the kernel's choice. On a 512 GB map the first request
        // succeeds as before.
        var kr1: kern_return_t = KERN_NO_SPACE
        // Places the JIT pool's RW alias lower when the 0x7000000000 hint is past the end of the address map (63 GB maps): just above the RX pool, then where the kernel chooses; 0 fails at the hint as before.
        let aliasRetry = MadeiraConfig.flag("MADEIRA_RW_ALIAS_RETRY")
        for hint in [vm_address_t(0x7000000000), rxAddrV + vm_address_t(poolSize), 0] {
            rwAddr = hint
            kr1 = vm_remap(
                mach_task_self_,
                &rwAddr,
                vm_size_t(poolSize),
                0,
                VM_FLAGS_ANYWHERE,
                mach_task_self_,
                vm_address_t(bitPattern: rxPtr),
                0, // copy = false
                &curProt,
                &maxProt,
                VM_INHERIT_NONE
            )
            if hint != 0x7000000000 {
                LogStore.shared.log(String(format: "[rw-alias] high hint out of reach; %@ kr=%d RW=0x%lx",
                                           hint == 0 ? "kernel placement" : String(format: "above the RX pool (hint 0x%lx)", Int(hint)),
                                           kr1, Int(rwAddr)), level: kr1 == KERN_SUCCESS ? .info : .error)
            }
            if kr1 != KERN_NO_SPACE || !aliasRetry { break }
        }

        guard kr1 == KERN_SUCCESS else {
            LogStore.shared.log("vm_remap failed: \(kr1)", level: .error)
            poolFailure = "Madeira could not map its JIT memory (vm_remap error \(kr1)). Restart Madeira and try again; "
                + "if it keeps happening, send the diagnostic log."
            return nil
        }

        let rwOverlaps = overlapsExeWindow(rwAddr, vm_address_t(poolSize))
        LogStore.shared.log("ml977: RX=[\(String(format:"%p",Int(rxAddrV))),"
            + "\(String(format:"%p",Int(rxAddrV + vm_address_t(poolSize))))) "
            + "RW=[\(String(format:"%p",Int(rwAddr))),"
            + "\(String(format:"%p",Int(rwAddr + vm_address_t(poolSize))))) "
            + "offset=0x\(String(Int(rwAddr) - Int(rxAddrV), radix: 16)) "
            + "windowHeld=\(windowHeld) rwOverlap=\(rwOverlaps)",
            level: rwOverlaps ? .error : .success)

        // Set RW protection
        let kr2 = vm_protect(mach_task_self_, rwAddr, vm_size_t(poolSize), 0, VM_PROT_READ | VM_PROT_WRITE)
        guard kr2 == KERN_SUCCESS else {
            LogStore.shared.log("vm_protect(RW) failed: \(kr2)", level: .error)
            vm_deallocate(mach_task_self_, rwAddr, vm_size_t(poolSize))
            poolFailure = "Madeira could not make its JIT memory writable (vm_protect error \(kr2)). Restart Madeira and try again; "
                + "if it keeps happening, send the diagnostic log."
            return nil
        }

        let rwPtr = UnsafeMutableRawPointer(bitPattern: rwAddr)!
        LogStore.shared.log("RW mapping at \(String(format: "%p", Int(bitPattern: rwPtr)))")

        // ml358: the pool has NEVER been jetsam-exempt. jit_region_create()
        // applies NO_FOOTPRINT, but this path takes its RX pages from the
        // debugger and vm_remaps the RW alias, so every written pool page has
        // counted against phys_footprint in full — which is what killed ml357
        // ("Terminated due to memory issue" with 848MB of pool written). Apply
        // the ledger exemption to the shared object now that both aliases
        // exist; the helper logs footprint either side, so the next log says
        // whether the kernel honoured it. Non-fatal if refused.
        // ml360: the entry must be made over the RW ALIAS, not the RX view —
        // ml360's run showed mach_make_memory_entry_64(READ|WRITE) over the
        // debugger's RX pages fails with KERN_PROTECTION_FAILURE. Same vm
        // object either way; the RW alias actually permits the access.
        let exempt = jit_make_region_no_footprint(rwPtr, poolSize, "pool-RW-alias")
        // ml359: log the verdict through LogStore.log (which appends to the
        // file) — the ml358 run lost it because the jit_log callback only fed
        // the UI view. Detail (kr / footprint delta) is in the jit_log lines.
        LogStore.shared.log("[no-footprint] pool applied=\(exempt)", level: exempt ? .success : .error)

        LogStore.shared.log("JIT pool ready (debugger still attached).", level: .success)
        poolTaken = true

        return (rx: rxPtr, rw: rwPtr, size: poolSize)
    }

    /// Detach the debugger. Call this after Wine is done loading PE DLLs.
    static func detachDebugger() {
        LogStore.shared.log("Detaching debugger...")
        jit26_detach()
        // task #34: signal in-process waiters (share-probe poller). CS_DEBUGGED
        // is sticky post-detach, so an env flag is the reliable signal.
        setenv("MADEIRA_DETACHED", "1", 1)
        LogStore.shared.log("Debugger detached.", level: .success)
    }
}
