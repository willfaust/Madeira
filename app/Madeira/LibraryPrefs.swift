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

    /// "Graphics card the game sees": a GPUCards id, nil for no choice.
    static func gpuCard(_ windowsPath: String) -> String? { (dict(gpuCardKey) as [String: String])[windowsPath] }
    static func setGPUCard(_ id: String?, for windowsPath: String) { store(id.flatMap { $0.isEmpty ? nil : $0 }, gpuCardKey, windowsPath) }

    /// "Pause threads fully" (BCDLaunch.realSuspend): nil is Automatic, true On, false Off.
    static func realSuspend(_ windowsPath: String) -> Bool? { (dict(realSuspendKey) as [String: Bool])[windowsPath] }
    static func setRealSuspend(_ on: Bool?, for windowsPath: String) { store(on, realSuspendKey, windowsPath) }

    /// FNV-1a over a string: stable across launches, unlike String.hashValue.
    /// Names a game's config file (GameProfiles.swift) and fingerprints the
    /// recommended settings Madeira wrote (GameRecommendationsApply.swift).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
