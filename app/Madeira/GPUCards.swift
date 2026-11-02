//
//  GPUCards.swift
//  Madeira
//
//  "Graphics card the game sees" (Game details › Compatibility): one choice
//  per game, which names the same card everywhere a game can ask.
//
//  - DXGI (Direct3D 10, 11 and 12): DXMT's dxgi.customVendorId,
//    dxgi.customDeviceId and dxgi.customDeviceDesc.
//  - Direct3D 9: d3d9.customVendorId, d3d9.customDeviceId,
//    d3d9.customDeviceDesc and d3d9.customDriver (build/dxmt-patches/0001).
//  - Windows' own adapter (EnumDisplayDevices, SetupAPI's PCI entry, the
//    display driver key, the D3DKMT adapter): win32u reads
//    MADEIRA_GPU_VENDOR, MADEIRA_GPU_DEVICE and MADEIRA_GPU_NAME
//    (build/win32u-unix/sysparams_ios.c, ios_virtual_gpu_ids).
//  - NVAPI: DXMT_ENABLE_NVEXT follows the card's maker, 1 for NVIDIA and 0
//    for any other, so a game that asks NVAPI first agrees with DXGI.
//
//  Without a choice nothing changes: the "Report an NVIDIA GPU" and "Older
//  NVIDIA card (Direct3D 9)" switches work as before. A choice replaces both.
//
//  Plain values only (no Metal, no UI), so tests/host/check-gpu-card.py can
//  check the table against sysparams_ios.c's list of known adapters.
//

import Foundation

struct GPUCard: Equatable {
    /// What LibraryPrefs stores.
    let id: String
    /// What the picker shows.
    let title: String
    let vendor: UInt16
    let device: UInt16
    /// The adapter name a game reads; nil is the Metal device's own name.
    let name: String?
    /// Direct3D 9's driver file; nil keeps DXMT's.
    var driver: String? = nil

    var vendorHex: String { String(format: "%04x", vendor) }
    var deviceHex: String { String(format: "%04x", device) }
    var isNVIDIA: Bool { vendor == GPUCards.nvidiaVendor }
}

enum GPUCards {
    static let appleVendor: UInt16 = 0x106b, nvidiaVendor: UInt16 = 0x10de
    static let amdVendor: UInt16 = 0x1002, intelVendor: UInt16 = 0x8086

    /// Every card sysparams_ios.c may have registered must be in its
    /// ios_known_gpus list too, so a later launch with another card removes it.
    static let all: [GPUCard] = [
        // The card "Report an NVIDIA GPU" already reports (10DE:2544).
        GPUCard(id: "nvidia-rtx3060", title: "NVIDIA GeForce RTX 3060", vendor: nvidiaVendor, device: 0x2544,
                name: "NVIDIA GeForce RTX 3060"),
        // For games that only know cards up to 2016-2018.
        GPUCard(id: "nvidia-gtx1060", title: "NVIDIA GeForce GTX 1060", vendor: nvidiaVendor, device: 0x1c03,
                name: "NVIDIA GeForce GTX 1060 6GB"),
        // "Older NVIDIA card (Direct3D 9)" (D3D9Identity.olderNvidiaName), here for
        // every API: Fallout 3 and New Vegas pick their render path from the name and the driver.
        GPUCard(id: "nvidia-7900gs", title: "NVIDIA GeForce 7900 GS (older games)", vendor: nvidiaVendor, device: 0x0292,
                name: "NVIDIA GeForce 7900 GS", driver: "nv4_disp.dll"),
        GPUCard(id: "amd-rx6700xt", title: "AMD Radeon RX 6700 XT", vendor: amdVendor, device: 0x73df,
                name: "AMD Radeon RX 6700 XT"),
        GPUCard(id: "amd-rx580", title: "AMD Radeon RX 580", vendor: amdVendor, device: 0x67df,
                name: "Radeon RX 580 Series"),
        GPUCard(id: "intel-uhd630", title: "Intel UHD Graphics 630", vendor: intelVendor, device: 0x3e92,
                name: "Intel(R) UHD Graphics 630"),
        // This device's own GPU under its Metal name in every place, Windows'
        // registry included (which otherwise says "Madeira Display"), with the
        // ids DXMT's Direct3D 9 and win32u already use.
        GPUCard(id: "apple", title: "This device's own GPU", vendor: appleVendor, device: 0x0001, name: nil),
    ]

