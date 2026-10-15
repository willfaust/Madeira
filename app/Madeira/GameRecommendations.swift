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

    /// The config file's text as GameProfile stores it (one trailing newline).
    var fileText: String { config.hasSuffix("\n") ? config : config + "\n" }

    /// A short list of the switches it sets, for Game details.
    var switchSummary: String {
        var parts: [String] = []
        if let avx { parts.append("AVX \(avx ? "on" : "off")") }
        if let nvidia { parts.append("NVIDIA \(nvidia ? "on" : "off")") }
        if let wineVCRT { parts.append("Wine's C++ runtime \(wineVCRT ? "on" : "off")") }
        if fastSync == false { parts.append("fast synchronization off") }
        if let semaphoreFastPath { parts.append("fast semaphore waits \(semaphoreFastPath ? "on" : "off")") }
        if let fpsMode {
            let label = [1: "60", 3: "30", 4: "40", 0: "display maximum", 2: "uncapped"][fpsMode] ?? "\(fpsMode)"
            parts.append("FPS limit \(label)")
        }
        if let resolution { parts.append(resolution == Self.screen720 ? "this screen's shape at 720 lines" : resolution) }
        return parts.joined(separator: ", ")
    }
}

enum GameRecommendations {
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
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
    /// (with the line GTA's installs passed, 13:08).
    static let gta5EnhancedSteam = GameRecommendation(
        id: "gta5e-steam", title: "GTA V Enhanced (Steam)", version: 3,
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 4,
        display: "fit")

    /// GTA V Enhanced started from its own PlayGTAV.exe outside a Steam
    /// library (Rockstar Games Launcher or another store; build 451). Version 2:
    /// the same orphan-lock reaper mode as the Steam copy (its launcher and
    /// Social Club too).
    static let gta5EnhancedOther = GameRecommendation(
        id: "gta5e-other", title: "GTA V Enhanced (outside Steam)", version: 2,
        config: """
        # Madeira's recommended settings for GTA V Enhanced outside Steam (Rockstar Games Launcher or another store).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        vram-mb = 4096
        d3d12-core-dll = 1
        d3d12-typed-uav-load = 1
        d3d12-tiled-resources = 1
        d3d12-tile-based = 0
        d3d12-caps-log = 2
        d3d12-msaa8 = 1
        pool-split = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PAD_MODE = hid
        env.SteamDeck = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_FASTSYNC_SEM = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, resolution: "1280x720", display: "fit")

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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, display: "fit")

    /// Horizon Forbidden West (Complete Edition, Steam 2420110), madeira-bcd builds
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
    /// madeira-bcd ships it, without its own variant DXGI DLL (this dxgi.dll has the
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
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
    /// eco. With it (madeira-bcd build 531, 2026-10-14, a tester's iPhone 15 Pro Max
    /// with 6 GB for the app) the game created its D3D12 device and swapchain and
    /// played the Bink intro, then thrashed memory there (footprint 3.3-4.1 GB with
    /// 1.1-2.2 GB compressed); a device with more memory should get further.
    static let ratchetClankRiftApart = GameRecommendation(
        id: "ratchet-clank-rift-apart", title: "Ratchet & Clank: Rift Apart", version: 1,
        config: """
        # Madeira's recommended settings for Ratchet & Clank: Rift Apart.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        vram-mb = 3072
        swap-mb = 8192
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        typed-view-rgb32 = 1
        mip0-full = 1
        quiet-log = 1
        pso-lazy-libs = 1
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: true, wineVCRT: false, fastSync: true, fpsMode: 3, display: "fit")

    /// Crysis Remastered (Steam): madeira-bcd build 528, 2026-10-13 22:08, the owner:
    /// "mükemmel çalıştı" (it ran perfectly). It ran with the standard list's line and
    /// every switch off (AVX, NVIDIA, Wine's C++ runtime, MetalFX) at 1408x648 Fit,
    /// 5.2 GB at most, and closed normally. Its own list keeps those switches and the
    /// defaults it was tested with when the standard list changes.
    static let crysisRemastered = GameRecommendation(
        id: "crysis-remastered", title: "Crysis Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Crysis Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, display: "fit")

    /// Crysis 2 Remastered (Steam 2096600), not yet run with this list. On madeira-bcd
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
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: false, wineVCRT: false, display: "fit")

