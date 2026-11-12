//
//  LibraryBCD.swift
//  Madeira
//
//  madeira-bcd: this fork's per-game options inside upstream's library.
//
//  A game's madeira-bcd options are keyed by its Windows path: the switches in
//  LibraryPrefs (AVX, Wine's C++ runtime, NVIDIA) and the game's own config
//  file (GameProfiles.swift: any madeira.cfg key or env.NAME line).
//

import Foundation
import Metal

/// What a launch exports on top of the exe, its arguments and its screen.
enum BCDLaunch {
    /// The switches every launch of a game applies. Everything is set or unset, so a
    /// previous launch's choice never leaks into this one.
    static func applyExtras(avx: Bool, wineVCRT: Bool, nvidia: Bool, olderNvidia: Bool = false, card: GPUCard? = nil,
                            profile: GameProfile?) {
        if avx { setenv("MADEIRA_FEX_AVX", "1", 1) } else { unsetenv("MADEIRA_FEX_AVX") }
        applyJapanese(false)   // applyLibrary turns it on for a game that has it
        if wineVCRT { setenv("MADEIRA_WINE_VCRT", "1", 1) } else { unsetenv("MADEIRA_WINE_VCRT") }
        var dxmtExtra: [String] = []
        if nvidia {
            setenv("DXMT_ENABLE_NVEXT", "1", 1)
            // The same GeForce RTX 3060 (10DE:2544) win32u registers as the
            // display adapter (sysparams_ios.c, ios_virtual_gpu_ids); merged
            // into DXMT_CONFIG by ContentView.
            dxmtExtra.append("dxgi.customDeviceId=2544")
            // DXGI's output carries user32's monitor handle and user32's mode
            // list, so a game can find its monitor on the adapter. Default-on
            // in this fork until the build 222 switch to upstream, where both
            // became 32-bit-only switches; Ghost of Tsushima has said "No
            // installed graphics card ... monitor connected to it" on every
            // launch since (logs 2026-10-01 16:15 / 16:16 / 17:04; 2026-09-28
            // ran with both). A game file's env.NAME = 0 still wins.
            setenv("DXMT_WSI_MONITOR_IDENTITY", "1", 1)
            setenv("DXMT_WSI_MODE_TABLE", "1", 1)
        } else {
            unsetenv("DXMT_ENABLE_NVEXT")
            unsetenv("DXMT_WSI_MONITOR_IDENTITY")
            unsetenv("DXMT_WSI_MODE_TABLE")
        }
        // "Older NVIDIA card (Direct3D 9)": after the NVIDIA ids, so its D3D9 ids win.
        if olderNvidia { dxmtExtra += D3D9Identity.olderNvidia.options }
        // "Graphics card the game sees" (GPUCards.swift): the same card in DXGI,
        // Direct3D 9, NVAPI and Windows' adapter. applyLibrary turns both NVIDIA
        // switches off when one is chosen, so nothing above names another card.
        if let card {
            let metalName = MTLCreateSystemDefaultDevice()?.name
            dxmtExtra += GPUCards.dxmtOptions(card, metalName: metalName)
            for (name, value) in GPUCards.environment(card, metalName: metalName) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        } else {
            for name in GPUCards.identityNames { unsetenv(name) }
        }
        // The game's own settings (GameProfiles.swift).
        if let p = profile, p.hasSettings, let u = p.url {
            setenv("MADEIRA_CFG_GAME", u.path, 1)
        } else {
            unsetenv("MADEIRA_CFG_GAME")
        }
        if dxmtExtra.isEmpty { unsetenv("MADEIRA_DXMT_EXTRA") }
        else { setenv("MADEIRA_DXMT_EXTRA", dxmtExtra.joined(separator: ";"), 1)   /* DXMT splits on ";" */ }
    }

