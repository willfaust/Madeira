//
//  GameRecommendations.swift
//  Madeira
//
//  madeira-bcd: the settings Madeira recommends for the games it has been
//  tested with, shipped in the app (owner's decision, 2026-10-09).
//
//  A recommendation is the game's own config file (GameProfiles.swift,
//  madeira.cfg syntax) plus the switches the game's settings page keeps
//  elsewhere: AVX, Report an NVIDIA GPU, Wine's C++ runtime, the fastsync
//  switches, the FPS limit, the resolution and the scaling. A game that
//  arrives with no config of its own gets its recommendation once (a Steam
//  install, a game added by hand, a game already in the library);
//  "Reset to Recommended" at the bottom of its settings brings it back at
//  any time (GameRecommendationsApply.swift).
//
//  How a game is recognised:
//    - A library Steam game by its App ID or by its folder under
//      steamapps\common, which Steam keeps the same from build to build.
//    - A program by its file name, wherever it was installed; only the
//      game's own programs count, not a redistributable in its folder.
//    - GTA V Enhanced by PlayGTAV.exe (or GTA5_Enhanced.exe) beside
//      GTA5_Enhanced.exe: inside a Steam library it is the Steam copy,
//      anywhere else a copy from outside Steam (Rockstar Games Launcher or
//      another store), and each has its own list. Red Dead Redemption 2's
//      RDR2.exe and PlayRDR2.exe the same way.
//    - GTA V Legacy: App ID 271590, the folder "Grand Theft Auto V",
//      GTA5.exe, or PlayGTAV.exe beside GTA5.exe and without
//      GTA5_Enhanced.exe (Enhanced is checked first); inside a Steam library
//      the Steam copy, anywhere else the list for outside Steam.
//    - The Rockstar Games Launcher outside Steam: Launcher.exe in a
//      "Rockstar Games\Launcher" folder, and its installer
//      Rockstar-Games-Launcher.exe, wherever it was downloaded.
//    - The Steam titles of `steamTitles` (merged 2026-10-26): their App IDs,
//      their folders under steamapps\common and their own programs; a
//      program marked Steam-only names the game only inside a Steam library.
//    - Any other game, and the Desktop, gets the standard list (owner's
//      decisions, 2026-10-12; GameRecommendationsApply.swift).
//
//  This file is Foundation only: tests/host/check-game-recommendations.py
//  compiles it with a test harness. The lists are the working ones recorded
//  in the private notes (OYUN-AYARLARI); a game that gets a newer working
//  list gets it here too, with a higher `version` (with every build, owner's
//  order 2026-10-09).
//

import Foundation

/// The recommended setup of one game. A switch left nil is not touched.
struct GameRecommendation: Equatable {
    /// Stable identity ("rdr2-steam"); the record of what was applied keys on it.
    let id: String
    /// Shown under "Reset to Recommended".
    let title: String
    /// Raised whenever `config` or a switch changes.
    let version: Int
    /// The game's own config file, madeira.cfg syntax.
    let config: String
    var avx: Bool? = nil
    var nvidia: Bool? = nil
    /// Game details › Older NVIDIA card (Direct3D 9) (LibraryBCD.swift, D3D9Identity).
    var olderNvidia: Bool? = nil
    var wineVCRT: Bool? = nil
    /// Game details › Fast synchronization (LibraryEntry.fastSync).
    var fastSync: Bool? = nil
    /// Game details › Fast semaphore waits (LibraryEntry.semaphoreFastPath).
    var semaphoreFastPath: Bool? = nil
    /// LibraryEntry.fpsMode: 1 = 60, 3 = 30, 4 = 40, 0 = display maximum, 2 = uncapped.
    var fpsMode: Int? = nil
    /// "WxH", or `GameRecommendation.screen720`. nil keeps the device's own
    /// default, which is what the lists recorded as 1408x648 were on a 19.5:9 iPhone.
    var resolution: String? = nil
    /// `resolution`: this screen's shape at 720 lines (ResolutionChoices.screen720,
    /// 1568x720 on a 19.5:9 iPhone), for games that offer full screen only at 720
    /// lines or more. A screen whose default already has them keeps its default.
    static let screen720 = "screen@720"
    /// Aspect & scaling (DisplayMode raw value); "fit" is the default.
    var display: String? = nil
    /// Game details › Launch › Start (LibraryEntry.launchMode): "desktop", the Wine desktop.
    var launchMode: String? = nil
    /// Game details › Launch › Start Windows services first (LibraryEntry.startServices).
    var startServices: Bool? = nil

    /// Lines only a device with less than 12 GB of RAM gets, after `config`
    /// (GameRecommendations.smallRAMDevice). nil: every device gets the same list.
    var smallRAMConfig: String? = nil

    /// The config file's text as GameProfile stores it (one trailing newline): `config`,
    /// and on a device with less than 12 GB of RAM `smallRAMConfig` after it.
    var fileText: String {
        var text = config.hasSuffix("\n") ? config : config + "\n"
        if let extra = smallRAMConfig, GameRecommendations.smallRAMDevice {
            text += extra.hasSuffix("\n") ? extra : extra + "\n"
        }
        return text
    }

    /// A short list of the switches it sets, for Game details.
    var switchSummary: String {
        var parts: [String] = []
        if let avx { parts.append("AVX \(avx ? "on" : "off")") }
        if let nvidia { parts.append("NVIDIA \(nvidia ? "on" : "off")") }
        if let olderNvidia { parts.append("older NVIDIA card \(olderNvidia ? "on" : "off")") }
        if let wineVCRT { parts.append("Wine's C++ runtime \(wineVCRT ? "on" : "off")") }
        if fastSync == false { parts.append("fast synchronization off") }
        if let semaphoreFastPath { parts.append("fast semaphore waits \(semaphoreFastPath ? "on" : "off")") }
        if let fpsMode {
            let label = [1: "60", 3: "30", 4: "40", 0: "display maximum", 2: "uncapped"][fpsMode] ?? "\(fpsMode)"
            parts.append("FPS limit \(label)")
        }
        if let resolution { parts.append(resolution == Self.screen720 ? "this screen's shape at 720 lines" : resolution) }
        if launchMode == "desktop" { parts.append("starts in the Wine desktop") }
        if startServices == true { parts.append("Windows services first") }
        return parts.joined(separator: ", ")
    }
}

enum GameRecommendations {
    // MARK: The device

    /// Installed RAM (hw.memsize): a 12 GB iPhone reports 11,695 MB, an 8 GB one
    /// about 7,500 MB. A variable so the host test can try both.
    static var deviceRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// An 8 GB (or smaller) device: under 10 GB installed. It gets a list's
    /// `smallRAMConfig`; a 12 GB phone or a 16 GB iPad does not.
    static var smallRAMDevice: Bool { deviceRAMBytes < 10 << 30 }

    // MARK: The lists

    /// Red Dead Redemption 2 from Steam, through Madeira Dock: the build 463
    /// list, plus build 466's memory and ExecuteIndirect switches, the DXGI
    /// monitor identity and mode list for Borderless / Full Screen (which no
    /// longer crash, 2026-10-09 11:34), build 467's full-screen window and
    /// 720-line screen, the least RDR2 offers in full screen (which fits the
    /// screen, 13:09), build 470's test: the swap file also takes the 1-4 MB
    /// blocks (the game still reached the 8 GB limit a minute into play), and
    /// build 472's pool-mid: a mapping between the pool's two regions at image
    /// load cut the pool to 604 MB and the game stopped with ERR_GFX_INIT (14:33);
    /// and ring-share: on build 470 (14:48) the argument-buffer chunks grew to
    /// 1.5 GB of the 3.6 GB Metal held in play; and build 476's test: the x64
    /// program files (libcef.dll 228 MB, steamclient64.dll, the launcher, the
    /// game) move to the swap file once read, the launcher's and Social Club's
    /// DXMT upload rings take 4 MB blocks instead of 32 MB (they held 200 MB
    /// through play on 467), and the ExecuteIndirect probe is off (on 470 it
    /// split render passes every 3 s per pipeline for the first two minutes);
    /// and build 480's: on 476 the game loaded xinput1_4.dll only at its first
    /// controller read, when the launcher's, Social Club's and the game's
    /// 128 MB code buffers had left the JIT pool no room for it, so neither the
    /// controller nor the on-screen controls reached the game; the DLL is now
    /// loaded with the D3D12 device. Build 479 also kept 192 MB of the pool for
    /// DLLs: the game's code buffer then got 16 MB and was refilled again and
    /// again (2-3 FPS, 19:35), so the pool is back to 128 MB. The orphan-lock
    /// reaper releases only locks a live thread has stamped (it released live
    /// locks: three "is not owned" errors on 476). Version 10 (build 514,
    /// 2026-10-12): the first install's VC++ setup may not start its elevated
    /// engine (.be\vc_redist), which crashed with a lock held while the setup
    /// waited for it forever (12:43). With the line the setup fails at once and
    /// the installs pass (12:57); the session links its own VC++ DLLs anyway.
    static let rdr2Steam = GameRecommendation(
        id: "rdr2-steam", title: "Red Dead Redemption 2 (Steam)", version: 10,
        config: """
        # Madeira's recommended settings for Red Dead Redemption 2 (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-shader-pack = 1
        replay-split = 1
        ring-share = 1
        pool-low = 1
        pool-mid = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 2304
        swap-mb = 8192
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        pso-warm = 2
        fence-chain = 6
        avail-phys = 1
        indirect-fast = 1
        ind-probe = 0
        fullscreen-window = 1
        env.WINE_D3D_CONFIG = renderer=no3d
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_BAND_CENSUS = 1
        env.MADEIRA_RDR2_VA_HOLD = 1
        env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
        env.MADEIRA_THREAD_STACK_SPILL = 1
        env.MADEIRA_SMALL_STACK_EXES = RDR2.exe
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;RDR2.exe
        env.MADEIRA_DXGI_BUDGET_EVENTS = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_PRELOAD_DLLS = xinput1_4.dll
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_METAL_HUD_MAIN = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: GameRecommendation.screen720, display: "fit")

    /// Red Dead Redemption 2 started from its own RDR2.exe or PlayRDR2.exe outside
    /// a Steam library (Rockstar Games Launcher or another store; owner's request,
    /// 2026-10-12). Derived from the Steam copy's list and not device-tested on
    /// its own: the Steam list, whose lines are the game's own (its 8960 MB
    /// reservation, the JIT pool, the swap file, the controller DLL, the
    /// launcher's and Social Club's rings), without the two only Madeira Dock
    /// reads when Steam starts the game (the service manager and the programs
    /// that keep that session alive), plus the line GTA V Enhanced's list outside
    /// Steam starts with: the [ec-hook] reporter off.
    static let rdr2Other = GameRecommendation(
        id: "rdr2-other", title: "Red Dead Redemption 2 (outside Steam)", version: 1,
        config: """
        # Madeira's recommended settings for Red Dead Redemption 2 outside Steam (Rockstar Games Launcher or another store).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-shader-pack = 1
        replay-split = 1
        ring-share = 1
        pool-low = 1
        pool-mid = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 2304
        swap-mb = 8192
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        pso-warm = 2
        fence-chain = 6
        avail-phys = 1
        indirect-fast = 1
        ind-probe = 0
        fullscreen-window = 1
        env.WINE_D3D_CONFIG = renderer=no3d
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_BAND_CENSUS = 1
        env.MADEIRA_RDR2_VA_HOLD = 1
        env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
        env.MADEIRA_THREAD_STACK_SPILL = 1
        env.MADEIRA_SMALL_STACK_EXES = RDR2.exe
        env.MADEIRA_DXGI_BUDGET_EVENTS = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_PRELOAD_DLLS = xinput1_4.dll
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_METAL_HUD_MAIN = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: GameRecommendation.screen720, display: "fit")

