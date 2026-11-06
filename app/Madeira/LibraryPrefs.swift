//
//  LibraryPrefs.swift
//  Madeira
//
//  madeira-bcd: a game's own launch switches, kept by its Windows path (AVX,
//  Report an NVIDIA GPU, Wine's C++ runtime), which every launch of the game
//  exports (BCDLaunch, LibraryBCD.swift).
//

import Foundation

/// Per-title launch switches that are not command-line arguments, keyed by
/// the game's Windows path.
enum LibraryPrefs {
    private static let avxKey = "madeira.library.avx"
    private static let vcrtKey = "madeira.library.wineVCRT"
    private static let nvidiaKey = "madeira.library.nvidia"
    private static let olderNvidiaKey = "madeira.library.olderNvidia"
    private static let realSuspendKey = "madeira.library.realSuspend"
    private static let gpuCardKey = "madeira.library.gpuCard"
    private static let japaneseKey = "madeira.library.japanese"

    private static func dict<T>(_ key: String) -> [String: T] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: T]) ?? [:]
    }

    private static func store<T>(_ value: T?, _ key: String, _ field: String) {
        var all: [String: T] = dict(key)
        all[field] = value
        UserDefaults.standard.set(all, forKey: key)
    }

    static func avx(_ windowsPath: String) -> Bool { (dict(avxKey) as [String: Bool])[windowsPath] ?? false }
    static func setAVX(_ on: Bool, for windowsPath: String) { store(on ? true : nil, avxKey, windowsPath) }

    static func wineVCRT(_ windowsPath: String) -> Bool { (dict(vcrtKey) as [String: Bool])[windowsPath] ?? false }
    static func setWineVCRT(_ on: Bool, for windowsPath: String) { store(on ? true : nil, vcrtKey, windowsPath) }

    static func nvidia(_ windowsPath: String) -> Bool { (dict(nvidiaKey) as [String: Bool])[windowsPath] ?? false }
    static func setNvidia(_ on: Bool, for windowsPath: String) { store(on ? true : nil, nvidiaKey, windowsPath) }

    /// "Older NVIDIA card (Direct3D 9)": D3D9 names a GeForce 7900 GS (D3D9Identity).
    static func olderNvidia(_ windowsPath: String) -> Bool { (dict(olderNvidiaKey) as [String: Bool])[windowsPath] ?? false }
    static func setOlderNvidia(_ on: Bool, for windowsPath: String) { store(on ? true : nil, olderNvidiaKey, windowsPath) }

    /// "Japanese locale": Wine runs the game with a Japanese system locale (code page 932)
    /// and a Japanese font (MADEIRA_JAPANESE, WineProcessBridge.m madeira_japanese_prefix).
    static func japanese(_ windowsPath: String) -> Bool { (dict(japaneseKey) as [String: Bool])[windowsPath] ?? false }
    static func setJapanese(_ on: Bool, for windowsPath: String) { store(on ? true : nil, japaneseKey, windowsPath) }

    /// "Graphics card the game sees": a GPUCards id, nil for no choice.
    static func gpuCard(_ windowsPath: String) -> String? { (dict(gpuCardKey) as [String: String])[windowsPath] }
    static func setGPUCard(_ id: String?, for windowsPath: String) { store(id.flatMap { $0.isEmpty ? nil : $0 }, gpuCardKey, windowsPath) }

    /// "Pause threads fully" (BCDLaunch.realSuspend): nil is Automatic, true On, false Off.
    static func realSuspend(_ windowsPath: String) -> Bool? { (dict(realSuspendKey) as [String: Bool])[windowsPath] }
    static func setRealSuspend(_ on: Bool?, for windowsPath: String) { store(on, realSuspendKey, windowsPath) }

    /// The switches a shared setup carries (GameSetupShare.swift), by name; a switch
    /// that is off or unset is left out.
    static func sharedSwitches(_ windowsPath: String) -> [String: Any] {
        var out: [String: Any] = [:]
        if avx(windowsPath) { out["avx"] = true }
        if wineVCRT(windowsPath) { out["wineVCRT"] = true }
        if nvidia(windowsPath) { out["nvidia"] = true }
        if olderNvidia(windowsPath) { out["olderNvidia"] = true }
        if japanese(windowsPath) { out["japanese"] = true }
        if let suspend = realSuspend(windowsPath) { out["realSuspend"] = suspend }
        return out
    }

    /// A shared setup's switches replace the game's: one the setup leaves out is off.
    static func applySharedSwitches(_ switches: [String: Any], for windowsPath: String) {
        setAVX(switches["avx"] as? Bool ?? false, for: windowsPath)
        setWineVCRT(switches["wineVCRT"] as? Bool ?? false, for: windowsPath)
        setNvidia(switches["nvidia"] as? Bool ?? false, for: windowsPath)
        setOlderNvidia(switches["olderNvidia"] as? Bool ?? false, for: windowsPath)
        setJapanese(switches["japanese"] as? Bool ?? false, for: windowsPath)
        setRealSuspend(switches["realSuspend"] as? Bool, for: windowsPath)
    }

    /// FNV-1a over a string: stable across launches, unlike String.hashValue.
    /// Names a game's config file (GameProfiles.swift) and fingerprints the
    /// recommended settings Madeira wrote (GameRecommendationsApply.swift).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