    /// "Japanese locale" (Game details › Compatibility): MADEIRA_JAPANESE, read by
    /// WineProcessBridge.m before the wineserver starts (the font and the Japanese font
    /// names go into the prefix) and when Wine starts (LC_ALL = ja_JP.UTF-8, so code page
    /// 932, and the extra code page tables). Off: a Japanese locale an earlier launch
    /// exported is taken back; madeira.cfg's and the game file's own env lines are
    /// exported again after this, so a line there still applies.
    static func applyJapanese(_ on: Bool) {
        if on {
            setenv("MADEIRA_JAPANESE", "1", 1)
        } else {
            unsetenv("MADEIRA_JAPANESE")
            if let lc = getenv("LC_ALL"), String(cString: lc).hasPrefix("ja") {
                unsetenv("LC_ALL"); unsetenv("LANG"); unsetenv("MADEIRA_NLS_EXTRA")
            }
        }
    }

    /// A start from upstream's library: this game's madeira-bcd options. The
    /// FPS limit is the entry's (upstream's FPS picker, which offers 40 FPS too).
    static func applyLibrary(_ entry: LibraryEntry) {
        applyVCRTArm64(entry)
        if entry.desktop == true {
            applyExtras(avx: false, wineVCRT: false, nvidia: false, profile: nil)
            return
        }
        let path = entry.windowsPath
        let profile = GameProfile(windowsPath: path)
        // A chosen card replaces both NVIDIA switches.
        let card = GPUCards.card(LibraryPrefs.gpuCard(path))
        let nvidia = card == nil && LibraryPrefs.nvidia(path)
        let olderNvidia = card == nil && LibraryPrefs.olderNvidia(path)
        applyExtras(avx: LibraryPrefs.avx(path), wineVCRT: LibraryPrefs.wineVCRT(path),
                    nvidia: nvidia, olderNvidia: olderNvidia, card: card, profile: profile)
        applyJapanese(LibraryPrefs.japanese(path))
        if let appID = entry.steamAppID {
            if let card { D3D9Identity.syncGamePrefs(appID: appID, card: card) }
            else { D3D9Identity.syncGamePrefs(appID: appID, olderNvidia: olderNvidia) }
        }
        let program = path.split(separator: "\\").last.map(String.init) ?? path
        let cardLog = card.map { $0.id + " " + $0.vendorHex + ":" + $0.deviceHex } ?? "-"
        LogStore.shared.log("[bcd] library launch \(program): avx=\(LibraryPrefs.avx(path) ? 1 : 0) "
                            + "wine-vcrt=\(LibraryPrefs.wineVCRT(path) ? 1 : 0) nvidia=\(nvidia ? 1 : 0) "
                            + "older-nvidia=\(olderNvidia ? 1 : 0) gpu-card=\(cardLog) "
                            + "japanese=\(LibraryPrefs.japanese(path) ? 1 : 0) "
                            + "game-config=\(profile.hasSettings ? 1 : 0)")
    }

