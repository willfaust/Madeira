// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

// Madeira's JIT helper: a classic app extension that Madeira starts by its bundle ID
// (app/Madeira/JITBuiltInHost.swift), so a sideloader's renamed install still finds it.
// One MadeiraJITRequest per extension request, answered when the request completes.

import Foundation
import os
#if !targetEnvironment(simulator)
import StikJIT
#endif

#if targetEnvironment(simulator)
private struct DDIPaths {
    static func `default`(in directory: URL) -> DDIPaths { DDIPaths() }
}

private enum StikJIT {
    enum Script { case customBase64(String) }
    struct DeviceSecurityState { let isTXMPresent: Bool? }
    enum PreparationStage { case unavailable }
    enum JITReadiness {
        case unreachable(reason: String)
        case preparationFailed(reason: String)
        case ready(DeviceSecurityState)
    }

    static var isTXMPresent: Bool? { nil }
    static func prepareDevice(pairingFile: URL, paths: DDIPaths,
                              progress: (PreparationStage) -> Void) -> JITReadiness {
        .unreachable(reason: "Built-in JIT is available only on a physical device.")
    }
    static func enableJIT(targetPID: Int32, pairingFile: URL, ddiPaths: DDIPaths,
                          script: Script, forceScript: Bool,
                          preparationProgress: (PreparationStage) -> Void,
                          progress: (String) -> Void) throws {
        throw NSError(domain: "MadeiraJITHelper", code: 100,
                      userInfo: [NSLocalizedDescriptionKey:
                        "Built-in JIT is available only on a physical device."])
    }
    static func resetCachedDDI(at paths: DDIPaths) throws {}
}
#endif

private enum MadeiraJITWork {
    /// One request at a time, as the XPC handler ran them before.
    static let queue = DispatchQueue(label: "com.willfaust.madeora.jit-helper")

    static func handle(_ request: MadeiraJITRequest) -> MadeiraJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true,
                             message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "MadeiraJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths,
                    progress: { NSLog("[MadeiraJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready.",
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason,
                                 txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false,
                                 message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64,
                      !scriptBase64.isEmpty else {
                    throw NSError(domain: "MadeiraJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Madeira JIT script was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: {
                        NSLog("[MadeiraJIT] prepare: %@", String(describing: $0))
                    },
                    progress: { NSLog("[MadeiraJIT] %@", $0) })
                return .init(success: true,
                             message: "Madeira detached cleanly from its built-in JIT helper.",
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI, .probe:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the first input
/// item; the response goes back as JSON in the item the request completes with. Enable
/// completes only when Madeira's script has detached, so the request, and this process,
/// last as long as the debugger does.
@objc(MadeiraJITHelperHandler)
final class MadeiraJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[MadeiraJITRequest.itemKey] as? Data
        let request = data.flatMap { try? JSONDecoder().decode(MadeiraJITRequest.self, from: $0) }
        // ml1310: the probe never waits behind a running enable request (that one lasts
        // as long as the debugger does), so it has its own queue.
        let queue = request?.operation == .probe ? DispatchQueue.global(qos: .utility) : MadeiraJITWork.queue
        queue.async {
            let response: MadeiraJITRequest.Response
            if let request, request.operation == .probe {
                response = MadeiraExtensionProbeWork.run()
            } else if let request {
                response = MadeiraJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Madeira's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [MadeiraJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}

/// ml1310: what this extension's own process may map, for running Wine processes in an
/// app extension (docs/NUTSEMU_ANALYSIS.md section 4c, step 7; docs/PROCESS_MODEL_ML1310.md).
/// Read-only and harmless: every reservation is PROT_NONE and given back at once, the
/// exec test maps 16 KB of anonymous memory, changes its protection and unmaps it, and
/// nothing is ever executed or touched.
private enum MadeiraExtensionProbeWork {
    static func run() -> MadeiraJITRequest.Response {
        let task = mach_task_self_
        let page = vm_size_t(vm_page_size)
        let none = vm_prot_t(0), rw = vm_prot_t(3), rwx = vm_prot_t(7)
        let inheritNone = vm_inherit_t(2)   // VM_INHERIT_NONE

        // vm_map: on arm64 the same 64-bit call as mach_vm_map, which iOS hides from Swift.
        func map(_ size: vm_size_t, at: vm_address_t?, maxProt: vm_prot_t) -> kern_return_t {
            var addr = at ?? 0
            let kr = vm_map(task, &addr, size, 0, at == nil ? VM_FLAGS_ANYWHERE : VM_FLAGS_FIXED,
                                 0, 0, 0, none, maxProt, inheritNone)
            if kr == KERN_SUCCESS { vm_deallocate(task, addr, size) }
            return kr
        }
        func gb(_ v: UInt64) -> String { String(format: "%.2fGB", Double(v) / 1_073_741_824) }
        func mb(_ v: UInt64) -> String { "\(v >> 20)MB" }
        func fixed(_ at: vm_address_t) -> String {
            let kr = map(page, at: at, maxProt: rw)
            return kr == KERN_SUCCESS ? "ok" : kr == KERN_NO_SPACE ? "occupied" : "refused(kr=\(kr))"
        }

        // The largest single VM_FLAGS_ANYWHERE reservation, by binary search in 16 MB
        // steps up to 1 TB.
        let step: vm_size_t = 16 << 20
        var lo: vm_size_t = 0, hi: vm_size_t = (1 << 40) / step + 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if map(mid * step, at: nil, maxProt: rw) == KERN_SUCCESS { lo = mid } else { hi = mid }
        }
        let largest = UInt64(lo * step)
        let rwxKr = map(step, at: nil, maxProt: rwx)

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let infoKr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let vm = infoKr == KERN_SUCCESS
            ? "map=0x\(String(info.min_address, radix: 16))-0x\(String(info.max_address, radix: 16)) " +
              "footprint=\(mb(info.phys_footprint)) limit_remaining=\(mb(info.limit_bytes_remaining))"
            : "task_vm_info=unavailable(kr=\(infoKr))"

        var exec = "mmap-failed"
        let size = Int(page)
        if let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
           p != UnsafeMutableRawPointer(bitPattern: -1) {
            exec = mprotect(p, size, PROT_READ | PROT_EXEC) == 0
                ? "ok" : "refused(\(String(cString: strerror(errno))))"
            munmap(p, size)
        }

        let message = "pid=\(getpid()) anywhere_max=\(gb(largest)) (16MB steps, PROT_NONE, max RW) " +
            "anywhere16MB_maxRWX=\(rwxKr == KERN_SUCCESS ? "ok" : "refused(kr=\(rwxKr))") " +
            "fixed@0x7000000000=\(fixed(0x70_0000_0000)) fixed@0x14c000000=\(fixed(0x1_4c00_0000)) " +
            "\(vm) available=\(mb(UInt64(os_proc_available_memory()))) mprotect_exec=\(exec)"
        NSLog("[MadeiraJIT] ext-probe: %@", message)
        return .init(success: true, message: message, txmPresent: nil)
    }
}
