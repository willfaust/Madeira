import Foundation
import Security
// ObservableObject/@Published for JITState; the rest of this file is
// Foundation and Security only.
import Combine

private typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
private func _SecTaskCopyValueForEntitlement(
    _ task: SecTaskRef,
    _ entitlement: NSString,
    _ error: NSErrorPointer
) -> CFTypeRef?

@_silgen_name("SecTaskCreateFromSelf")
private func _SecTaskCreateFromSelf(
    _ allocator: CFAllocator?
) -> SecTaskRef?

func checkAppEntitlement(_ ent: String) -> Bool {
    guard let task = _SecTaskCreateFromSelf(nil) else { return false }

    guard let value = _SecTaskCopyValueForEntitlement(task, ent as NSString, nil) else {
        return false
    }

    if let number = value as? NSNumber {
        return number.boolValue
    }

    return false
}

struct EntitlementStatus {
    let jitAllowed: Bool
    let increasedMemory: Bool
    let extendedVA: Bool

    static func check() -> EntitlementStatus {
        EntitlementStatus(
            jitAllowed: checkAppEntitlement("com.apple.security.cs.allow-jit"),
            increasedMemory: checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit"),
            extendedVA: checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing")
        )
    }
}

/* Runtime check: is a debugger attached to this process (P_TRACED)?
 * This is the signal StikDebug JIT actually rides on — CS_DEBUGGED gets
 * set while traced, enabling JIT-region execution. The allow-jit
 * ENTITLEMENT is macOS-only and never granted on iOS, so the old badge
 * built on it was permanently ✗ no matter what StikDebug did. */
func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let ret = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard ret == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}

/// Is JIT available, and is the thing that grants it still attached?
///
/// Two questions with two different answers, and conflating them is exactly
/// what made the old "JIT off" chip lie:
///
/// - `capable` is `CS_DEBUGGED`. The kernel sets it when StikDebug attaches and
///   it is STICKY across detach — the pool pages StikDebug blessed keep
///   executing, which is the whole reason the app detaches early and gets its
///   speed back. This is what "JIT works" means, and it does not go false when
///   the debugger leaves.
/// - `attached` is `P_TRACED`: is StikDebug on this process RIGHT NOW. It goes
///   false within seconds of every launch, because detaching early is
///   deliberate. It is needed back for any NEW BRK request — a fresh JIT pool,
///   the page-zero mapping — so the *next* launch needs a re-attach even though
///   JIT never stopped working.
///
/// The chip read `P_TRACED` alone, so it announced "JIT off" a couple of
/// seconds into every run while the guest was compiling happily through the
/// blessed pool. Reported as "JIT turns itself off as soon as I enter the
/// desktop".
final class JITState: ObservableObject {
    static let shared = JITState()

    @Published private(set) var capable = false
    @Published private(set) var attached = false

    private var timer: Timer?

    private init() {}

    /// Poll, rather than publishing from the attach/detach sites. StikDebug
    /// attaches from another process, so there is no in-app event for the
    /// attach, and the detach has more than one path (a failed pool returns
    /// before the sequence's own detach call).
    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common, or the state freezes while the log list is being scrolled.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let nowCapable = jit_check_debugged()
        let nowAttached = isDebuggerAttached()
        if nowCapable != capable {
            capable = nowCapable
            report(nowCapable
                ? "JIT enabled (CS_DEBUGGED set) — stays enabled after detach"
                : "JIT off — CS_DEBUGGED is clear, so StikDebug never attached "
                  + "(or the app was restarted since it did)")
        }
        if nowAttached != attached {
            attached = nowAttached
            report(nowAttached
                ? "StikDebug attached"
                : "StikDebug detached — JIT still enabled, but a new run needs a "
                  + "re-attach to allocate its pool (press Enable JIT)")
        }
    }

    /// The home screen's JIT chip, defined here so the chip and the log lines
    /// above cannot drift apart. `attached` is shown as a suffix and not as a
    /// warning, because being detached between runs is how this app works.
    var chipText: String {
        if !capable { return "JIT off" }
        return attached ? "JIT ready" : "JIT ready \u{b7} detached"
    }

    private func report(_ line: String) {
        fputs("[jit] \(line)\n", stderr)
        LogStore.shared.log(line, level: capable ? .success : .error)
    }
}