    /// "Pause threads fully" (Game details › Compatibility): MADEIRA_REAL_SUSPEND for
    /// this session, or nil to leave it unset. Without it a Wine SuspendThread only
    /// snapshots the target's registers while the thread keeps running (ml730,
    /// build/wineserver/mach_ios.c). A Unity IL2CPP game's garbage collector suspends
    /// every thread and scans its stack: with the threads still running it freed
    /// objects in use, and Megabonk crashed while loading (c0000005 at a scrambled
    /// address in two of the threads it had suspended). With real suspension it runs.
    /// The game's own On or Off wins; Automatic follows madeira.cfg's real-suspend
    /// when that is set, and otherwise turns it on for a Unity IL2CPP game only:
    /// real suspension can deadlock a game that suspends a thread holding a lock
    /// Madeira's own code needs, so it stays off for everything else.
    static func realSuspend(_ entry: LibraryEntry?) -> (value: String, source: String)? {
        if let entry, entry.desktop != true, let on = LibraryPrefs.realSuspend(entry.windowsPath) {
            return (on ? "1" : "0", "this game's switch")
        }
        if let v = MadeiraConfig.get("real-suspend")?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            return (v, "madeira.cfg real-suspend")
        }
        if let entry, entry.desktop != true, isUnityIL2CPP(entry) { return ("1", "Unity IL2CPP game (GameAssembly.dll)") }
        return nil
    }

    /// The ARM64 Visual C++ runtime marker (env.MADEIRA_VCRT_ARM64_KEY, written by
    /// build/ntdll-unix/server_ios.c) for an Unreal Engine game. Its bootstrap program
    /// sees an ARM64 machine and asks for "Microsoft Visual C++ 2015-2022
    /// Redistributable (arm64)" on every start (Satisfactory exits with 0x2329, and
    /// Subnautica 2 does the same); installing the x64 one or wine-vcrt changes nothing.
    /// Set to 1 here for an Unreal game, unset for every other start so one game's value
    /// never carries over. A line in madeira.cfg or the game's own file is exported after
    /// this and wins (0 turns it off for that game). env.MADEIRA_VCRT_ARM64_AUTO = 0 in
    /// madeira.cfg turns the automatic choice off.
    static func applyVCRTArm64(_ entry: LibraryEntry?) {
        guard let entry, entry.desktop != true, MadeiraConfig.flag("MADEIRA_VCRT_ARM64_AUTO"), isUnreal(entry) else {
            unsetenv("MADEIRA_VCRT_ARM64_KEY")
            return
        }
        setenv("MADEIRA_VCRT_ARM64_KEY", "1", 1)
        LogStore.shared.log("[vcrt-arm64] Unreal game: MADEIRA_VCRT_ARM64_KEY=1 (automatic; a line in madeira.cfg or the game's config wins, env.MADEIRA_VCRT_ARM64_AUTO = 0 turns this off)")
    }

    /// A packaged Unreal Engine game keeps an Engine folder (with Binaries or Extras)
    /// next to its bootstrap program. The game's folder is checked, and for a program
    /// started below it (a direct Steam start of Binaries\Win64\*-Shipping.exe) each
    /// folder between the two.
    static func isUnreal(_ entry: LibraryEntry) -> Bool {
        guard let url = LibraryEntry.hostURL(ofWindowsPath: entry.windowsPath) else { return false }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        let folder = (fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : url.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL
        var candidates = [folder]
        if let launched = LibraryEntry.hostURL(ofWindowsPath: entry.launchWindowsPath)?.resolvingSymlinksInPath().standardizedFileURL,
           launched.path.hasPrefix(folder.path + "/") {
            var dir = launched.deletingLastPathComponent()
            while dir.path.hasPrefix(folder.path + "/") { candidates.append(dir); dir = dir.deletingLastPathComponent() }
        }
        return candidates.contains { dir in
            let engine = dir.appendingPathComponent("Engine", isDirectory: true)
            return ["Binaries", "Extras"].contains { sub in
                var d: ObjCBool = false
                return fm.fileExists(atPath: engine.appendingPathComponent(sub).path, isDirectory: &d) && d.boolValue
            }
        }
    }

    /// A Unity IL2CPP build keeps GameAssembly.dll next to its exe. A direct Steam
    /// launch can select an exe below its install folder; Dock keeps the root check.
    static func isUnityIL2CPP(_ entry: LibraryEntry) -> Bool {
        guard let url = LibraryEntry.hostURL(ofWindowsPath: entry.windowsPath) else { return false }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        let folder = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : url.deletingLastPathComponent()
        if let launched = LibraryEntry.hostURL(ofWindowsPath: entry.launchWindowsPath) {
            let program = launched.resolvingSymlinksInPath().standardizedFileURL
            let root = folder.resolvingSymlinksInPath().standardizedFileURL
            if program.path.hasPrefix(root.path + "/"),
               fm.fileExists(atPath: program.deletingLastPathComponent().appendingPathComponent("GameAssembly.dll").path) {
                return true
            }
        }
        return fm.fileExists(atPath: folder.appendingPathComponent("GameAssembly.dll").path)
    }
}