    /// GTA V Enhanced from Steam, through Madeira Dock (build 456: 18 minutes
    /// idle and 19 minutes of fast driving without a crash, 33-40 FPS at 40).
    /// Version 2 (2026-10-12): the orphan-lock reaper releases only locks a live
    /// thread has stamped, as for RDR2 and Horizon Zero Dawn. Its default mode
    /// released a busy lock in SocialClubHelper.exe while the owner lived; the
    /// helper died at Story Mode and the launcher's window stayed grey (log
    /// 10:53, after a reset and a new Rockstar sign-in). Version 3: the first
    /// install's VC++ setup may not start its elevated engine, as for RDR2
    /// (with the line GTA's installs passed, 13:08). Version 4 (2026-10-26): new
    /// pipelines are built off the render thread (pso-async); 252 of them held it
    /// for 12 s in two minutes of driving and the game fell to 3-15 FPS. Version 5
    /// (2026-10-26 late): compiled pipelines kept in archives of our own (pso-archive):
    /// Metal's cache had 6,904 of 6,986 in one session and 19 of the first 500 in the
    /// next, which froze for seconds at a time while they compiled again. Version 6
    /// (2026-10-28, log 97, an 8 GB phone): Metal grew from 540 MB to 2.1 GB in ten
    /// minutes and took the footprint to the 6 GB limit while the rest stayed flat.
    /// 356 MB of it was argument-ring chunks lists kept, so lists share them
    /// (ring-share, as RDR2's list since its version 6); and the video budget never
    /// fell below what the game used (2.6 GB at the end), so on a device with less
    /// than 12 GB of RAM its trim starts earlier (`gta5EnhancedSmallRAMLines`).
    /// Version 7 (log 98): that trim started too early; see `gta5EnhancedSmallRAMLines`.
    /// Version 9 (logs 103-106, an 8 GB phone): the memory guard in
    /// `gta5EnhancedSmallRAMLines`. Version 8 also set semaphores on fastsync's cells and
    /// lean diagnostics; with them the game's loading stalled at its first screen and the
    /// launcher sometimes never came up (logs 104-106), so version 9 has version 7's lines.
    /// Version 10 (log 107, an iPhone 17): the FPS limit is 30, not 40. The menus held 40
    /// at 2-2.9 W, and after ~330 J of the process's CPU energy iOS clamped the cores to
    /// 1.31 / 1.70 GHz for the rest of the session, before gameplay started (13-25 FPS).
    static let gta5EnhancedSteam = GameRecommendation(
        id: "gta5e-steam", title: "GTA V Enhanced (Steam)", version: 10,
        config: """
        # Madeira's recommended settings for GTA V Enhanced (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-core-dll = 1
        d3d12-msaa8 = 1
        d3d12-tile-based = 0
        d3d12-tiled-resources = 1
        d3d12-typed-uav-load = 1
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 4096
        swap-mb = 3072
        pso-warm = 2
        pso-async = 1
        pso-archive = 1
        ring-share = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5_Enhanced.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_PAD_MODE = hid
        env.MADEIRA_METAL_HUD_MAIN = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 3,
        display: "fit", smallRAMConfig: gta5EnhancedSmallRAMLines)

    /// GTA V Enhanced on a device with less than 12 GB of RAM (log 97: limit 6136 MB,
    /// the rest of the footprint ~4 GB). The video budget shrinks 1:1 with the
    /// footprint above (limit - vram-trim-mb). Log 98 (3584): with shared rings Metal
    /// stayed at 1.3-1.6 GB, and from a ~5.4 GB footprint the budget (1.0-1.3 GB) sat
    /// below it. The usage the game is shown is Metal's whole allocation, ~600 MB of
    /// which (pipelines and our own buffers) it cannot free; it shed only ~90 MB of
    /// textures, then stopped streaming (no disk reads, one thread yielding ~34k/s)
    /// and froze for tens of seconds at a time. From 2560 below the limit the budget
    /// stays above 2 GB up to a 5.5 GB footprint and reaches what Metal holds only
    /// near the kill line. Log 103: the phone itself ran out of RAM (host free ~100 MB
    /// for minutes, 6 GB of the app compressed, the donor pool at 3.6 GB) and the
    /// session was killed under critical pressure. With donor-pool-guard = 1 a
    /// critical-pressure notification sends the 64-bit title's new memory to the swap
    /// file, which the kernel can page out, instead of more donated RAM.
    static let gta5EnhancedSmallRAMLines = "vram-trim-mb = 2560\ndonor-pool-guard = 1"

    /// GTA V Legacy from Steam (App ID 271590, DirectX 11 through DXMT): the
    /// Enhanced list without its D3D12 lines and its DualSense mode (Legacy takes
    /// XInput only), the Dock keeping Launcher.exe and GTA5.exe, and DXMT's display
    /// mode table and monitor identity. On community build 547 (2026-10-15,
    /// log GTA5.exe 13:37:35, a 12 GB iPhone) it played Story Mode into the city
    /// at 38-60 FPS, after the airconv geometry-shader fix (willfaust/dxmt). With
    /// vram-mb = 4096 and swap-mb = 3072 the first try had sudden drops and
    /// stalls; without them it ran smoothly (the DXGI budget then is the default
    /// 1536 MB). A device with less than 12 GB of RAM still gets the 3 GB RAM
    /// swap (`smallRAMConfig`); a 12 GB phone or a 16 GB iPad does not. A copy
    /// from outside Steam (Epic, Rockstar's store) gets `gta5LegacyOther`.
    static let gta5LegacySteam = GameRecommendation(
        id: "gta5l-steam", title: "GTA V Legacy (Steam)", version: 1,
        config: """
        # Madeira's recommended settings for GTA V Legacy (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_METAL_HUD_MAIN = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 4,
        display: "fit", smallRAMConfig: smallRAMSwapLines)

    /// GTA V Legacy started from its own GTA5.exe, or PlayGTAV.exe beside it,
    /// outside a Steam library (Epic, Rockstar's store; merged 2026-10-26 from
    /// a community list for it). The Steam list without the two lines only
    /// Madeira Dock reads when Steam starts the game (the service manager and
    /// the programs that keep that session alive), the same switches and the
    /// same 3 GB RAM swap under 12 GB of RAM. Not device-tested here.
    static let gta5LegacyOther = GameRecommendation(
        id: "gta5l-other", title: "GTA V Legacy (outside Steam)", version: 1,
        config: """
        # Madeira's recommended settings for GTA V Legacy (outside Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_METAL_HUD_MAIN = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 4,
        display: "fit", smallRAMConfig: smallRAMSwapLines)

    /// Grand Theft Auto IV from Steam (App ID 12210, the Complete Edition): a
    /// 32-bit game behind the same publisher launcher as GTA V (PlayGTAIV.exe
    /// starts Launcher.exe, which starts GTAIV.exe), so it takes the launcher
    /// chain's lines from the GTA V Legacy list and none of GTA V's graphics
    /// lines: the service manager in the Dock session, the Dock holding the
    /// session for Launcher.exe and GTAIV.exe, pure-x64 images uncopied, the
    /// browser helper's address-space layout, the crash handler and the
    /// vc_redist re-run refused, and the emulator's code buffers below the
    /// window (pool-low). Logs of 2026-10-24 (vk-1024-4): without pool-low the
    /// chain's eleven pseudo-processes held 423 MB of a 567 MB JIT pool in DLL
    /// copies, the helper's renderer thread got a 16 MB code buffer and
    /// recompiled four million blocks while the sign-in page never painted. A
    /// 32-bit game also needs its 4 GB guest window late in the session, when
    /// the helper's reservations have taken most of the map: 2 GB of margin
    /// instead of 8. Version 2 (logs 66–70, 2026-10-25): the chain and the
    /// game together pass the 6 GB jetsam limit, so the swap tier is on with
    /// donated RAM (donor-pool-mb) as its first stage and the file behind it,
    /// broad coverage from 1 MB; the game's own memory takes donated RAM but
    /// never the file (swap-wow64's default: on the file its heap froze the
    /// game for seconds at a time). The display link is held at the panel's
    /// maximum (MADEIRA_PROMOTE) while the frame-rate sag is diagnosed. Played
    /// through to driving; from Steam only. Version 3 (2026-10-26, from a
    /// community list for the same launcher chain): AVX off. With AVX on in the
    /// publisher launcher's process but not in its service, the launcher cannot
    /// connect to the service (the community GTA V and RDR2 logs). The Social Club
    /// browser's address-space layout (MADEIRA_SC_PA_POOLS = 2) was already here.
    static let gta4Steam = GameRecommendation(
        id: "gta4-steam", title: "Grand Theft Auto IV (Steam)", version: 3,
        config: """
        # Madeira's recommended settings for Grand Theft Auto IV (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        swap-mb = 4096
        swap-min-mb = 1
        env.MADEIRA_SWAP_COVERAGE = broad
        donor-pool-mb = 4096
        env.MADEIRA_PROMOTE = 1
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTAIV.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist;syswow64\\dllhost
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, fastSync: true, semaphoreFastPath: true, display: "fit")