    static func card(_ id: String?) -> GPUCard? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    /// The card's name, the Metal device's for the Apple card.
    static func name(_ card: GPUCard, metalName: String?) -> String? {
        card.name ?? metalName.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// DXMT's options for a card, ids first. `names: false` leaves the two
    /// descriptions out (ContentView, when DXMT_CONFIG would pass its limit).
    static func dxmtOptions(_ card: GPUCard, metalName: String?, names: Bool = true) -> [String] {
        var out: [String] = []
        for api in ["dxgi", "d3d9"] {
            out.append("\(api).customVendorId=\(card.vendorHex)")
            out.append("\(api).customDeviceId=\(card.deviceHex)")
        }
        if let driver = card.driver { out.append("d3d9.customDriver=\(driver)") }
        // DXMT's parser keeps a quoted value whole (a name has spaces); the
        // Apple card's name is already DXMT's default.
        if names, let name = card.name {
            for api in ["dxgi", "d3d9"] { out.append("\(api).customDeviceDesc=\"\(name)\"") }
        }
        return out
    }

    /// The description options, in the order ContentView drops them when
    /// DXMT_CONFIG would pass DXMT's 259 characters.
    static let nameKeys = ["dxgi.customDeviceDesc", "d3d9.customDeviceDesc"]

    static func optionKey(_ option: String) -> String {
        option.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? option
    }

    /// The environment a launch exports for a card: (name, value), and nil
    /// values are unset. NVIDIA's monitor switches go with any PC card, as they
    /// do with "Report an NVIDIA GPU": a game that found the card also looks
    /// for its monitor on it.
    static func environment(_ card: GPUCard, metalName: String?) -> [(String, String?)] {
        let pc = card.vendor != appleVendor
        var env: [(String, String?)] = [
            ("DXMT_ENABLE_NVEXT", card.isNVIDIA ? "1" : "0"),
            ("DXMT_WSI_MONITOR_IDENTITY", pc ? "1" : nil),
            ("DXMT_WSI_MODE_TABLE", pc ? "1" : nil),
            ("MADEIRA_GPU_VENDOR", card.vendorHex),
            ("MADEIRA_GPU_DEVICE", card.deviceHex),
        ]
        env.append(("MADEIRA_GPU_NAME", name(card, metalName: metalName)))
        return env
    }

    /// The names win32u reads, unset by a launch without a card.
    static let identityNames = ["MADEIRA_GPU_VENDOR", "MADEIRA_GPU_DEVICE", "MADEIRA_GPU_NAME"]

    /// A game's prefs with sD3DDevice on the card it will see (Fallout 3 and
    /// New Vegas reopen their launcher when it changes; D3D9Identity.prefsFiles),
    /// or nil when nothing changes. With no card (`wanted` nil) the Metal name
    /// goes back only over a name one of these cards wrote.
    static func prefsText(_ text: String, wanted: String?, metalName: String?) -> String? {
        let ours = Set(all.compactMap(\.name))
        var lines = text.components(separatedBy: "\n")
        var changed = false
        for (i, raw) in lines.enumerated() {
            let cr = raw.hasSuffix("\r")
            let line = cr ? String(raw.dropLast()) : raw
            guard line.lowercased().hasPrefix("sd3ddevice=") else { continue }
            let key = line.prefix { $0 != "=" }
            let current = line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            let target = wanted ?? (ours.contains(current) ? metalName : nil)
            guard let target, !target.isEmpty, target != current else { continue }
            lines[i] = "\(key)=\"\(target)\"" + (cr ? "\r" : "")
            changed = true
        }
        return changed ? lines.joined(separator: "\n") : nil
    }
}