/// "Older NVIDIA card (Direct3D 9)" (Game details › Compatibility): Direct3D 9
/// names a GeForce 7900 GS with NVIDIA's driver file, as the d3d9.dll wrapper
/// New Vegas players install does. Fallout 3 and New Vegas pick their render
/// path from the card's name and the driver: with Madeira's own ("Apple ...",
/// "DXMT (Metal)") they take the basic one (Shader Package 2), and New Vegas
/// crashes loading a save at 00B57AA9 right after building faces; the
/// wrapper's identity gives NVIDIA's (Shader Package 13). The ids alone did not
/// help (2026-10-26 logs): the driver name is the part that counts
/// (d3d9.customDriver, willfaust/dxmt d3d9_interface.cpp).
enum D3D9Identity {
    static let olderNvidiaName = "NVIDIA GeForce 7900 GS"

    struct Card { let options: [String] }
    static let olderNvidia = Card(options: [
        "d3d9.customVendorId=10de", "d3d9.customDeviceId=0292",
        "d3d9.customDeviceDesc=\"\(olderNvidiaName)\"", "d3d9.customDriver=nv4_disp.dll",
    ])

    /// Games that keep the card's name in their prefs (sD3DDevice) and open their
    /// launcher when it changes: a second 32-bit program, which ends the session.
    /// App ID -> the file under Documents/My Games.
    static let prefsFiles: [Int: String] = [
        22380: "FalloutNV/FalloutPrefs.ini",                                   // Fallout: New Vegas
        22300: "Fallout3/FalloutPrefs.ini", 22370: "Fallout3/FalloutPrefs.ini", // Fallout 3, GOTY
    ]

    /// Keeps the game's sD3DDevice on the card it will see, before a launch (no session runs).
    /// Switched off, a name any GPUCards card wrote goes back to the Metal name too.
    static func syncGamePrefs(appID: Int, olderNvidia: Bool) {
        rewritePrefs(appID: appID) { text, metalName in
            olderNvidia ? prefsText(text, olderNvidia: true, metalName: metalName)
                        : GPUCards.prefsText(text, wanted: nil, metalName: metalName)
        }
    }

    /// The same for a game with "Graphics card the game sees" chosen: that card's name.
    static func syncGamePrefs(appID: Int, card: GPUCard) {
        rewritePrefs(appID: appID) { text, metalName in
            GPUCards.prefsText(text, wanted: GPUCards.name(card, metalName: metalName), metalName: metalName)
        }
    }

    private static func rewritePrefs(appID: Int, _ update: (String, String?) -> String?) {
        guard let relative = prefsFiles[appID] else { return }
        let users = LibraryModel.drive.appendingPathComponent("users", isDirectory: true)
        let metalName = MTLCreateSystemDefaultDevice()?.name
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] {
            let file = users.appendingPathComponent(user).appendingPathComponent("Documents/My Games/" + relative)
            guard let data = try? Data(contentsOf: file) else { continue }
            let utf8 = String(data: data, encoding: .utf8)
            guard let text = utf8 ?? String(data: data, encoding: .isoLatin1),
                  let updated = update(text, metalName),
                  let out = updated.data(using: utf8 != nil ? .utf8 : .isoLatin1) else { continue }
            do {
                try out.write(to: file, options: .atomic)
                LogStore.shared.log("[d3d9-identity] app=\(appID) \(relative): sD3DDevice set to the card the game sees")
            } catch {
                LogStore.shared.log("[d3d9-identity] app=\(appID) \(relative): not written: \(error.localizedDescription)", level: .error)
            }
        }
    }

    /// The prefs with sD3DDevice naming the card the game will see, or nil when nothing
    /// changes. Switching off puts back the Metal name only over the name this setting
    /// wrote, never over a name the game or the user chose.
    static func prefsText(_ text: String, olderNvidia: Bool, metalName: String?) -> String? {
        var lines = text.components(separatedBy: "\n")
        var changed = false
        for (i, raw) in lines.enumerated() {
            let cr = raw.hasSuffix("\r")
            let line = cr ? String(raw.dropLast()) : raw
            guard line.lowercased().hasPrefix("sd3ddevice=") else { continue }
            let key = line.prefix { $0 != "=" }
            let current = line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            let wanted: String?
            if olderNvidia { wanted = current == olderNvidiaName ? nil : olderNvidiaName }
            else { wanted = current == olderNvidiaName ? metalName : nil }
            guard let wanted else { continue }
            lines[i] = "\(key)=\"\(wanted)\"" + (cr ? "\r" : "")
            changed = true
        }
        return changed ? lines.joined(separator: "\n") : nil
    }
}