    /// GTA V Enhanced started from its own PlayGTAV.exe outside a Steam
    /// library (Rockstar Games Launcher or another store; build 451). Version 2:
    /// the same orphan-lock reaper mode as the Steam copy (its launcher and
    /// Social Club too). Version 3: pipelines built off the render thread, as
    /// for the Steam copy. Version 4: the pipeline archive, as for the Steam copy.
    /// Version 5: shared argument-ring chunks and, under 12 GB of RAM, the earlier
    /// video-budget trim, as for the Steam copy. Version 6: that trim later, as for
    /// the Steam copy's version 7. Version 8: the memory guard, as for the Steam copy's
    /// version 9 (version 7 also had lean diagnostics). Version 9 (2026-10-28, for an
    /// Epic copy): the Steam copy's version 10 without its Steam and Dock lines: the swap
    /// file, the pool and image lines, pipeline warm-up, BattlEye off for PlayGTAV.exe,
    /// the error handler and vc_redist blocked, a 30 FPS limit and the semaphore fast
    /// path switch. MADEIRA_FASTSYNC_SEM is gone (with it the Steam copy's loading
    /// stalled at its first screen, logs 104-106). Version 10 (ml2280, testers' log of
    /// 2026-10-28): it starts in the Wine desktop. The Epic copy's first start runs the
    /// Rockstar Games Launcher installer, whose service needs services.exe; started directly,
    /// the session is the game's (ARM64EC), where that aarch64 program cannot run. In the
    /// desktop sechost starts it on demand, as for the launcher's own list (no services
    /// batch: it would write the Epic sign-in arguments to disk).
    static let gta5EnhancedOther = GameRecommendation(
        id: "gta5e-other", title: "GTA V Enhanced (outside Steam)", version: 10,
        config: """
        # Madeira's recommended settings for GTA V Enhanced outside Steam (Rockstar Games Launcher or another store).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-core-dll = 1
        d3d12-msaa8 = 1
        d3d12-tile-based = 0
        d3d12-tiled-resources = 1
        d3d12-typed-uav-load = 1
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 4096
        swap-mb = 3072
        pso-warm = 2
        pso-async = 1
        pso-archive = 1
        ring-share = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_PAD_MODE = hid
        env.MADEIRA_METAL_HUD_MAIN = 1
        env.SteamDeck = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 3,
        resolution: "1280x720", display: "fit", launchMode: "desktop", smallRAMConfig: gta5EnhancedSmallRAMLines)

    /// Ghost of Tsushima (build 336: DualSense input, rumble, triggers and light work).
    /// Build 492 adds Horizon Zero Dawn's proven fix for typed buffer views that
    /// start off a 16-byte boundary: the GPU reads such a texture from its start
    /// rounded down, so the shader saw data shifted by a few elements in the frames
    /// where a view landed there (HZD: walls, trees and plants missing for one
    /// frame). GoT's one-frame "shapes in the air" are the same kind of fault.
    /// view-census counts such views, so its first run shows whether GoT makes any.
    /// Version 3 (build 515, 2026-10-12, the owner's working list): the [ec-hook]
    /// reporter is off (on 515 it ended the game at start, reading steam_api64.dll's
    /// protected sections), the swap file holds 4 GB, and a new thread's stacks may
    /// take the kernel's pick once Wine's band is full (a thread the game could not
    /// create froze it in a cutscene, 15:39). With the game's own graphics at their
    /// lowest it stays under the memory limit on an iPhone 17 Pro Max.
    static let ghostOfTsushima = GameRecommendation(
        id: "ghost-of-tsushima", title: "Ghost of Tsushima", version: 3,
        config: """
        # Madeira's recommended settings for Ghost of Tsushima.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        dxil-tess = 0
        sampler-reduction = 3
        ind-count = 6000
        typed-view-align = 16
        typed-view-shadow = 1
        view-census = 1
        env.MADEIRA_PAD_MODE = hid
        swap-mb = 4096
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_THREAD_STACK_SPILL = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: "1280x720", display: "fit")

    /// God of War (2018) (build 335: 1080p, DualSense input).
    static let godOfWar = GameRecommendation(
        id: "god-of-war", title: "God of War", version: 1,
        config: """
        # Madeira's recommended settings for God of War.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        dxmt = d3d11.mipClampBC=2
        swap-mb = 6144
        swap-min-kb = 1024
        env.WINEDEBUG = err+all,err-virtual,fixme-all
        env.MADEIRA_PAD_MODE = hid
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: "1920x1080", display: "fit")

    /// Horizon Zero Dawn (Complete Edition, GOG or Steam), still being brought
    /// up: the list for build 471's test. Its shaders keep their constant
    /// buffers, samplers and textures in register spaces 6 and 8, which build
    /// 466 refused (the game then crashed); MFC ships with build 468. Build 469
    /// drew the first frame and hung (a pipeline without a pixel shader, fixed
    /// in 471); DXGI now lists the virtual monitor's own modes, as user32 does,
    /// so the game can pick this screen's resolution. Build 471 reached the
    /// language menu at 56 FPS with no input at all: no window was foreground,
    /// so its raw keyboard and mouse input went nowhere, and it reads its pad
    /// only through Windows.Gaming.Input; build 475's two switches cover both.
    /// On build 475 (2026-10-09 16:20) the game played for seven minutes, then
    /// stopped with an "Error" box when its settings menu was refused a
    /// pipeline: the converter refused ~4,900 of its shaders with code 4 (they
    /// read a "t4-unbounded" range), each of them again for every pipeline.
    /// Build 477's switches retry those with sized ranges, remember what stays
    /// refused, and hand the game a placeholder instead of a failure; Wine's
    /// "controller_get_User stub" line (12,747 of them, the game asks every
    /// frame) is silenced. On build 479 (19:44) the retried shaders converted,
    /// but the game stopped with "Error" at start: the orphan-lock reaper had
    /// released two locks whose owners were alive (one on 475 too). Build 480's
    /// line lets it release only locks a live thread has stamped. On build 480
    /// (20:28) the game reached play, and iOS closed it two seconds in at
    /// 8,189 MB: in its menu it had created 52,570 pipelines, and their 23,045
    /// shader libraries stayed in memory although a few thousand are drawn; the
    /// image was corrupted from the first gameplay frame, when the game began to
    /// clear rectangles of its targets and the whole targets were cleared. Build
    /// 481's list lets a pipeline's libraries go until its first draw, clears only
    /// the rectangles, puts the game's memory in the swap file as Red Dead
    /// Redemption 2's list does (broad, from 1 MB), and leaves out pso-warm, whose
    /// queue held 24,570 pipelines (and their libraries) when the game closed.
    /// On build 481 (21:52, 21:55) the game played without closing, but its
    /// characters, which it skins in compute shaders, came out with missing
    /// faces, missing hair or collapsed to spikes every few frames, with
    /// gpu-sync = 1 as without it. Build 483's list adds two diagnostics:
    /// skin-check logs those draws, the dispatches that wrote their vertices and
    /// copies of the vertices themselves; view-census names buffer views that
    /// fall back or are cut short. d3d12-typed-uav-load = 1 changed nothing
    /// (481, 23:19). Build 484's list is one test of every candidate the
    /// research left at once, each its own line: the game reads OPTIONS1, so
    /// d3d12-wave-ops = 0 gives it shaders without wave intrinsics; raw and
    /// structured buffer views also carry a texture view (typed reads of them
    /// read zeros otherwise); R32 typed UAVs get ShaderAtomic; FEX orders vector
    /// and memcpy accesses as x86 does and ignores the volatile metadata of
    /// concrt140.dll and mfc140.dll. If the characters come out whole, the lines
    /// are halved to find the one that matters; skin-check stays on either way.
    /// None of them helped (484, 2026-10-10 07:32), so build 485's list drops
    /// them again. Its skinning dispatches gave the same vertex a different
    /// extreme depending on which of the game's two upload heaps the frame
    /// used, so the list now starts typed buffer views at the 16-byte boundary
    /// Apple's converter documents (a bone palette then has no padding
    /// elements), and skin-check traces whole frames, keeps the vertex shaders
    /// of meshes skinned there, dumps the compute skinning's data and compares
    /// what the GPU read with what the CPU had written. On build 485 (09:35)
    /// the characters came out whole: the dumped skinning matched a recompute
    /// vertex for vertex, and the GPU read exactly the CPU's bytes. Plants and
    /// lighting still flicker, and a small view two compute passes read every
    /// frame started 4 bytes past a 16-byte boundary in some frames, so build
    /// 486's list starts every typed view exactly at its first element where a
    /// probe shows the GPU reads such textures right, and drops the skinning
    /// diagnostics (view-census stays: it counts the views that keep an offset).
    /// On build 486 (11:52) nothing changed: the probe showed the GPU reads such
    /// a texture from its start rounded down to 16 bytes, and whole walls,
    /// trees and plants went missing for one frame every few seconds, at the
    /// moments the depth pyramid the game culls with read back near depths.
    /// Build 487's list gives typed views of upload memory that start off a
    /// 16-byte boundary an aligned copy of their bytes (typed-view-shadow),
    /// holds a queue's wait until the work it waits for is committed
    /// (fence-strict), and logs every frame's draws and the pyramid as the GPU
    /// wrote it (vis-trace). Build 489's list adds desc-guard, which logs the
    /// game rewriting a descriptor that a batch still running on the GPU uses
    /// (another one-frame cause: that draw reads another object's data).
    /// Build 490's list keeps the game's two 32 MB readback buffers, where the
    /// GPU writes the depth pyramid the CPU culls with, on Metal's own memory
    /// instead of the file-backed swap tier (readback-swap = 0); vis-trace now
    /// also compares every pyramid readback with the GPU's own copy. Build
    /// 491's list reads a table's single constant buffers when the draw is
    /// recorded, as NVIDIA's driver and vkd3d-proton do (static-cbv): with
    /// vkd3d-proton, Horizon Zero Dawn Remastered's foliage flicker stops when
    /// that is extended to every such constant buffer. On build 491 the game
    /// rendered without a fault (19:28). Two runs then showed what matters: the
    /// list without fence-strict, static-cbv, readback-swap and the trace
    /// diagnostics stayed clean (19:58), and without typed-view-shadow the
    /// vanishing came back (20:01). That list is version 15. Build 494's list
    /// (version 16) adds two lines for frame rate (493, 2026-10-11): our
    /// runtime's log lines no longer go through OutputDebugString, whose
    /// exception and server request cost ~0.5 ms a line, and the census frames
    /// that froze the game for 1.5-2 s every ~10 s in its first minutes are
    /// off (quiet-log); the server names the shader-cache files it opens with
    /// one call instead of realpath, which kept it busy on a performance core
    /// in the menu (MADEIRA_SRV_FGETPATH).
    static let horizonZeroDawn = GameRecommendation(
        id: "horizon-zero-dawn", title: "Horizon Zero Dawn", version: 16,
        config: """
        # Madeira's recommended settings for Horizon Zero Dawn.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        dxbc-register-spaces = 1
        msc-unbounded-retry = 1
        msc-fail-memo = 1
        pso-placeholder = 1
        pso-lazy-libs = 1
        clear-rects = 1
        typed-view-align = 16
        typed-view-shadow = 1
        view-census = 1
        quiet-log = 1
        swap-mb = 6144
        swap-mode = 2
        swap-min-mb = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.MADEIRA_INPUT_FOREGROUND = 1
        env.MADEIRA_WGI_HOST_PADS = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_SRV_FGETPATH = 1
        env.WINEDEBUG = fixme-input
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, display: "fit")

