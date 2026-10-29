import Foundation
import Security
import UIKit

private typealias SecTaskRef = OpaquePointer

@_silgen_name("SecTaskCopyValueForEntitlement")
private func _SecTaskCopyValueForEntitlement(
    _ task: SecTaskRef,
    _ entitlement: NSString,
    _ error: NSErrorPointer
) -> Unmanaged<CFTypeRef>?

@_silgen_name("SecTaskCreateFromSelf")
private func _SecTaskCreateFromSelf(
    _ allocator: CFAllocator?
) -> SecTaskRef?

func checkAppEntitlement(_ ent: String) -> Bool {
    guard let task = _SecTaskCreateFromSelf(nil) else { return false }
    // The manually declared Create/Copy APIs return caller-owned CF objects.
    defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(task)).release() }

    guard let value = _SecTaskCopyValueForEntitlement(task, ent as NSString, nil)?.takeRetainedValue() else {
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

/// How this copy is signed, from the process's code-signing flags: whether a
/// debugger may attach (get-task-allow), which StikDebug needs to enable JIT.
struct SigningStatus {
    let known: Bool
    let flags: UInt32
    /// CS_GET_TASK_ALLOW. Unknown flags count as debuggable, so a failed query
    /// never blocks a copy that works.
    var debuggable: Bool { !known || flags & 0x4 != 0 }
    var debugged: Bool { known && flags & 0x1000_0000 != 0 }

    static var current: SigningStatus {
        var flags: UInt32 = 0
        let known = jit_cs_status(&flags)
        return SigningStatus(known: known, flags: flags)
    }
    static let notDebuggableMessage = "JIT cannot be enabled on this copy of Madeira: it was signed without get-task-allow "
        + "(a distribution or enterprise certificate), so no debugger can attach to it. Install Madeira with a development "
        + "certificate (for example SideStore, AltStore or Xcode), then enable JIT again."
}

/// The device, system, address map, signing and settings a session depends on,
/// written to the diagnostic log at start-up and again at each launch, so a log
/// says by itself which device and set-up produced it. No names, identifiers or
/// account data: the model code, versions, sizes and switches only.
enum DeviceDiagnostics {
    private static func machine() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    /// The user address map: it ends at 0xfc0000000 (63 GB) without the
    /// extended-virtual-addressing entitlement and at 512 GB with it.
    private static func addressMap() -> String {
        var low: UInt64 = 0, high: UInt64 = 0
        guard jit_task_map_range(&low, &high) else { return "address-map=unknown" }
        return String(format: "address-map=[0x%llx,0x%llx) %lluGB", low, high, high >> 30)
    }
    /// The kind and lifetime of the embedded provisioning profile and the
    /// entitlements it grants. A 7-day lifetime is a free developer account.
    private static func profile() -> String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let object = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound),
                                                                       options: [], format: nil),
              let plist = object as? [String: Any]
        else { return "profile=none" }
        let granted = plist["Entitlements"] as? [String: Any] ?? [:]
        func grants(_ key: String) -> Int { (granted[key] as? Bool) == true ? 1 : 0 }
        let kind: String
        if (plist["ProvisionsAllDevices"] as? Bool) == true { kind = "enterprise" }
        else if plist["ProvisionedDevices"] != nil { kind = grants("get-task-allow") == 1 ? "development" : "ad-hoc" }
        else { kind = "store" }
        var text = "profile=\(kind)"
        if let created = plist["CreationDate"] as? Date, let expires = plist["ExpirationDate"] as? Date {
            let day = 86400.0
            text += " lifetime=\(Int((expires.timeIntervalSince(created) / day).rounded()))d"
                + " left=\(Int((expires.timeIntervalSinceNow / day).rounded(.down)))d"
        }
        return text + " profile-get-task-allow=\(grants("get-task-allow"))"
            + " profile-increased-memory=\(grants("com.apple.developer.kernel.increased-memory-limit"))"
            + " profile-extended-va=\(grants("com.apple.developer.kernel.extended-virtual-addressing"))"
    }
    private static func signing() -> String {
        let status = SigningStatus.current
        guard status.known else { return "cs-flags=unknown debugger-attached=\(isDebuggerAttached() ? 1 : 0)" }
        return String(format: "cs-flags=0x%x get-task-allow=%d cs-debugged=%d debugger-attached=%d",
                      status.flags, status.debuggable ? 1 : 0, status.debugged ? 1 : 0, isDebuggerAttached() ? 1 : 0)
    }
    private static func power() -> String {
        "low-power=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) thermal=\(thermal())"
    }

    /// Once per app run, on the main thread (it reads the screen).
    static func logStartup() {
        let process = ProcessInfo.processInfo
        let log = LogStore.shared
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        log.log("[device] model=\(machine()) idiom=\(idiom)\(process.isiOSAppOnMac ? " on-mac=1" : "")"
            + " os=\(UIDevice.current.systemName) \(process.operatingSystemVersionString)"
            + " ram=\(process.physicalMemory >> 20)MB available=\(jit_available_memory() >> 20)MB cores=\(process.activeProcessorCount)")
        let entitlements = EntitlementStatus.check()
        log.log("[device] \(addressMap()) increased-memory=\(entitlements.increasedMemory ? 1 : 0)"
            + " extended-va=\(entitlements.extendedVA ? 1 : 0)")
        log.log("[device] signing: \(signing()) \(profile())")
        if !SigningStatus.current.debuggable {
            log.log("[device] this copy is signed without get-task-allow: no debugger can attach to it, so JIT cannot be "
                + "enabled. Reinstall Madeira with a development certificate.", level: .error)
        }
        if StikJITHelper.flaggedWithoutDebugger {
            log.log("[jit-debugger] CS_DEBUGGED is set but no debugger is attached at start-up: JIT was enabled "
                + "outside Madeira (StikDebug's app list attaches and leaves). Enable JIT in Madeira before playing.",
                level: .error)
        }
        let screen = UIScreen.main
        let offset = TimeZone.current.secondsFromGMT()
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        log.log("[device] settings: \(power())"
            + " screen=\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))@\(screen.nativeScale)x"
            + " max-fps=\(screen.maximumFramesPerSecond)"
            + String(format: " utc-offset=%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) / 60 % 60)
            + " free-disk=\(free.map { "\($0 >> 30)GB" } ?? "unknown")"
            + " stikdebug-url=\(StikJITHelper.isAvailable ? 1 : 0)")
    }

    /// At each launch: the values that change while the app runs.
    static func logLaunch() {
        LogStore.shared.log("[device] launch: \(signing()) \(addressMap()) available=\(jit_available_memory() >> 20)MB \(power())")
    }
}