/// A library game that ran out of JIT pool (`[jit-pool] EXHAUSTED`, which ends many
/// big games at start: Slay the Spire 2 with Steam code 45, Satisfactory before its
/// logo) gets the two lines that fixed those games added to its own config:
/// `pool-split = 1` (about 880 MB instead of 560-630 MB) and
/// `env.MADEIRA_X64_IMAGE_NOCOPY = 1` (pure-x64 DLLs are not copied into the pool).
/// The pool is set up once per app run, so they apply after Madeira is reopened, and
/// the alert at the end of the session says so. A key the game's config already sets,
/// to any value, is left alone, so a player's `pool-split = 0` stays.
/// `env.MADEIRA_JIT_POOL_AUTO = 0` turns this off.
enum JITPoolAuto {
    static let lines: [(key: String, value: String)] = [("pool-split", "1"), ("env.MADEIRA_X64_IMAGE_NOCOPY", "1")]

    /// The lines `text` does not set yet.
    static func missing(_ text: String) -> [(key: String, value: String)] {
        let values = GameProfile.parse(text)
        return lines.filter { values[$0.key] == nil }
    }

    /// `text` with the missing lines added, or nil when nothing is missing.
    static func added(to text: String) -> String? {
        let add = missing(text)
        guard !add.isEmpty else { return nil }
        var out = text
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        out += "# Added by Madeira: this game ran out of JIT memory\n"
        out += add.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"
        return out
    }

    /// Adds the missing lines to the game's config. Returns true when it changed it.
    static func apply(windowsPath: String, title: String) -> Bool {
        guard MadeiraConfig.flag("MADEIRA_JIT_POOL_AUTO") else {
            LogStore.shared.log("[jit-pool-auto] \(title): ran out of JIT memory; automatic settings are off (MADEIRA_JIT_POOL_AUTO=0)")
            return false
        }
        let file = GameProfile(windowsPath: windowsPath)
        let text = file.text
        guard let out = added(to: text) else {
            LogStore.shared.log("[jit-pool-auto] \(title): ran out of JIT memory; its config already sets pool-split and MADEIRA_X64_IMAGE_NOCOPY")
            return false
        }
        let keys = missing(text).map(\.key).joined(separator: ", ")
        file.text = out
        guard file.text == out else {
            LogStore.shared.log("[jit-pool-auto] \(title): could not write its config", level: .error)
            return false
        }
        LogStore.shared.log("[jit-pool-auto] \(title): ran out of JIT memory; added \(keys) to its config for the next start")
        return true
    }

    /// The starting screen's words when the pool ran out before the game came up
    /// (LibraryModel.poolRestartNote). `added`: this start added the lines; otherwise the
    /// config already had them (or MADEIRA_JIT_POOL_AUTO=0) and a fresh run may still get
    /// a bigger pool from iPadOS.
    static var startHeadline: String { L("Not enough memory") }
    static func startMessage(_ title: String, added: Bool) -> String {
        added
            ? String(format: L("%@ ran out of JIT memory, so Madeira gave it bigger memory settings. Tap Close Madeira (the round arrow below), then open Madeira again: %@ starts by itself."), title, title)
            : String(format: L("%@ ran out of JIT memory. Tap Close Madeira (the round arrow below), then open Madeira again; that often gives more memory, and %@ starts by itself."), title, title)
    }

    /// The alert after the session.
    static func message(_ title: String) -> String {
        "\(title) ran out of JIT memory, so Madeira gave it bigger JIT memory settings. To use them, close Madeira (swipe it away in the app switcher), open it again and start \(title)."
    }
}