    /// Dark Souls: Remastered (tested on an iPhone Air, iOS 27.2, 2026-10).
    /// The game enumerates XInput only at start and never looks again (no
    /// device-arrival broadcast reaches it here), so player 1 is published from
    /// the first frame, and a player without controls of their own gets the Xbox
    /// layout. Without these the game runs but ignores the touch controller.
    /// The game's Arxan protection needs no dearxan: start-up also needs the image
    /// low-alias for steamclient64 (#385).
    static let darkSoulsRemastered = GameRecommendation(
        id: "dark-souls-remastered", title: "Dark Souls: Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Dark Souls: Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        # The game looks for a controller only when it starts: player 1 is there from the first frame.
        env.MADEIRA_PAD_EARLY_SLOT = 1
        env.MADEIRA_CONTROLS_XBOX_DEFAULT = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Dark Souls III (Steam; tested on an iPhone Air, iOS 27.2, 2026-10). Its JIT
    /// pool used to fill with the game's and Steam's image copies (the exe alone is
    /// 87 MB), so FEX's code buffer reset dozens of times a minute and combat ran at
    /// 3-11 fps: pool-split takes the pool past the main thread's stack (688 MB
    /// instead of 384-544) and MADEIRA_X64_IMAGE_NOCOPY runs the pure-x64 images in
    /// place. The orphan-lock reaper in its default mode released a live
    /// DynamicBuffer lock with three waiters, and two threads then crashed in DXMT;
    /// stamped reaps only locks of threads that are gone, as for Horizon Zero Dawn.
    /// The game looks for a controller only at start, as Dark Souls: Remastered.
    /// With these, combat holds 16-20 fps.
    static let darkSoulsIII = GameRecommendation(
        id: "dark-souls-iii", title: "Dark Souls III", version: 1,
        config: """
        # Madeira's recommended settings for Dark Souls III.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool-split = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PAD_EARLY_SLOT = 1
        env.MADEIRA_CONTROLS_XBOX_DEFAULT = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)
    /// Fallout: New Vegas (tested on an iPhone, 2026-10-26): loading a save crashed at
    /// 00B57AA9 right after the game built a face, on Madeira's own card name and
    /// driver, which give it the basic render path (Shader Package 2). "Older NVIDIA
    /// card (Direct3D 9)" reports the card and driver the game knows (Shader Package
    /// 13), as the d3d9.dll wrapper its players install does. The config is the
    /// standard list, which the game ran with.
    static let falloutNewVegas = GameRecommendation(
        id: "fallout-new-vegas", title: "Fallout: New Vegas", version: 1,
        config: """
        # Madeira's recommended settings for Fallout: New Vegas.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        olderNvidia: true)

    /// Fallout 3 and its Game of the Year Edition: New Vegas's engine, which picks
    /// its render path the same way. Not tested on a device yet.
    static let fallout3 = GameRecommendation(
        id: "fallout-3", title: "Fallout 3", version: 1,
        config: """
        # Madeira's recommended settings for Fallout 3 (not tested yet).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        olderNvidia: true)

    /// Call of Duty: Black Ops II, campaign (202970) and Zombies (212910), which
    /// share one folder; multiplayer (202990) lives there too. Build 26
    /// (2026-10-26): Zombies' sound crackled with the 60 ms default although the
    /// speaker was never short (the [ios_audio] ml1230 pacing lines), and 150 ms
    /// cleared it (owner's test, 2026-10-27). The standard list's line besides,
    /// which it ran with; not madeira-bcd's defaults, which it did not.
    static let blackOps2 = GameRecommendation(
        id: "black-ops-2", title: "Call of Duty: Black Ops II", version: 1,
        config: """
        # Madeira's recommended settings for Call of Duty: Black Ops II.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_AUDIO_LEAD_MS = 150
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)
    /// Horizon Forbidden West (Complete Edition, Steam 2420110), community builds
    /// 517-534 (2026-10-13/14). The game needs AVX. Memory it frees is released at
    /// once (with the free delay it reserved the same aligned addresses again and
    /// looped), and its programs run from their own image, which leaves the JIT pool
    /// room. Its memory goes to the swap file from 64 KB, and it sees a 3 GB
    /// video-memory budget with budget events (a smaller one left it on a black
    /// screen). Horizon Zero Dawn's typed-view alignment and aligned copies keep
    /// the image right (without the copies, vegetation shot into the sky); the
    /// copies need the 262,144-entry table and its fixed-cost refresh, and the
    /// game's float3 typed views a 16-byte-element copy (typed-view-rgb32).
    /// Render passes stay open across lists. mip0-full gives FSR 3's MipLevels 0
    /// pyramid its full chain: without it, frame generation showed black squares
    /// (build 533: gone). Our log lines skip OutputDebugString and the census
    /// frames; shader libraries wait for a pipeline's first draw; guest threads run
    /// at the efficiency QoS; the thread samplers are off and Wine's fixme lines are
    /// quiet. Played with FSR 3 frame generation on: 24 presents a second before
    /// mip0-full (build 531), 15 with it (533; its GPU cost is still open); the
    /// sound is robotic (env.MADEIRA_AUDIO_SPATIAL = 0 is the next try). Version 5, as
    /// ships it, without its own variant DXGI DLL (this dxgi.dll has the
    /// budget events).
    static let horizonForbiddenWest = GameRecommendation(
        id: "horizon-forbidden-west", title: "Horizon Forbidden West", version: 5,
        config: """
        # Madeira's recommended settings for Horizon Forbidden West.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        vram-mb = 3072
        swap-mb = 8192
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        typed-view-align = 16
        typed-view-shadow = 1
        typed-view-rgb32 = 1
        mip0-full = 1
        rp-carry = 1
        quiet-log = 1
        pso-lazy-libs = 1
        eco = 1
        env.MADEIRA_DXGI_BUDGET_EVENTS = 1
        env.MADEIRA_SWAP_MIN_KB = 64
        env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
        env.MADEIRA_INPUT_FOREGROUND = 1
        env.MADEIRA_WGI_HOST_PADS = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_SRV_FGETPATH = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_FREE_DELAY_MS = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_PAD_MODE = hid
        env.MADEIRA_LEAN_DIAG = 1
        env.WINEDEBUG = err+all,err-virtual,fixme-all
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: true, wineVCRT: false, fastSync: true, fpsMode: 3, display: "fit")

    /// Ratchet & Clank: Rift Apart (Steam 1895880), not yet seen past its intro
    /// video. Like the other Nixxes ports (Ghost of Tsushima, the Horizon games) it
    /// is a D3D12 game with DirectStorage, so its list is Horizon Forbidden West's
    /// general lines: AVX and an NVIDIA GPU reported, the swap file and video-memory
    /// budget, frees released at once, programs run from their own image (its 113
    /// MB program left a shrunken JIT pool), float3 typed views copied, MipLevels 0
    /// textures given their full chain, the frame-rate and quiet-log switches and the
    /// pad lines. Left out: Decima's typed-view alignment and copies, rp-carry, and
    /// eco. With it (community build 531, 2026-10-14, a tester's iPhone 15 Pro Max
    /// with 6 GB for the app) the game created its D3D12 device and swapchain and
    /// played the Bink intro, then thrashed memory there (footprint 3.3-4.1 GB with
    /// 1.1-2.2 GB compressed); a device with more memory should get further.
    /// Version 2 (2026-10-26, a community last known working list for it, its
    /// version 6: the game loaded a save and played on a 12 GB phone): a 2 GB
    /// video-memory budget and a 1 GB swap file; fence-early; MADEIRA_JUMBO_HALF
    /// (the game probes 8 GB for each 4 GB arena, and the fifth probe found no
    /// hole and the game called NULL), MADEIRA_CAGE_RELEASE (the guest band ran
    /// out while 8 GB sat in a holdback nothing here asks for), MADEIRA_ALIAS_RELEASE
    /// and MADEIRA_VA_PRESSURE_GAP_OK (loading a save releases and re-reserves
    /// the arenas at the same bases), and LC_ALL = en_US.UTF-8 (with the
    /// phone's Turkish locale the game threw an unhandled exception after loading
    /// code page 857). Left out: the community variant dxgi.dll switch.
    static let ratchetClankRiftApart = GameRecommendation(
        id: "ratchet-clank-rift-apart", title: "Ratchet & Clank: Rift Apart", version: 2,
        config: """
        # Madeira's recommended settings for Ratchet & Clank: Rift Apart.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        vram-mb = 2048
        swap-mb = 1024
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        typed-view-rgb32 = 1
        mip0-full = 1
        quiet-log = 1
        pso-lazy-libs = 1
        fence-early = 1
        env.MADEIRA_DXGI_BUDGET_EVENTS = 1
        env.MADEIRA_SWAP_MIN_KB = 64
        env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
        env.MADEIRA_INPUT_FOREGROUND = 1
        env.MADEIRA_WGI_HOST_PADS = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_SRV_FGETPATH = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_FREE_DELAY_MS = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_PAD_MODE = hid
        env.MADEIRA_LEAN_DIAG = 1
        env.MADEIRA_JUMBO_HALF = 1
        env.MADEIRA_CAGE_RELEASE = 1
        env.MADEIRA_ALIAS_RELEASE = 1
        env.LC_ALL = en_US.UTF-8
        env.WINEDEBUG = err+all,err-virtual,fixme-all
        env.MADEIRA_VA_PRESSURE_GAP_OK = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: true, wineVCRT: false, fastSync: true, fpsMode: 3, display: "fit")

    /// Crysis Remastered (Steam): community build 528, 2026-10-13 22:08, a tester:
    /// it ran perfectly. It ran with the standard list's line and
    /// every switch off (AVX, NVIDIA, Wine's C++ runtime, MetalFX) at 1408x648 Fit,
    /// 5.2 GB at most, and closed normally. Its own list keeps those switches and the
    /// defaults it was tested with when the standard list changes.
    static let crysisRemastered = GameRecommendation(
        id: "crysis-remastered", title: "Crysis Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Crysis Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Crysis 2 Remastered (Steam 2096600), not yet run with this list. On madeira
    /// build 540 (2026-10-14 23:54) it ran with the standard list and every switch off,
    /// and stopped at its first AVX instruction (c000001d, FEX "DISABLEAVX expected");
    /// the game needs AVX, on Windows too. Version 1: the standard line with AVX on,
    /// the other switches off, at Fit.
    static let crysis2Remastered = GameRecommendation(
        id: "crysis-2-remastered", title: "Crysis 2 Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Crysis 2 Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: false, wineVCRT: false, display: "fit")

    /// Crysis 3 Remastered (Steam 2096610). On community build 540 (2026-10-14
    /// 23:55) it ran with the standard list and every switch off, and stopped when
    /// msvcp140.dll branched to its own image base (c000001d on the MZ header).
    /// Version 1 turned Wine's C++ runtime on; it stopped the same way on build 547
    /// (2026-10-15 15:08:17): that switch does nothing in a Steam (Dock) session,
    /// and the DLL is Wine's ARM64EC msvcp140 (sysx64) all along. The game's Bin64
    /// ships Microsoft's x64 vcruntime140.dll, and Wine's msvcp140 cannot call its
    /// x64 memcpy (no exit thunk). Version 2: env.MADEIRA_APP_DLL_SHADOW =
    /// vcruntime140.dll makes the loader take Wine's vcruntime140, as in every Steam
    /// game without its own copy, and Wine's C++ runtime switch is off again. It runs
    /// with it (a tester, build 549: it ran without problems).
    static let crysis3Remastered = GameRecommendation(
        id: "crysis-3-remastered", title: "Crysis 3 Remastered", version: 2,
        config: """
        # Madeira's recommended settings for Crysis 3 Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_APP_DLL_SHADOW = vcruntime140.dll
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: false, wineVCRT: false, display: "fit")

    /// Every other game, and the Desktop (owner's decisions, 2026-10-12): most games
    /// the owner tried outside these lists closed at start until the [ec-hook]
    /// reporter was off. It reads code a game's protection rewrites at run time
    /// (GTA V Enhanced outside Steam on build 451, Ghost of Tsushima on build 515),
    /// and it only logs, so turning it off costs a game nothing. Version 3: without
    /// madeira-bcd's defaults (version 2 had them). This list reaches every game, and
    /// MADEIRA_FREE_DELAY_MS keeps a released block's addresses taken, so an allocator
    /// that reserves, releases and reserves again inside the same range never gets it
    /// back: Madeira Dock spun on "Loading Steam" before Thumper. The game lists that
    /// were tested with those defaults keep them. No switches.
    static let standard = GameRecommendation(
        id: "standard", title: "games without a list of their own", version: 3,
        config: """
        # Madeira's recommended settings for a game without a list of its own.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// The Rockstar Games Launcher outside Steam (Launcher.exe in its own folder;
    /// a tester's copy of a game bought there, 2026-10-28). Through Madeira Dock the
    /// game's own list carries the launcher chain's lines and the Dock starts the
    /// service manager; a library entry for the launcher itself had neither. Log 91:
    /// no service manager, so the launcher's service could not be installed
    /// (\pipe\svcctl missing, RPC 1722). Log 92: with it, the sign-in helper's
    /// libcef.dll found no room in a 624 MB pool (c0000017, six restarts, a black
    /// window). Log 93: with the pool lines, libcef loaded, then the helper's 32 GB
    /// PartitionAlloc reservation met the emulator's arena and Chromium stopped
    /// itself (0x80000003). So: the Wine desktop with Windows services first, and the
    /// chain's lines from the games' lists (Social Club layout 2, the pool lines,
    /// pure-x64 images uncopied, the crash handler and the vc_redist re-run refused).
    static let rockstarLauncher = GameRecommendation(
        id: "rockstar-launcher", title: "Rockstar Games Launcher", version: 1,
        config: """
        # Madeira's recommended settings for the Rockstar Games Launcher outside Steam.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool-low = 1
        pool-mid = 1
        pool-page-fit = 1
        pool-split = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        fastSync: true, display: "fit", launchMode: "desktop", startServices: true)

    /// The launcher's installer (log 91): it installs the launcher's service, which
    /// needs the service manager, and runs the embedded vc_redist, which the
    /// launcher's list refuses; so the two Launch switches and the standard line only.
    static let rockstarLauncherSetup = GameRecommendation(
        id: "rockstar-launcher-setup", title: "Rockstar Games Launcher installer", version: 1,
        config: """
        # Madeira's recommended settings for the Rockstar Games Launcher installer.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        launchMode: "desktop", startServices: true)

    /// ml2021: Valve's client in Big Picture (the library's Big Picture button;
    /// C:\big-picture.bat in the Wine desktop, LibraryEntry.bigPictureEntry). A
    /// 64-bit Chromium host like the publisher launcher's helper, so it takes that
    /// chain's memory lines: Social Club layout 2 for libcef.dll's PartitionAlloc
    /// pools, the emulator's code buffers below the window, pure-x64 images
    /// uncopied, the stamped orphan-lock mode, GDI's shared section (the client's
    /// updater, iDeck's finding), and the swap tier with the donor pool so the web
    /// helper's idle pages leave the footprint. No release delay: the client's
    /// allocator reserves, releases and reserves again (the standard list dropped it
    /// for Madeira Dock's "Loading Steam"). Version 2 (log 83, 2026-10-25): the win32
    /// client's steam.exe and its web helper are 32-bit programs, one 4 GB guest window
    /// each; the second was refused for the default 8 GB of spare address space
    /// (`refused: map too small`), so the margin is the launcher chain's 2 GB and the
    /// session holds every window slot from the start.
    /// Version 3: the 32-bit web helper's crash reporter may start
    /// (MADEIRA_STEAM_ALLOW_CRASHPAD; without it the helper ends itself at start), and
    /// Social Club's shared PartitionAlloc pool layout (MADEIRA_SC_PA_POOLS) is gone:
    /// its soft address grants can overlap the client's own views.
    /// Version 4 (logs 111-112, Big Picture loaded): the UI's JavaScript ran interpreted
    /// (V8 --jitless, ml476's choice for the old client, whose stalls also had the
    /// debugger overhead in them) and its renderer thread took most of a core on every
    /// screen change; V8 compiles again (MADEIRA_JITLESS = 0, set 1 to compare), and CEF's
    /// verbose file log is off (MADEIRA_CEF_VERBOSE = 0).
    /// Version 5 (logs 113-114): with V8 compiling, its code space is pool-aliased RWX
    /// memory in the 32-bit window, so every store to it was emulated (254,000 in 40 s
    /// against 5 jitless) and the renderer stopped producing frames: the UI froze. V8
    /// is interpreted again (the default); the verbose log stays off.
    /// Version 6 (logs 116-119): in three starts of four the web helper's renderer thread
    /// waited forever for a lock in libcef.dll that two other threads held, before the UI
    /// came up or on the Steam logo. A 32-bit process stuck like that for 40 s is ended
    /// (MADEIRA_SRW_HANG_KILL_S = 40), so the client starts a new web helper; the holders
    /// are logged at 30 s.
    static let steamBigPicture = GameRecommendation(
        id: "steam-big-picture", title: "Steam Big Picture", version: 6,
        config: """
        # Madeira's recommended settings for Steam Big Picture.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        swap-mb = 4096
        swap-min-mb = 1
        env.MADEIRA_SWAP_COVERAGE = broad
        donor-pool-mb = 4096
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_GDI_SHARED_SECTION = 1
        env.MADEIRA_STEAM_ALLOW_CRASHPAD = 1
        env.MADEIRA_CEF_VERBOSE = 0
        env.MADEIRA_SRW_HANG_KILL_S = 40
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_WOW_PLACEHOLDERS = 1
        env.MADEIRA_FREE_DELAY_MS = 0
        env.MADEIRA_EC_HOOK_TRACE = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        fastSync: true, display: "fit")

    /// The 3 GB RAM swap a device with less than 12 GB of RAM gets in GTA V
    /// Legacy's list.
    static let smallRAMSwapLines = "swap-mb = 3072"

    static let all = [rdr2Steam, rdr2Other, gta5EnhancedSteam, gta5EnhancedOther, gta5LegacySteam, gta5LegacyOther, gta4Steam,
                      ghostOfTsushima, godOfWar, horizonZeroDawn, horizonForbiddenWest, ratchetClankRiftApart, crysisRemastered,
                      crysis2Remastered, crysis3Remastered, rockstarLauncher, rockstarLauncherSetup, steamBigPicture,
                      darkSoulsRemastered, darkSoulsIII, falloutNewVegas, fallout3, blackOps2, standard]
        + steamTitles.map(\.list)

    // MARK: Recognising a game

    /// Steam App IDs.
    static let rdr2AppID = 1174180, gta5EnhancedAppID = 3240220, ghostAppID = 2215430, godOfWarAppID = 1593500,
               horizonZeroDawnAppID = 1151640, darkSoulsRemasteredAppID = 570940, darkSoulsIIIAppID = 374320,
               crysisRemasteredAppID = 1715130, crysis2RemasteredAppID = 2096600,
               crysis3RemasteredAppID = 2096610, horizonForbiddenWestAppID = 2420110, ratchetClankRiftApartAppID = 1895880
    static let falloutNewVegasAppID = 22380, fallout3AppIDs: Set<Int> = [22300, 22370]   // Fallout 3, its GOTY Edition
    /// Black Ops II's campaign, Zombies and multiplayer.
    static let blackOps2AppIDs: Set<Int> = [202970, 212910, 202990]
    /// GTA V Legacy, the edition every Steam copy of GTA V also carries.
    static let gta5LegacyAppID = 271590
    /// Grand Theft Auto IV: The Complete Edition.
    static let gta4AppID = 12210

    /// The recommendation for a game, or nil.
    /// - windowsPath: a program ("C:\Games\GoW\GoW.exe"), or a library Steam
    ///   game's install folder ("C:\...\steamapps\common\Red Dead Redemption 2").
    /// - steamAppID: set for a library Steam game.
    /// - fileExists: whether a C:\ path exists (GTA5_Enhanced.exe beside a program).
    static func match(windowsPath: String, steamAppID: Int?, fileExists: (String) -> Bool) -> GameRecommendation? {
        let path = windowsPath.replacingOccurrences(of: "/", with: "\\").trimmingSuffix("\\")
        let parts = path.lowercased().split(separator: "\\").map(String.init)
        guard let last = parts.last else { return nil }
        let steamFolder = steamCommonFolder(parts)
        if last == "big-picture.bat" { return steamBigPicture }   // ml2021: the library's Big Picture entry
        guard last.hasSuffix(".exe") else {
            // A library Steam game: its App ID, or its install folder right under
            // steamapps\common (not a batch file inside it).
            let installFolder = last == steamFolder ? steamFolder : nil
            if steamAppID == rdr2AppID || installFolder == "red dead redemption 2" { return rdr2Steam }
            if steamAppID == gta5EnhancedAppID || installFolder == "grand theft auto v enhanced" { return gta5EnhancedSteam }
            if steamAppID == gta5LegacyAppID || installFolder == "grand theft auto v" { return gta5LegacySteam }
            if steamAppID == gta4AppID || installFolder == "grand theft auto iv" { return gta4Steam }
            if steamAppID == ghostAppID || installFolder == "ghost of tsushima director's cut"
                || installFolder == "ghost of tsushima" { return ghostOfTsushima }
            if steamAppID == godOfWarAppID || installFolder == "godofwar" || installFolder == "god of war" { return godOfWar }
            if steamAppID == horizonZeroDawnAppID || installFolder == "horizon zero dawn" { return horizonZeroDawn }
            if steamAppID == darkSoulsRemasteredAppID || installFolder == "dark souls remastered" { return darkSoulsRemastered }
            if steamAppID == darkSoulsIIIAppID || installFolder == "dark souls iii" { return darkSoulsIII }
            if steamAppID == falloutNewVegasAppID || installFolder == "fallout new vegas" { return falloutNewVegas }
            if steamAppID.map(fallout3AppIDs.contains) == true || installFolder == "fallout 3"
                || installFolder == "fallout 3 goty" { return fallout3 }
            if blackOps2AppIDs.contains(steamAppID ?? 0) || installFolder == "call of duty black ops ii" { return blackOps2 }
            if steamAppID == horizonForbiddenWestAppID || installFolder == "horizon forbidden west complete edition" {
                return horizonForbiddenWest
            }
            if steamAppID == ratchetClankRiftApartAppID || installFolder == "ratchet & clank - rift apart" {
                return ratchetClankRiftApart
            }
            if steamAppID == crysisRemasteredAppID || installFolder == "crysis remastered" { return crysisRemastered }
            if steamAppID == crysis2RemasteredAppID || installFolder == "crysis 2 remastered" { return crysis2Remastered }
            if steamAppID == crysis3RemasteredAppID || installFolder == "crysis 3 remastered" { return crysis3Remastered }
            return steamTitles.first { title in
                steamAppID.map { title.appIDs.contains($0) } == true || installFolder.map { title.folders.contains($0) } == true
            }?.list
        }
        // A program, wherever it was installed: only the game's own programs, so a
        // redistributable inside a game's folder gets nothing.
        let inSteam = steamAppID != nil || steamFolder != nil
        switch last {
        case "playgtav.exe", "gta5_enhanced.exe":
            // GTA V Enhanced (the legacy edition has PlayGTAV.exe too, beside GTA5.exe):
            // inside a Steam library the Steam copy, anywhere else the list for outside Steam.
            let folder = path.lastIndex(of: "\\").map { String(path[..<$0]) } ?? ""
            guard fileExists(folder + "\\GTA5_Enhanced.exe") else {
                // GTA V Legacy: PlayGTAV.exe beside GTA5.exe, inside or outside a Steam library.
                guard last == "playgtav.exe" && fileExists(folder + "\\GTA5.exe") else { return nil }
                return inSteam ? gta5LegacySteam : gta5LegacyOther
            }
            return inSteam ? gta5EnhancedSteam : gta5EnhancedOther
        case "gta5.exe":
            // GTA V Legacy's game program, inside or outside a Steam library.
            return inSteam ? gta5LegacySteam : gta5LegacyOther
        case "playgtaiv.exe", "launchgtaiv.exe", "gtaiv.exe":
            // Grand Theft Auto IV's launcher stub and game program, from Steam only.
            return inSteam ? gta4Steam : nil
        case "rdr2.exe", "playrdr2.exe":
            return inSteam ? rdr2Steam : rdr2Other
        case "ghostoftsushima.exe":
            return ghostOfTsushima
        case "gow.exe":
            return godOfWar
        case "horizonzerodawn.exe":
            return horizonZeroDawn
        case "darksoulsremastered.exe":
            return darkSoulsRemastered
        case "darksoulsiii.exe":
            return darkSoulsIII
        case "falloutnv.exe":
            return falloutNewVegas
        case "fallout3.exe":
            return fallout3
        case "t6sp.exe", "t6zm.exe", "t6mp.exe":
            return blackOps2
        case "horizonforbiddenwest.exe":
            return horizonForbiddenWest
        case "riftapart.exe":
            return ratchetClankRiftApart
        case "crysisremastered.exe":
            return crysisRemastered
        case "crysis2remastered.exe":
            return crysis2Remastered
        case "crysis3remastered.exe":
            return crysis3Remastered
        case "launcher.exe" where Array(parts.dropLast().suffix(2)) == ["rockstar games", "launcher"]:
            // The Rockstar Games Launcher outside Steam; another publisher's Launcher.exe gets nothing here.
            return rockstarLauncher
        case "rockstar-games-launcher.exe":
            return rockstarLauncherSetup
        default:
            return steamTitles.first { $0.programs.contains(last) || (inSteam && $0.steamPrograms.contains(last)) }?.list
        }
    }

    /// The folder name right under steamapps\common, lowercased, or nil.
    static func steamCommonFolder(_ parts: [String]) -> String? {
        guard parts.count >= 3 else { return nil }
        for i in 0..<(parts.count - 2) where parts[i] == "steamapps" && parts[i + 1] == "common" {
            return parts[i + 2]
        }
        return nil
    }
}

// MARK: More Steam titles

/// Lists merged on 2026-10-26 from community tested lists, one per Steam title,
/// in this file's format. Only lines this tree reads are kept; each list's comment
/// names the lines left out and why.
extension GameRecommendations {
    /// A title `match` recognises: its Steam App IDs, its folders right under
    /// steamapps\common (lowercased), the programs that name it wherever they are
    /// installed, and the programs that name it only inside a Steam library.
    struct SteamTitle {
        let appIDs: [Int]
        let folders: [String]
        let programs: [String]
        let steamPrograms: [String]
        let list: GameRecommendation
    }

    static let steamTitles: [SteamTitle] = [
        SteamTitle(appIDs: [2537590], folders: ["msfs2024"],
                   programs: ["flightsimulator2024.exe"], steamPrograms: [], list: msfs2024),
        SteamTitle(appIDs: [730], folders: ["counter-strike global offensive"],
                   programs: ["cs2.exe"], steamPrograms: [], list: counterStrike2),
        SteamTitle(appIDs: [432940], folders: ["breakneck"],
                   programs: ["breakneck.exe"], steamPrograms: [], list: breakneck),
        SteamTitle(appIDs: [418530], folders: ["spelunky 2"],
                   programs: ["spel2.exe"], steamPrograms: [], list: spelunky2),
        SteamTitle(appIDs: [761890], folders: ["albion online"],
                   programs: ["albionlauncher.exe"], steamPrograms: [], list: albionOnline),
        SteamTitle(appIDs: [990080], folders: ["hogwarts legacy"],
                   programs: ["hogwartslegacy.exe"], steamPrograms: [], list: hogwartsLegacy),
        SteamTitle(appIDs: [287700], folders: ["mgs_tpp"],
                   programs: ["mgsvtpp.exe"], steamPrograms: [], list: metalGearSolidV),
        SteamTitle(appIDs: [3564860], folders: ["stellarbladedemo"],
                   programs: ["sb-win64-shipping.exe"], steamPrograms: [], list: stellarBladeDemo),
        SteamTitle(appIDs: [4078430], folders: ["star wars galactic racer"],
                   programs: ["swgr-win64-shipping.exe"], steamPrograms: [], list: starWarsGalacticRacer),
        SteamTitle(appIDs: [], folders: ["minecraft dungeons ii"],
                   programs: [], steamPrograms: [], list: minecraftDungeons2),
        SteamTitle(appIDs: [2524850], folders: ["denshattack"],
                   programs: ["denshattack_proto.exe"], steamPrograms: [], list: denshattack),
        SteamTitle(appIDs: [4474710], folders: ["final fantasy resonance demo"],
                   programs: ["ffrs.exe"], steamPrograms: [], list: finalFantasyResonanceDemo),
        SteamTitle(appIDs: [1371980], folders: ["norestforthewicked"],
                   programs: ["norestforthewicked.exe"], steamPrograms: [], list: noRestForTheWicked),
        SteamTitle(appIDs: [980610], folders: ["quaver"],
                   programs: ["quaver.exe"], steamPrograms: [], list: quaver),
        SteamTitle(appIDs: [239140], folders: ["dying light"],
                   programs: ["dyinglightgame.exe"], steamPrograms: [], list: dyingLight),
        SteamTitle(appIDs: [284160], folders: ["beamng.drive"],
                   programs: ["beamng.drive.exe"], steamPrograms: [], list: beamngDrive),
        SteamTitle(appIDs: [3470630], folders: ["monster_hunter_stories_3_twisted_reflection_trial"],
                   programs: ["monster_hunter_stories_3_twisted_reflection_trial.exe"], steamPrograms: [], list: monsterHunterStories3Trial),
        SteamTitle(appIDs: [787480], folders: ["phoenix wright ace attorney trilogy"],
                   programs: ["pwaat.exe"], steamPrograms: [], list: pwaat),
        SteamTitle(appIDs: [270880], folders: ["american truck simulator"],
                   programs: ["amtrucks.exe"], steamPrograms: [], list: americanTruckSimulator),
        SteamTitle(appIDs: [1817190], folders: ["marvel's spider-man miles morales"],
                   programs: ["milesmorales.exe"], steamPrograms: [], list: marvelsSpiderManMilesMorales),
        SteamTitle(appIDs: [2536520], folders: ["diablo ii resurrected"],
                   programs: ["d2r.exe"], steamPrograms: [], list: diabloIIResurrected),
        SteamTitle(appIDs: [1903340], folders: ["expedition 33"],
                   programs: ["expedition33_steam.exe", "sandfall-win64-shipping.exe"], steamPrograms: [], list: clairObscurExpedition33),
        SteamTitle(appIDs: [1547000], folders: ["gta san andreas - the definitive edition"],
                   programs: [], steamPrograms: ["playgtasanandreas.exe"], list: gtasaDeSteam),
        SteamTitle(appIDs: [2211170], folders: ["unrailed! 2 back on track"],
                   programs: [], steamPrograms: [], list: unrailed2BackOnTrack),
        SteamTitle(appIDs: [2273430], folders: ["blazblueentropyeffect"],
                   programs: [], steamPrograms: ["blazblueentropyeffect.exe"], list: blazblueEntropyEffect),
        SteamTitle(appIDs: [1817070], folders: ["marvel's spider-man remastered"],
                   programs: ["spider-man.exe"], steamPrograms: [], list: marvelsSpiderManRemastered),
        SteamTitle(appIDs: [2651280], folders: ["marvel's spider-man 2"],
                   programs: ["spider-man2.exe"], steamPrograms: [], list: marvelsSpiderMan2),
        SteamTitle(appIDs: [2288350], folders: ["raidou tmotsa"],
                   programs: [], steamPrograms: ["raidou tmotsa.exe"], list: raidouRemastered),
        SteamTitle(appIDs: [1235140], folders: ["yakuza like a dragon"],
                   programs: [], steamPrograms: ["yakuzalikeadragon.exe"], list: yakuzaLikeADragon),
        SteamTitle(appIDs: [200260], folders: ["batman arkham city goty"],
                   programs: [], steamPrograms: ["batmanac.exe", "bmlauncher.exe"], list: batmanArkhamCityGoty),
        SteamTitle(appIDs: [3375780], folders: ["trails in the sky 1st chapter"],
                   programs: [], steamPrograms: ["sora_1st.exe"], list: trailsInTheSky1stChapter),
        SteamTitle(appIDs: [1962700], folders: ["subnautica2"],
                   programs: [], steamPrograms: ["subnautica2-win64-shipping.exe"], list: subnautica2),
        SteamTitle(appIDs: [2668510], folders: ["red dead redemption"],
                   programs: [], steamPrograms: ["playrdr.exe"], list: rdr1Steam),
        SteamTitle(appIDs: [3764200], folders: ["resident evil requiem biohazard requiem"],
                   programs: [], steamPrograms: ["re9.exe"], list: residentEvilRequiem),
        SteamTitle(appIDs: [4459100], folders: ["resident evil requiem biohazard requiem - demo"],
                   programs: [], steamPrograms: ["re9demo.exe"], list: residentEvilRequiemDemo),
        SteamTitle(appIDs: [1265920], folders: ["lis - remastered"],
                   programs: [], steamPrograms: ["lis-win64-shipping.exe"], list: lifeIsStrangeRemastered),
        SteamTitle(appIDs: [532210], folders: ["life is strange 2"],
                   programs: [], steamPrograms: ["lis2-win64-shipping.exe"], list: lifeIsStrange2),
        SteamTitle(appIDs: [108600], folders: ["projectzomboid"],
                   programs: [], steamPrograms: ["projectzomboid64.exe"], list: projectZomboid),
        SteamTitle(appIDs: [1329500], folders: ["spiderheck"],
                   programs: [], steamPrograms: ["spiderheckapp.exe"], list: spiderheck),
        SteamTitle(appIDs: [1557740], folders: ["rounds"],
                   programs: [], steamPrograms: ["rounds.exe"], list: rounds),
        SteamTitle(appIDs: [1599600], folders: ["plateup"],
                   programs: [], steamPrograms: ["plateup.exe"], list: plateup),
        SteamTitle(appIDs: [1004640], folders: ["final fantasy tactics - the ivalice chronicles"],
                   programs: [], steamPrograms: ["fft_enhanced.exe"], list: finalFantasyTacticsIvaliceChronicles),
        SteamTitle(appIDs: [1181600], folders: ["jetboardjoust"],
                   programs: [], steamPrograms: ["jetboardjoust.exe"], list: jetboardJoust),
        SteamTitle(appIDs: [3404260], folders: [],
                   programs: ["pagoda.exe"], steamPrograms: [], list: deadAsDisco),
        SteamTitle(appIDs: [], folders: ["tung"],
                   programs: ["tung.exe"], steamPrograms: [], list: tung),
        SteamTitle(appIDs: [814380], folders: ["sekiro"],
                   programs: ["sekiro.exe"], steamPrograms: [], list: sekiroShadowsDieTwice),
        SteamTitle(appIDs: [413150], folders: ["stardew valley"],
                   programs: ["stardew valley.exe"], steamPrograms: [], list: stardewValley),
        SteamTitle(appIDs: [2400160], folders: ["glyphica"],
                   programs: ["neosphere.exe"], steamPrograms: [], list: glyphicaTypingSurvival),
        SteamTitle(appIDs: [3483510], folders: ["the adventures of elliot the millennium tales"],
                   programs: ["elliot-win64-shipping.exe"], steamPrograms: [], list: theAdventuresOfElliot),

    ]

    /// Microsoft Flight Simulator 2024 (Steam App ID 2537590). Ported on 2026-10-26 from a community tested list
    /// for it (its version 6); not device-tested here.
    static let msfs2024 = GameRecommendation(
        id: "msfs-2024", title: "Microsoft Flight Simulator 2024", version: 1,
        config: """
        # Madeira's recommended settings for Microsoft Flight Simulator 2024.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        d3d12-fl-12-1 = 1
        d3d12-sm-6-7 = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: true, wineVCRT: false, display: "fit")

    /// Counter-Strike 2 (Steam App ID 730). Ported on 2026-10-26 from a community tested list for it (its version
    /// 2); not device-tested here.
    static let counterStrike2 = GameRecommendation(
        id: "counter-strike-2", title: "Counter-Strike 2", version: 1,
        config: """
        # Madeira's recommended settings for Counter-Strike 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        pool-split = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Breakneck (Steam App ID 432940). Ported on 2026-10-26 from a community tested list for it (its version 1);
    /// not device-tested here.
    static let breakneck = GameRecommendation(
        id: "breakneck", title: "Breakneck", version: 1,
        config: """
        # Madeira's recommended settings for Breakneck.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_WOW_RWX_PLAIN = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Spelunky 2 (Steam App ID 418530). Ported on 2026-10-26 from a community tested list for it (its version 3);
    /// not device-tested here.
    static let spelunky2 = GameRecommendation(
        id: "spelunky-2", title: "Spelunky 2", version: 1,
        config: """
        # Madeira's recommended settings for Spelunky 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Albion Online (Steam App ID 761890). Ported on 2026-10-26 from a community tested list for it (its version
    /// 1); not device-tested here.
    static let albionOnline = GameRecommendation(
        id: "albion-online", title: "Albion Online", version: 1,
        config: """
        # Madeira's recommended settings for Albion Online.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        pool-split = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Hogwarts Legacy (Steam App ID 990080). Ported on 2026-10-26 from a community tested list for it (its
    /// version 1); not device-tested here.
    static let hogwartsLegacy = GameRecommendation(
        id: "hogwarts-legacy", title: "Hogwarts Legacy", version: 1,
        config: """
        # Madeira's recommended settings for Hogwarts Legacy.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 448
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// METAL GEAR SOLID V: THE PHANTOM PAIN (Steam App ID 287700). Ported on 2026-10-26 from a community tested
    /// list for it (its version 1); not device-tested here.
    static let metalGearSolidV = GameRecommendation(
        id: "metal-gear-solid-v", title: "METAL GEAR SOLID V: THE PHANTOM PAIN", version: 1,
        config: """
        # Madeira's recommended settings for METAL GEAR SOLID V: THE PHANTOM PAIN.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 176
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Stellar Blade Demo (Steam App ID 3564860). Ported on 2026-10-26 from a community tested list for it (its
    /// version 2); not device-tested here.
    static let stellarBladeDemo = GameRecommendation(
        id: "stellar-blade-demo", title: "Stellar Blade Demo", version: 1,
        config: """
        # Madeira's recommended settings for Stellar Blade Demo.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 320
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// STAR WARS Galactic Racer (Steam App ID 4078430). Ported on 2026-10-26 from a community tested list for it
    /// (its version 2); not device-tested here.
    static let starWarsGalacticRacer = GameRecommendation(
        id: "star-wars-galactic-racer", title: "STAR WARS Galactic Racer", version: 1,
        config: """
        # Madeira's recommended settings for STAR WARS Galactic Racer.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 496
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Minecraft Dungeons II (Steam folder "minecraft dungeons ii"). Ported on 2026-10-26 from a community tested
    /// list for it (its version 1); not device-tested here. Left out: MADEIRA_OPTIN_DLLS (the community app-side
    /// switch; not in this tree (opt-in DLLs not merged)); pool-split-retry (the community app-side switch; not in
    /// this tree).
    static let minecraftDungeons2 = GameRecommendation(
        id: "minecraft-dungeons-2", title: "Minecraft Dungeons II", version: 1,
        config: """
        # Madeira's recommended settings for Minecraft Dungeons II.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_LOCK_ORPHAN = 0
        quiet-log = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        pool-split = 1
        env.MADEIRA_VCRT_ARM64_KEY = 1
        env.MADEIRA_FAULT_GUARD_GUEST_RIP = 1
        env.MADEIRA_RECOVERY_LOG_SAMPLE = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Denshattack! (Steam App ID 2524850). Ported on 2026-10-26 from a community tested list for it (its version
    /// 1); not device-tested here.
    static let denshattack = GameRecommendation(
        id: "denshattack", title: "Denshattack!", version: 1,
        config: """
        # Madeira's recommended settings for Denshattack!.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_VCRT_ARM64_KEY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// FINAL FANTASY RESONANCE DEMO (Steam App ID 4474710). Ported on 2026-10-26 from a community tested list for
    /// it (its version 2); not device-tested here.
    static let finalFantasyResonanceDemo = GameRecommendation(
        id: "final-fantasy-resonance-demo", title: "FINAL FANTASY RESONANCE DEMO", version: 1,
        config: """
        # Madeira's recommended settings for FINAL FANTASY RESONANCE DEMO.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_VCRT_ARM64_KEY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// No Rest for the Wicked (Steam App ID 1371980). Ported on 2026-10-26 from a community tested list for it
    /// (its version 4); not device-tested here. Left out: MADEIRA_WINTYPES (the community app-side switch; not in
    /// this tree).
    static let noRestForTheWicked = GameRecommendation(
        id: "no-rest-for-the-wicked", title: "No Rest for the Wicked", version: 1,
        config: """
        # Madeira's recommended settings for No Rest for the Wicked.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_FEX_BAND_KEEP_MB = 6144
        dxmt = d3d11.mipClampBC=1
        env.MADEIRA_CTX_FRAME = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Quaver (Steam App ID 980610). Ported on 2026-10-26 from a community tested list for it (its version 1); not
    /// device-tested here.
    static let quaver = GameRecommendation(
        id: "quaver", title: "Quaver", version: 1,
        config: """
        # Madeira's recommended settings for Quaver.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.DOTNET_EnableWriteXorExecute = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Dying Light (Steam App ID 239140). Ported on 2026-10-26 from a community tested list for it (its version
    /// 2); not device-tested here. Left out: MADEIRA_OPTIN_DLLS (the community app-side switch; not in this tree
    /// (opt-in DLLs not merged)); MADEIRA_OPTIN_DLLS (the community app-side switch; not in this tree (opt-in DLLs
    /// not merged)).
    static let dyingLight = GameRecommendation(
        id: "dying-light", title: "Dying Light", version: 1,
        config: """
        # Madeira's recommended settings for Dying Light.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.LC_ALL = en_US.UTF-8
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// BeamNG.drive (Steam App ID 284160). Ported on 2026-10-26 from a community tested list for it (its version
    /// 2); not device-tested here. Left out: MADEIRA_X64_MACHINE (read by a Wine/tools patch that is not merged).
    static let beamngDrive = GameRecommendation(
        id: "beamng-drive", title: "BeamNG.drive", version: 1,
        config: """
        # Madeira's recommended settings for BeamNG.drive.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Monster Hunter Stories 3: Twisted Reflection Trial Version (Steam App ID 3470630). Ported on 2026-10-26 from
    /// a community tested list for it (its version 1); not device-tested here.
    static let monsterHunterStories3Trial = GameRecommendation(
        id: "monster-hunter-stories-3-trial", title: "Monster Hunter Stories 3: Twisted Reflection Trial Version", version: 1,
        config: """
        # Madeira's recommended settings for Monster Hunter Stories 3: Twisted Reflection Trial Version.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Phoenix Wright: Ace Attorney Trilogy (Steam App ID 787480). Ported on 2026-10-26 from a community tested
    /// list for it (its version 1); not device-tested here.
    static let pwaat = GameRecommendation(
        id: "pwaat", title: "Phoenix Wright: Ace Attorney Trilogy", version: 1,
        config: """
        # Madeira's recommended settings for Phoenix Wright: Ace Attorney Trilogy.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_WOW_RWX_PLAIN = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// American Truck Simulator (Steam App ID 270880). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let americanTruckSimulator = GameRecommendation(
        id: "american-truck-simulator", title: "American Truck Simulator", version: 1,
        config: """
        # Madeira's recommended settings for American Truck Simulator.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_TINY_WINDOW_FIX = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Marvel's Spider-Man: Miles Morales (Steam App ID 1817190). Ported on 2026-10-26 from a community tested
    /// list for it (its version 1); not device-tested here.
    static let marvelsSpiderManMilesMorales = GameRecommendation(
        id: "marvels-spider-man-miles-morales", title: "Marvel's Spider-Man: Miles Morales", version: 1,
        config: """
        # Madeira's recommended settings for Marvel's Spider-Man: Miles Morales.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        mip0-full = 1
        quiet-log = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, display: "fit")

    /// Diablo II: Resurrected (Steam App ID 2536520). Ported on 2026-10-26 from a community tested list for it
    /// (its version 2); not device-tested here. Left out: MADEIRA_OPTIN_DLLS (the community app-side switch; not
    /// in this tree (opt-in DLLs not merged)); MADEIRA_NTDLL_XSEC (read by the companion ntdll-xsec.dll, which this
    /// tree does not build); MADEIRA_SHARED_SECTION_EXEC (needs ntdll-xsec.dll (NTDLL_XSEC) to tell the emulator; not
    /// built here); MADEIRA_D2R_PROBE_RECOVERY (read by a Wine/tools patch that is not merged).
    static let diabloIIResurrected = GameRecommendation(
        id: "diablo-ii-resurrected", title: "Diablo II: Resurrected", version: 1,
        config: """
        # Madeira's recommended settings for Diablo II: Resurrected.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_NTDLL_DATA_SYNC_RANGE = 1
        env.MADEIRA_FAULT_LOOP_GUEST_PROGRESS = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Clair Obscur: Expedition 33 (Steam App ID 1903340). Ported on 2026-10-26 from a community tested list for
    /// it (its version 1); not device-tested here.
    static let clairObscurExpedition33 = GameRecommendation(
        id: "clair-obscur-expedition-33", title: "Clair Obscur: Expedition 33", version: 1,
        config: """
        # Madeira's recommended settings for Clair Obscur: Expedition 33.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// GTA San Andreas - The Definitive Edition (Steam) (Steam App ID 1547000). Ported on 2026-10-26 from a
    /// community tested list for it (its version 1); not device-tested here. Left out: MADEIRA_FEX_AVX (the AVX switch
    /// (avx: false) instead).
    static let gtasaDeSteam = GameRecommendation(
        id: "gtasa-de-steam", title: "GTA San Andreas - The Definitive Edition (Steam)", version: 1,
        config: """
        # Madeira's recommended settings for GTA San Andreas - The Definitive Edition (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false)

    /// Unrailed! 2: Back on Track (Steam App ID 2211170). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let unrailed2BackOnTrack = GameRecommendation(
        id: "unrailed-2-back-on-track", title: "Unrailed! 2: Back on Track", version: 1,
        config: """
        # Madeira's recommended settings for Unrailed! 2: Back on Track.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.DOTNET_GCRegionRange = 400000000
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// BlazBlue Entropy Effect (Steam App ID 2273430). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let blazblueEntropyEffect = GameRecommendation(
        id: "blazblue-entropy-effect", title: "BlazBlue Entropy Effect", version: 1,
        config: """
        # Madeira's recommended settings for BlazBlue Entropy Effect.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Marvel's Spider-Man Remastered (Steam App ID 1817070). Ported on 2026-10-26 from a community tested list
    /// for it (its version 2); not device-tested here.
    static let marvelsSpiderManRemastered = GameRecommendation(
        id: "marvels-spider-man-remastered", title: "Marvel's Spider-Man Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Marvel's Spider-Man Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        mip0-full = 1
        quiet-log = 1
        write-buffer-immediate = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, display: "fit")

    /// Marvel's Spider-Man 2 (Steam App ID 2651280). Ported on 2026-10-26 from a community tested list for it (its
    /// version 1); not device-tested here.
    static let marvelsSpiderMan2 = GameRecommendation(
        id: "marvels-spider-man-2", title: "Marvel's Spider-Man 2", version: 1,
        config: """
        # Madeira's recommended settings for Marvel's Spider-Man 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_CAGE_RELEASE = 1
        mip0-full = 1
        quiet-log = 1
        swap-mb = 6144
        swap-mode = 2
        swap-min-mb = 1
        env.MADEIRA_FEX_AVX = 2
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, display: "fit")

    /// RAIDOU Remastered: The Mystery of the Soulless Army (Steam App ID 2288350). Ported on 2026-10-26 from a
    /// community tested list for it (its version 1); not device-tested here.
    static let raidouRemastered = GameRecommendation(
        id: "raidou-remastered", title: "RAIDOU Remastered: The Mystery of the Soulless Army", version: 1,
        config: """
        # Madeira's recommended settings for RAIDOU Remastered: The Mystery of the Soulless Army.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Yakuza: Like a Dragon (Steam App ID 1235140). Ported on 2026-10-26 from a community tested list for it (its
    /// version 1); not device-tested here.
    static let yakuzaLikeADragon = GameRecommendation(
        id: "yakuza-like-a-dragon", title: "Yakuza: Like a Dragon", version: 1,
        config: """
        # Madeira's recommended settings for Yakuza: Like a Dragon.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 416
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Batman: Arkham City GOTY (Steam App ID 200260). Ported on 2026-10-26 from a community tested list for it
    /// (its version 2); not device-tested here.
    static let batmanArkhamCityGoty = GameRecommendation(
        id: "batman-arkham-city-goty", title: "Batman: Arkham City GOTY", version: 1,
        config: """
        # Madeira's recommended settings for Batman: Arkham City GOTY.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.FEX_X87REDUCEDPRECISION = 0
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Trails in the Sky 1st Chapter (Steam App ID 3375780). Ported on 2026-10-26 from a community tested list for
    /// it (its version 1); not device-tested here.
    static let trailsInTheSky1stChapter = GameRecommendation(
        id: "trails-in-the-sky-1st-chapter", title: "Trails in the Sky 1st Chapter", version: 1,
        config: """
        # Madeira's recommended settings for Trails in the Sky 1st Chapter.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_VDCFG_PATH = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Subnautica 2 (Steam App ID 1962700). Ported on 2026-10-26 from a community tested list for it (its version
    /// 1); not device-tested here.
    static let subnautica2 = GameRecommendation(
        id: "subnautica-2", title: "Subnautica 2", version: 1,
        config: """
        # Madeira's recommended settings for Subnautica 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Red Dead Redemption (Steam) (Steam App ID 2668510). Ported on 2026-10-26 from a community tested list for
    /// it (its version 1); not device-tested here.
    static let rdr1Steam = GameRecommendation(
        id: "rdr1-steam", title: "Red Dead Redemption (Steam)", version: 1,
        config: """
        # Madeira's recommended settings for Red Dead Redemption (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Resident Evil Requiem (Steam App ID 3764200). Ported on 2026-10-26 from a community tested list for it (its
    /// version 2); not device-tested here.
    static let residentEvilRequiem = GameRecommendation(
        id: "resident-evil-requiem", title: "Resident Evil Requiem", version: 1,
        config: """
        # Madeira's recommended settings for Resident Evil Requiem.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 592
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        d3d12-pso-cached-blob = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Resident Evil Requiem Demo (Steam App ID 4459100). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let residentEvilRequiemDemo = GameRecommendation(
        id: "resident-evil-requiem-demo", title: "Resident Evil Requiem Demo", version: 1,
        config: """
        # Madeira's recommended settings for Resident Evil Requiem Demo.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        d3d12-pso-cached-blob = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Life is Strange Remastered (Steam App ID 1265920). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let lifeIsStrangeRemastered = GameRecommendation(
        id: "life-is-strange-remastered", title: "Life is Strange Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Life is Strange Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Life is Strange 2 (Steam App ID 532210). Ported on 2026-10-26 from a community tested list for it (its
    /// version 1); not device-tested here.
    static let lifeIsStrange2 = GameRecommendation(
        id: "life-is-strange-2", title: "Life is Strange 2", version: 1,
        config: """
        # Madeira's recommended settings for Life is Strange 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 400
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Project Zomboid (Steam App ID 108600). Ported on 2026-10-26 from a community tested list for it (its
    /// version 1); not device-tested here.
    static let projectZomboid = GameRecommendation(
        id: "project-zomboid", title: "Project Zomboid", version: 1,
        config: """
        # Madeira's recommended settings for Project Zomboid.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env._JAVA_OPTIONS = -XX:-UseZGC
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// SpiderHeck (Steam App ID 1329500). Ported on 2026-10-26 from a community tested list for it (its version
    /// 1); not device-tested here.
    static let spiderheck = GameRecommendation(
        id: "spiderheck", title: "SpiderHeck", version: 1,
        config: """
        # Madeira's recommended settings for SpiderHeck.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_FAULT_GUARD_RATE = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// ROUNDS (Steam App ID 1557740). Ported on 2026-10-26 from a community tested list for it (its version 1);
    /// not device-tested here.
    static let rounds = GameRecommendation(
        id: "rounds", title: "ROUNDS", version: 1,
        config: """
        # Madeira's recommended settings for ROUNDS.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_FAULT_GUARD_RATE = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// PlateUp! (Steam App ID 1599600). Ported on 2026-10-26 from a community tested list for it (its version 1);
    /// not device-tested here.
    static let plateup = GameRecommendation(
        id: "plateup", title: "PlateUp!", version: 1,
        config: """
        # Madeira's recommended settings for PlateUp!.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_FAULT_GUARD_RATE = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// FINAL FANTASY TACTICS - The Ivalice Chronicles (Steam App ID 1004640). Ported on 2026-10-26 from a
    /// community tested list for it (its version 1); not device-tested here.
    static let finalFantasyTacticsIvaliceChronicles = GameRecommendation(
        id: "final-fantasy-tactics-ivalice-chronicles", title: "FINAL FANTASY TACTICS - The Ivalice Chronicles", version: 1,
        config: """
        # Madeira's recommended settings for FINAL FANTASY TACTICS - The Ivalice Chronicles.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_USER_VA_GB = 32
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Jetboard Joust (Steam App ID 1181600). Ported on 2026-10-26 from a community tested list for it (its
    /// version 1); not device-tested here.
    static let jetboardJoust = GameRecommendation(
        id: "jetboard-joust", title: "Jetboard Joust", version: 1,
        config: """
        # Madeira's recommended settings for Jetboard Joust.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_ANON_CAS_FLUSH = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Dead as Disco (Steam App ID 3404260). Ported on 2026-10-26 from a community tested list for it (its version
    /// 1); not device-tested here. Left out: MADEIRA_OPTIN_DLLS (the community app-side switch; not in this tree
    /// (opt-in DLLs not merged)).
    static let deadAsDisco = GameRecommendation(
        id: "dead-as-disco", title: "Dead as Disco", version: 1,
        config: """
        # Madeira's recommended settings for Dead as Disco.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_VCRT_ARM64_KEY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// TUNG (Steam folder "tung"). Ported on 2026-10-26 from a community tested list for it (its version 1); not
    /// device-tested here.
    static let tung = GameRecommendation(
        id: "tung", title: "TUNG", version: 1,
        config: """
        # Madeira's recommended settings for TUNG.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_VCRT_ARM64_KEY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Sekiro: Shadows Die Twice (Steam App ID 814380). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let sekiroShadowsDieTwice = GameRecommendation(
        id: "sekiro-shadows-die-twice", title: "Sekiro: Shadows Die Twice", version: 1,
        config: """
        # Madeira's recommended settings for Sekiro: Shadows Die Twice.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_NLS_EXTRA = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Stardew Valley (Steam App ID 413150). Ported on 2026-10-26 from a community tested list for it (its version
    /// 1); not device-tested here.
    static let stardewValley = GameRecommendation(
        id: "stardew-valley", title: "Stardew Valley", version: 1,
        config: """
        # Madeira's recommended settings for Stardew Valley.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_ANON_CAS_FLUSH = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// Glyphica: Typing Survival (Steam App ID 2400160). Ported on 2026-10-26 from a community tested list for it
    /// (its version 1); not device-tested here.
    static let glyphicaTypingSurvival = GameRecommendation(
        id: "glyphica-typing-survival", title: "Glyphica: Typing Survival", version: 1,
        config: """
        # Madeira's recommended settings for Glyphica: Typing Survival.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_ZERO_MITIGATION_POLICY = 1
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

    /// The Adventures of Elliot: The Millennium Tales (Steam App ID 3483510). Ported on 2026-10-26 from a
    /// community tested list for it (its version 1); not device-tested here. Left out: pool-above-window (the
    /// community app-side switch; not in this tree); MADEIRA_KUSER_KEEP_REGS (its engine code (signal_arm64_ios.c) is
    /// not in this tree yet).
    static let theAdventuresOfElliot = GameRecommendation(
        id: "the-adventures-of-elliot", title: "The Adventures of Elliot: The Millennium Tales", version: 1,
        config: """
        # Madeira's recommended settings for The Adventures of Elliot: The Millennium Tales.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-window-mb = 480
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        pool-split = 1
        pool-low = 1
        pool-low-margin = 32
        # The defaults this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """)

}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