    /// Crysis 3 Remastered (Steam 2096610). On madeira-bcd build 540 (2026-10-14
    /// 23:55) it ran with the standard list and every switch off, and stopped when
    /// msvcp140.dll branched to its own image base (c000001d on the MZ header).
    /// Version 1 turned Wine's C++ runtime on; it stopped the same way on build 547
    /// (2026-10-15 15:08:17): that switch does nothing in a Steam (Dock) session,
    /// and the DLL is Wine's ARM64EC msvcp140 (sysx64) all along. The game's Bin64
    /// ships Microsoft's x64 vcruntime140.dll, and Wine's msvcp140 cannot call its
    /// x64 memcpy (no exit thunk). Version 2: env.MADEIRA_APP_DLL_SHADOW =
    /// vcruntime140.dll makes the loader take Wine's vcruntime140, as in every Steam
    /// game without its own copy, and Wine's C++ runtime switch is off again. It runs
    /// with it (owner, build 549: "sorunsuz çalıştı").
    static let crysis3Remastered = GameRecommendation(
        id: "crysis-3-remastered", title: "Crysis 3 Remastered", version: 2,
        config: """
        # Madeira's recommended settings for Crysis 3 Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_APP_DLL_SHADOW = vcruntime140.dll
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
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

    static let all = [rdr2Steam, rdr2Other, gta5EnhancedSteam, gta5EnhancedOther, ghostOfTsushima, godOfWar, horizonZeroDawn,
                      horizonForbiddenWest, ratchetClankRiftApart, crysisRemastered, crysis2Remastered, crysis3Remastered,
                      standard]

    // MARK: Recognising a game

    /// Steam App IDs.
    static let rdr2AppID = 1174180, gta5EnhancedAppID = 3240220, ghostAppID = 2215430, godOfWarAppID = 1593500,
               horizonZeroDawnAppID = 1151640, crysisRemasteredAppID = 1715130, crysis2RemasteredAppID = 2096600,
               crysis3RemasteredAppID = 2096610, horizonForbiddenWestAppID = 2420110, ratchetClankRiftApartAppID = 1895880

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
        guard last.hasSuffix(".exe") else {
            // A library Steam game: its App ID, or its install folder right under
            // steamapps\common (not a batch file inside it).
            let installFolder = last == steamFolder ? steamFolder : nil
            if steamAppID == rdr2AppID || installFolder == "red dead redemption 2" { return rdr2Steam }
            if steamAppID == gta5EnhancedAppID || installFolder == "grand theft auto v enhanced" { return gta5EnhancedSteam }
            if steamAppID == ghostAppID || installFolder == "ghost of tsushima director's cut"
                || installFolder == "ghost of tsushima" { return ghostOfTsushima }
            if steamAppID == godOfWarAppID || installFolder == "godofwar" || installFolder == "god of war" { return godOfWar }
            if steamAppID == horizonZeroDawnAppID || installFolder == "horizon zero dawn" { return horizonZeroDawn }
            if steamAppID == horizonForbiddenWestAppID || installFolder == "horizon forbidden west complete edition" {
                return horizonForbiddenWest
            }
            if steamAppID == ratchetClankRiftApartAppID || installFolder == "ratchet & clank - rift apart" {
                return ratchetClankRiftApart
            }
            if steamAppID == crysisRemasteredAppID || installFolder == "crysis remastered" { return crysisRemastered }
            if steamAppID == crysis2RemasteredAppID || installFolder == "crysis 2 remastered" { return crysis2Remastered }
            if steamAppID == crysis3RemasteredAppID || installFolder == "crysis 3 remastered" { return crysis3Remastered }
            return nil
        }
        // A program, wherever it was installed: only the game's own programs, so a
        // redistributable inside a game's folder gets nothing.
        let inSteam = steamAppID != nil || steamFolder != nil
        switch last {
        case "playgtav.exe", "gta5_enhanced.exe":
            // GTA V Enhanced (the legacy edition has PlayGTAV.exe too, beside GTA5.exe):
            // inside a Steam library the Steam copy, anywhere else the list for outside Steam.
            let folder = path.lastIndex(of: "\\").map { String(path[..<$0]) } ?? ""
            guard fileExists(folder + "\\GTA5_Enhanced.exe") else { return nil }
            return inSteam ? gta5EnhancedSteam : gta5EnhancedOther
        case "rdr2.exe", "playrdr2.exe":
            return inSteam ? rdr2Steam : rdr2Other
        case "ghostoftsushima.exe":
            return ghostOfTsushima
        case "gow.exe":
            return godOfWar
        case "horizonzerodawn.exe":
            return horizonZeroDawn
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
        default:
            return nil
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

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
