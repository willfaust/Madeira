#!/usr/bin/env python3
"""Generate app/Madeira/ConfigCatalog.generated.swift: every option Madeira reads.

Two kinds of option live in Documents/madeira.cfg:
  - plain keys ("vram-mb = 4352"), read through build/madeira_cfg.h
    (madeira_cfg_get/int/bool), the D3D12 runtime (mad_cfg_int_pe/str_pe) or
    the app (MadeiraConfig.get/bool/flag);
  - environment switches ("env.NAME = value"), which the app exports before
    Wine starts; any MADEIRA_*/DXMT_*/MYTHIC_* name the code reads with getenv,
    GetEnvironmentVariable, env::getEnvVar, madeiraSwitch, ios_srv_switch or a flag helper.

The scan covers the tracked sources of this repository and of the wine, DXMT
and FEX submodules. Each option gets its type and default from the reading
call, a subsystem from the file it is read in, and the comment next to the
first read. OVERLAY adds titles and fixed choices for the options that have a
dedicated place in Settings.

    build/tools/gen-config-catalog.py           rewrite the Swift catalog
    build/tools/gen-config-catalog.py --check   exit 1 if it is out of date
"""
import collections, json, os, re, subprocess, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "app", "Madeira", "ConfigCatalog.generated.swift")
REPOS = {
    ".": ["build", "app", "madeira-d3d12/src", "madeira-dock/src"],
    "dxmt": ["src"],
    "wine": ["dlls", "server"],
    "FEX": ["Source", "FEXCore/Source"],
}
EXT = (".c", ".h", ".m", ".mm", ".cpp", ".hpp", ".cc", ".swift")
SKIP = ("/host-tests/", "/ffmpeg/", "ConfigCatalog.generated.swift")

CFG = re.compile(r'\b(madeira_cfg_(?:get|int|bool)|mad_cfg_(?:int|str)_pe|'
                 r'MadeiraConfig\.(?:get|bool|flag))\(\s*"([A-Za-z0-9._-]+)"\s*(?:,\s*([^,)]+))?')
ENV = re.compile(r'\b(getenv|GetEnvironmentVariable[AW]?|env::getEnvVar|madeiraSwitch|'
                 r'madeira_switch_for_caller|mad_env_is_zero|flag|envFlag|ios_srv_switch)\(\s*L?"((?:MADEIRA|DXMT|MYTHIC)_[A-Z0-9_]+)"'
                 r'\s*(?:,\s*(?:fallback:|default:)?\s*([^,)]+))?')
BOOL_READERS = {"madeira_cfg_bool", "MadeiraConfig.bool", "MadeiraConfig.flag", "flag", "envFlag",
                "madeiraSwitch", "madeira_switch_for_caller", "mad_env_is_zero"}
INT_READERS = {"madeira_cfg_int", "mad_cfg_int_pe"}

# Titles, kinds and fixed choices for options with a dedicated Settings row.
# "choices" are (value, label); the empty value means "remove the key".
OVERLAY = {
    # Madeira in the background (app/Madeira/BackgroundRun.swift, build/ntdll-unix/audio_null_ios.c).
    "background-run": {"category": "App & front end", "title": "Keep a game running in the background (minutes)",
                "kind": "int", "default": "10", "sources": ["app/Madeira/BackgroundRun.swift"],
                "note": "Minutes a running game keeps going after you switch apps or lock the screen, so a long load "
                        "finishes while you are away. Loading and other CPU work go on; drawing waits until Madeira is "
                        "back (background-pause). The game's sound is muted meanwhile. 0: iOS pauses the game within "
                        "seconds, as before. A game's own config can set it. [bg-run] lines in the log."},
    "background-gpu-gate": {"category": "App & front end", "title": "Hold GPU work in the background",
                "kind": "bool", "default": "1", "sources": ["app/Madeira/BackgroundRun.swift"],
                "note": "On by default. While Madeira is not the active app, any thread other than the app's main "
                        "thread that commits a Metal command buffer waits until Madeira is back, so a game that keeps "
                        "loading in the background (Zink OpenGL, Direct3D, Vulkan) never sends GPU work iOS refuses "
                        "and never loses its device. [metal-bg] lines in the log. 0: not installed. Read at app start."},
    "background-cpu": {"category": "App & front end", "title": "CPU cap in the background (% of one core)",
                "kind": "int", "default": "50", "sources": ["app/Madeira/BackgroundRun.swift"],
                "note": "While Madeira keeps a game or a download running in the background, its CPU use is held under "
                        "this percent of one core on average (threads are paused for 100 ms at a time when it is over), "
                        "because iOS ends a background app that averages more than about 80% for a minute. Higher loads "
                        "faster but risks that. 0: no cap. A game's own config can set it. [bg-cpu] lines in the log."},
    "background-download": {"category": "App & front end", "title": "Keep downloads running in the background (minutes)",
                "kind": "int", "default": "60", "sources": ["app/Madeira/BackgroundRun.swift"],
                "note": "Minutes a Steam, Epic, GOG, EA or itch.io download keeps going after you switch apps or lock "
                        "the screen. Then it pauses cleanly and continues when Madeira is active again. 0: only iOS's "
                        "short grace period, as before."},
    "background-sound": {"category": "App & front end", "title": "Game sound in the background",
                "kind": "bool", "default": "0", "sources": ["app/Madeira/BackgroundRun.swift"],
                "note": "Off by default: while a game keeps running in the background its sound is muted, and other "
                        "apps' audio plays normally. 1: you keep hearing the game. A game's own config can set it."},
    "env.MADEIRA_PASTE_INTERVAL_MS": {"category": "Windows, display & input", "title": "Clipboard typing interval (ms)",
                "kind": "int", "default": "10",
                "note": "Default 10 ms between pasted characters. Range 1-100 ms; use a longer interval for games "
                        "that miss fast text input. Enforced at delivery as well as queueing. Restart the session after changing it."},
    "env.MADEIRA_DOCK_STEAM_RUN": {"category": "Steam & Dock", "kind": "bool", "default": "1",
                "note": "On by default: when a game in a Madeira Dock session asks Steam to start another game "
                        "(steam.exe with steam://run/<App ID>, as Black Ops II's campaign does for Zombies), "
                        "steam.exe is not started and Madeira starts that game when it is next opened. 0 lets "
                        "steam.exe start as before (the full Steam client, which updates itself and stops at a "
                        "black window in a Dock session).",
                "sources": ["build/ntdll-unix/process_ios.c"]},
    # The iOS audio driver (build/ntdll-unix/audio_null_ios.c): the two a player may need.
    "env.MADEIRA_AUDIO_LEAD_MS": {"category": "Audio", "title": "Sound buffer",
                "kind": "choice", "default": "",
                "choices": [("", "60 ms (default)"), ("100", "100 ms"), ("150", "150 ms"), ("200", "200 ms"),
                            ("300", "300 ms")],
                "note": "How much sound Madeira keeps queued ahead of the speaker (10-500 ms, default 60). If a "
                        "game's sound crackles or sounds scratchy, a larger buffer usually clears it, at the cost "
                        "of sound lagging slightly behind the picture: Black Ops II's Zombies crackled at 60 ms "
                        "and was clean at 150. A game's own config can set it for that game alone. Applies at "
                        "the next game start."},
    "env.MADEIRA_AUDIO_DOWNMIX": {"category": "Audio", "title": "Mix surround sound down to stereo",
                "kind": "bool", "default": "1",
                "note": "On by default: a game that plays 5.1 or 7.1 sound has every channel folded into the "
                        "two speakers, so voices (in the centre channel), bass and the rear channels are heard. "
                        "Off keeps only the front left and right channels, as Madeira did before, which loses "
                        "most dialogue in a surround game. Applies at the next game start."},
    "env.MADEIRA_PIN_GRAPHICS_DLLS": {"category": "Memory & JIT pool", "title": "Keep graphics DLLs loaded",
                "kind": "bool", "default": "0",
                "note": "Default off. On a D3D12 device/probe call, pins already loaded D3D12, DXGI and Wine Metal "
                        "DLLs until normal process shutdown, preventing repeated unload/reload copies. Keeps DLL "
                        "data live; does not recycle executable ranges or change GPU capabilities. Restart the "
                        "session after changing it.",
                "sources": ["madeira-d3d12/src/pe/madeira_d3d12.c"]},
    "env.MADEIRA_APP_DLL_SHADOW": {"category": "Wine core (ntdll)", "title": "Ignore these DLLs in the game's folder",
                "kind": "text", "default": "",
                "note": "Default empty. DLL names separated by ';' (e.g. vcruntime140.dll): a plain x64 copy of one of "
                        "them outside C:\\windows (the game's own folder) is reported as not loadable, so the loader "
                        "binds the system's, as it already does for ucrtbase.dll. For a game that ships Microsoft's "
                        "x64 vcruntime140.dll but not msvcp140.dll: Wine's msvcp140 cannot call that x64 copy "
                        "(Crysis 3 Remastered: \"MSVCP140.dll failed to initialize\", c000001d). Logged as "
                        "[app-dll-shadow]. Read at every DLL load.",
                "sources": ["build/ntdll-unix/virtual_ios.c"]},
    "env.MADEIRA_PRELOAD_DLLS": {"category": "Memory & JIT pool", "title": "Load these DLLs with the D3D12 device",
                "kind": "text", "default": "",
                "note": "Default empty. DLL names separated by ';' (e.g. xinput1_4.dll): each program loads and pins "
                        "them at its first D3D12 device or probe call, while the JIT pool still has room for their "
                        "copies. RDR2 loads xinput1_4.dll only at its first controller read, and on build 476 the "
                        "pool was full by then: no controller and no on-screen controls. Restart the session after "
                        "changing it.",
                "sources": ["madeira-d3d12/src/pe/madeira_d3d12.c"]},
    "env.MADEIRA_POOL_RECYCLE_IMAGES": {"category": "Memory & JIT pool", "title": "Images in retired code-buffer space",
                "kind": "bool", "default": "0",
                "note": "Default off. If other image allocations fail, retired region-C code buffers up to 64 MB "
                        "may enter the image freelist after a 3-second grace, executable-page and thread-PC checks. "
                        "Requires pool-low; 64-bit processes only. Live buffers and the pool-low-margin stay unchanged."},
    "env.MADEIRA_POOL_CODE_EXIT_RECLAIM": {"category": "Memory & JIT pool", "title": "Return an exited program's code buffers",
                "kind": "bool", "default": "1",
                "note": "On by default. When a program of the session exits (a launcher restarting itself, "
                        "RockstarService.exe, a setup step), the emulator's code buffers it held go back to the JIT "
                        "pool: reusable 3 seconds later, once no thread runs in them. Before, they stayed in use "
                        "until Madeira closed, and a game started after many such exits got 16 MB code buffers and "
                        "ran slowly. 0 keeps them in use, as before."},
    "env.MADEIRA_X64_IMAGE_NOCOPY": {"category": "Memory & JIT pool", "title": "Pure-x64 images without a JIT-pool copy",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: an x64-only image (not ARM64EC hybrid, not a Wine builtin) in a 64-bit "
                        "process is not copied into the JIT pool; the emulator runs its code from the loaded "
                        "image, as 32-bit programs already do, and its executable protections are applied without "
                        "EXEC. Frees the pool for hybrid DLL copies and code buffers. Hybrid images keep their "
                        "copy. Set it in the game's own file; restart the session after changing it."},
    "env.MADEIRA_FIXED_BASE_GUARD": {"category": "Memory & JIT pool", "title": "Keep 0x140000000 for a fixed-base game",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a resource-only image view (a version or resource query, e.g. the Rockstar "
                        "Games Launcher reading Social-Club-Setup.exe) never takes the reserved executable window at "
                        "0x140000000; it is mapped elsewhere. The window then stays free for a game exe without "
                        "relocations that can only run there (Red Dead Redemption 2). It moves other programs' "
                        "images too (GTA V Enhanced's, for one), so set it only in such a game's own file; read at "
                        "session start."},
    "env.MADEIRA_RDR2_VA_HOLD": {"category": "Memory & JIT pool", "title": "Keep 8960 MB free for Red Dead Redemption 2",
                "kind": "bool", "default": "0",
                "note": "Default off; only with env.MADEIRA_SC_PA_POOLS = 2. 1: Social Club's layout 2 keeps libcef.dll's "
                        "PartitionAlloc pools at 256 MB and its metadata at 1 GB, chrome_elf.dll's metadata at 6.25 GB, "
                        "gives the rest of the app's 4 GB hold to Wine's furniture (3.75 GB more room for threads and "
                        "allocations), keeps Oilpan's cage at 1 GB so the FEX arena grows to 15 GB, and holds "
                        "[0x75d0000000, 0x7800000000) from boot for one 8960 MB reserve, the one "
                        "Red Dead Redemption 2 makes as it starts. Set it only in that game's own file; GTA V keeps "
                        "layout 2 as it is. Read at session start."},
    "env.MADEIRA_SWAP_RESERVE_MAX_MB": {"category": "Memory & JIT pool", "title": "Swap tier: largest reservation backed (MB)",
                "kind": "int", "default": "", "sources": ["build/ntdll-unix/virtual_ios.c"],
                "note": "The largest new reservation the swap tier backs whole: 256 MB in wide (at most 4 GB), 8 GB in "
                        "broad (at most 16 GB). 9216 with broad coverage (swap-mode = 2) also backs Red Dead "
                        "Redemption 2's 8960 MB heap with the file. Read at session start."},
    "env.MADEIRA_THREAD_STACK_SPILL": {"category": "Memory & JIT pool", "title": "New threads may use the kernel's pick when memory space is full",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a new thread's 1 MB kernel stack (and its emulator stack) is looked for from "
                        "the start of Wine's furniture band instead of from 4 GB (each new thread no longer tries "
                        "about 300 refused addresses first), and when that band is full the kernel places it "
                        "anywhere still free instead of the thread failing. Red Dead Redemption 2 froze four minutes "
                        "into the story because every new thread failed this way while 1.8 GB was free elsewhere. "
                        "Read at session start."},
    "env.MADEIRA_SMALL_STACK_EXES": {"category": "Memory & JIT pool", "title": "Programs whose threads keep a 2 MB stack",
                "kind": "text", "default": "",
                "note": "Empty by default: every thread stack is at least 8 MB (Chromium needs that). Exe names, "
                        "separated by commas (e.g. RDR2.exe): threads of these programs get the stack they ask for, "
                        "at least 2 MB, so their stacks take less of the shared memory space. Never list Chromium "
                        "programs (SocialClubHelper.exe, Launcher.exe, steamwebhelper.exe). Read when a thread starts."},
    "quiet-log": {"category": "Direct3D 12", "title": "Cheaper Direct3D 12 logging (no census frames)",
                "kind": "bool", "default": "0",
                "note": "1: the Direct3D 12 runtime's log lines skip OutputDebugString (an exception and a server "
                        "request each, ~0.5 ms a line on the device) and reach the log through Wine's own debug "
                        "output and stderr only; the census frames between presents 1500 and 3000 and the list "
                        "12000-12400 draw dumps are off (each froze the game for 1-2 s); the per-shader "
                        "\"converted at runtime\" line is kept for the first 64 shaders and then every 1000th. "
                        "A manual frame capture still works. Default off: the logging as before."},
    "replay-split": {"category": "Direct3D 12", "title": "Log where Direct3D 12 submission time goes",
                "kind": "bool", "default": "0",
                "note": "Default off, logging only. 1: every 5 seconds a [perf] replay split line divides the time "
                        "ExecuteCommandLists takes per frame into waiting for the queue, preparation, opening a "
                        "command buffer, each kind of command (draws, dispatches, copies, clears, barriers, render "
                        "targets, queries, state) and the end of each list. For finding why a game's frame is slow "
                        "when the GPU is not busy."},
    "env.MADEIRA_MFC": {"category": "Wine libraries", "title": "Microsoft MFC (mfc140.dll, mfc140u.dll)",
                "kind": "bool", "default": "1",
                "note": "On by default. MFC comes from the same Microsoft VC++ package as the C++ runtime and is "
                        "linked into the game's system32; games that import it (Horizon Zero Dawn) stop at once "
                        "without it. Wine has no MFC of its own. 0 leaves it out. Read at session start."},
    "fullscreen-window": {"category": "Direct3D 12", "title": "Full screen moves the game's window over the whole screen",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: when a Direct3D 12 game switches to full screen, its window is moved to the "
                        "screen's top-left corner and over the whole screen first, as Windows does; the game then "
                        "sizes it to the chosen mode. Without it a game that only resizes its window (Red Dead "
                        "Redemption 2) keeps it where it was, beside the Wine desktop. Read once per session."},
    "encode-batch": {"category": "Direct3D 12", "title": "One Metal call per encoder, not per draw",
                "kind": "bool", "default": "1",
                "note": "Default on. The commands a replay hands to one Metal encoder (every draw's state and draw, the "
                        "encoder's fence wait and update) are queued and handed over in one call when the encoder ends, "
                        "instead of one call into the Metal bridge per draw: the same commands in the same order, with "
                        "~1,500 fewer crossings a frame in Horizon Zero Dawn. 0: one call per draw, as before (for "
                        "telling a regression apart on the device). Read once per game start."},
    "draw-dedup": {"category": "Direct3D 12", "title": "Leave out render state the encoder already has",
                "kind": "bool", "default": "1",
                "note": "Default on. A draw no longer sends Metal the pipeline, viewport, scissor, depth-stencil state, "
                        "blend colour, rasterizer state or buffer bindings the render encoder already holds from the "
                        "draw before it; a buffer bound again with only a new offset is sent as an offset. Every draw "
                        "still runs with exactly the state it set (about half of a Horizon Zero Dawn draw's Metal "
                        "calls were such repeats). 0: every draw sends all of it, as before. Read once per game start."},
    "addr-scan": {"category": "Direct3D 12", "title": "Quicker GPU-address lookups",
                "kind": "bool", "default": "1",
                "note": "Default on. Finding the buffer behind a GPU address (every vertex buffer, index buffer and root "
                        "descriptor a game records) walks back only over entries that can still reach the address, "
                        "instead of over every buffer within the largest buffer's size of it (124 MB in Horizon Zero "
                        "Dawn). The same buffer is found. 0: the old walk. Read once per game start."},
    # madeira-bcd: winemetal reads it (dxmt, the rp-lean change of this wave).
    "rp-lean": {"category": "Direct3D 12", "title": "Render passes fill only the targets they use",
                "kind": "bool", "default": "1",
                "note": "Default on. A Metal render pass is described with only the colour targets it uses; the bridge "
                        "filled all eight slots for every pass (~240 Objective-C calls and 8 allocations a pass, a few "
                        "hundred passes a frame). Metal ignores a slot without a texture, so the pass is the same. "
                        "Also used by Direct3D 9/10/11 games through DXMT. 0: all eight slots, as before. Read once "
                        "per game start."},
    "indirect-fast": {"category": "Direct3D 12", "title": "Encode ExecuteIndirect records without per-record setup",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: after the first record of an ExecuteIndirect, the other records (which share "
                        "all state but their offset) are encoded 64 at a time with only their offset and the "
                        "indirect draw or dispatch, instead of the whole per-draw setup each. For games that issue "
                        "thousands of indirect records a frame (Red Dead Redemption 2), where that setup costs more "
                        "CPU time than the GPU spends. DXIL and DXBC pipelines (DXBC from build 470); pipelines "
                        "with tessellation or geometry stages, diagnostics and captures keep the per-record path. "
                        "Read once per session."},
    "dxbc-register-spaces": {"category": "Direct3D 12", "title": "Shader model 5.1 resources in register spaces other than 0",
                "kind": "bool", "default": "0",
                "note": "Default off: a DXBC shader (shader model 5.1) that declares a resource in a register space "
                        "other than 0 is refused, and its pipeline is not created. 1: such shaders are converted, and "
                        "each resource is bound from the root-signature entry with the same space and register. "
                        "Horizon Zero Dawn needs it (its constant buffers sit in spaces 6 and 8). Shaders converted "
                        "with it on are cached apart from the others. Read once per session.",
                "sources": ["madeira-d3d12/src/unix/madeira_ir_unix.mm", "madeira-d3d12/src/pe/madeira_d3d12.c"]},
    "env.MADEIRA_GAME_DIALOG_CURSOR": {"category": "Windows, display & input", "title": "Cursor over a game's launcher or message box",
                "kind": "bool", "default": "1",
                "note": "Default on. A game session draws no cursor: the finger is the pointer. While the game shows a "
                        "launcher or message box, the arrow is drawn where the finger last touched (where the click "
                        "lands) and goes away with the box. Tap the button itself to press it. 0: no cursor, as "
                        "before. Desktop (Dock) sessions keep their own cursor."},
    # madeira-bcd: Horizon Zero Dawn on build 471 got no input at all.
    "env.MADEIRA_INPUT_FOREGROUND": {"category": "Windows, display & input",
                "title": "Bring the game to the front when no window is",
                "kind": "bool", "default": "0",
                "note": "Default off. iOS has no window manager: a game that shows its window without activating "
                        "it and reads no XInput stays in the background, and Windows sends raw keyboard and mouse "
                        "input only to the program in front (Horizon Zero Dawn ignored every key and tap). 1: while "
                        "no window at all is in front, the game's main window is brought to the front when it polls "
                        "its messages or a key or tap arrives. Never while another window is in front."},
    "env.MADEIRA_WGI_HOST_PADS": {"category": "Controllers", "title": "Controllers in Windows.Gaming.Input",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: each connected XInput controller (a paired pad or the touch controller) "
                        "is also a Windows.Gaming.Input gamepad, an Xbox pad to the game, with rumble. For games "
                        "that read their controller only that way (Horizon Zero Dawn); a game that also reads "
                        "XInput could list it twice. Read when the game first asks for a gamepad."},
    # madeira-bcd: Red Dead Redemption 2 on build 470, 1.5 GB of argument-ring chunks.
    "ind-probe": {"category": "Direct3D 12", "title": "ExecuteIndirect probe (diagnostic)",
                "kind": "bool", "default": "1",
                "note": "Default on. Every 3 s per pipeline, the first argument record of an ExecuteIndirect is read "
                        "back by a small compute pass and logged as a [probe] line, 1500 lines at most. Each probe "
                        "ends the open render pass. 0: no probes (Red Dead Redemption 2's list, build 476)."},
    # madeira-bcd: Horizon Zero Dawn's refused shaders (build 475, 2026-10-09 16:20).
    "msc-unbounded-retry": {"category": "Direct3D 12", "title": "Retry refused shaders with sized unbounded ranges",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a DXIL shader the converter refuses with code 4 (a resource not in the root "
                        "signature) is converted once more with the root signature's unbounded descriptor ranges "
                        "given a size (2048 samplers, 1000000 others). Horizon Zero Dawn's ranges start at register 4 "
                        "and ~4,900 of its shaders were refused. Once that works for a root signature, its later "
                        "shaders take the sized ranges first."},
    "pso-placeholder": {"category": "Direct3D 12", "title": "Placeholder for pipelines whose shaders did not convert",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a graphics pipeline whose vertex or pixel shader did not convert is returned "
                        "to the game as a placeholder whose draws are skipped, instead of a failure. Horizon Zero "
                        "Dawn stopped with an \"Error\" box when its settings menu got such a failure."},
    # madeira-bcd: Horizon Zero Dawn's 23,045 libraries (build 480, 2026-10-09 20:28).
    "pso-lazy-libs": {"category": "Direct3D 12", "title": "Shader libraries only for pipelines in use",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a pipeline built at its first draw (or dispatch) lets its converted Metal "
                        "libraries go once the game has created it, and reads them back from the shader cache at "
                        "that first draw. Horizon Zero Dawn creates ~52,000 pipelines in its menu and draws a few "
                        "thousand; their libraries held hundreds of MB until iOS closed the game. Needs the shader "
                        "cache (on by default); with pso-warm, a library stays until its warm-up compile is done."},
    # madeira-bcd: Horizon Zero Dawn's corrupted first gameplay frames (build 480, 2026-10-09 20:37).
    "clear-rects": {"category": "Direct3D 12", "title": "Clear only the rectangles a game asks for",
                "kind": "bool", "default": "0",
                "note": "Default off: a render-target or depth-stencil clear with rectangles clears the whole view, as "
                        "before. 1: only the rectangles are cleared, in a small pass of their own (as DXMT's D3D11 "
                        "ClearView does); a rectangle that covers the view still clears it the fast way. Horizon Zero "
                        "Dawn passes rectangles from its first gameplay frames."},
    # madeira-bcd: render-pass memory traffic (Horizon Zero Dawn ~1.9 GB a frame through attachments, build 493).
    "clear-defer": {"category": "Direct3D 12", "title": "Clears wait for the pass that draws to their target",
                "kind": "bool", "default": "1",
                "note": "On by default. A whole render-target or depth-stencil clear becomes the clear the next "
                        "render pass that draws to that target starts with: a clear no longer ends the pass in "
                        "progress unless it is one of that pass's own targets, and needs no pass of its own (which "
                        "wrote the whole target to memory and read it back later). A barrier or copy that names the "
                        "cleared texture, or a pass or clear that uses it through another view, applies the clear "
                        "first, so nothing sees it uncleared. 0: every clear ends "
                        "the open pass and goes before the next pass on its own, as before. Read once per game start."},
    "rp-carry": {"category": "Direct3D 12", "title": "Experiment: render passes go on into the next command list",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: when a command list ends inside a render pass and the next list of the same "
                        "submission draws to the same targets first, with only state between the two draws, the pass "
                        "stays open: its targets are not written to memory and read back. Horizon Zero Dawn records "
                        "its depth and G-buffer passes in ~20 lists (0.3-0.6 GB a frame of such writes and reads), "
                        "GTA V Enhanced its G-buffer in ~12. Opt-in: the second list's draws no longer wait for the "
                        "whole first pass, an ordering Direct3D 12 does not promise but a game might rely on. Read "
                        "once per game start; [perf] gpu-traffic lines show what it saves."},
    "rp-discard": {"category": "Direct3D 12", "title": "Experiment: no load after, no store before DiscardResource",
                "kind": "bool", "default": "0", "sources": ["madeira-d3d12/src/pe/madeira_d3d12.c"],
                "note": "Default off. 1: after a game discards a whole render target or depth buffer "
                        "(DiscardResource), the next render pass that draws to it does not read its old contents "
                        "from memory, and a pass whose target is discarded (or cleared whole) next, before any other "
                        "use in the same submission, does not write it back -- as tile-based GPUs do on Windows. "
                        "Opt-in: a game that still reads what it discarded (desktop GPUs ignore discards) would show "
                        "garbage there. Read once per game start; [perf] gpu-traffic lines show the bytes."},
    "f6-rar": {"category": "Direct3D 12", "title": "Experiment: fence-chain 6 ignores read-to-read barriers",
                "kind": "bool", "default": "0",
                "note": "Default off; only with fence-chain = 6. 1: a ResourceBarrier whose every transition goes "
                        "from read states to read states (or is the first half of a split barrier) no longer makes "
                        "the next GPU pass wait for all earlier ones, and no longer ends an overlapping render pass "
                        "(which writes its targets to memory and reads them back). Direct3D 12 orders nothing at "
                        "such a barrier; a game that relied on it anyway would show flicker. Read once per game "
                        "start; [perf] f6-rar lines count them."},
    "skin-check": {"category": "Direct3D 12", "title": "Diagnostic: check meshes skinned on the GPU",
                "kind": "int", "default": "0",
                "note": "Default 0 (off). N: windows of N frames (1 = 8) log every draw that reads a vertex buffer a "
                        "compute shader wrote, the dispatches that wrote it with every binding, a summary of up to "
                        "32 KB of each such stream copied just before the draw, and the shaders' bytecode. For "
                        "characters drawn with missing faces or spikes (Horizon Zero Dawn); costs time in those frames."},
    "skin-check-every": {"category": "Direct3D 12", "title": "Diagnostic: presents between skin-check windows",
                "kind": "int", "default": "300",
                "note": "With skin-check on: a window starts this many presents after the previous one began "
                        "(at least 30); the first starts 60 presents after the first such draw."},
    "skin-check-capture": {"category": "Direct3D 12", "title": "Diagnostic: skin-check copies the streams",
                "kind": "bool", "default": "1",
                "note": "On by default with skin-check. 0: log only, with no GPU copies, which add a copy between "
                        "the skinning dispatches and the draw (to compare what the frames look like)."},
    "view-census": {"category": "Direct3D 12", "title": "Diagnostic: report buffer views that fall back",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: typed buffer views that cannot become a Metal texture buffer (the shader then "
                        "sees no data), views cut short at the end of their resource, and views or constant buffer "
                        "views past their resource are counted and named in the log, with Metal's minimum alignment "
                        "for each pixel format typed views use. Changes nothing else."},
    "skin-check-trace": {"category": "Direct3D 12", "title": "Diagnostic: skin-check traces whole frames",
                "kind": "bool", "default": "0",
                "note": "Default off. 1, with skin-check on: the first frame of the first two windows logs every draw "
                        "in one line (shaders, counts, streams, input layout); a pipeline with integer vertex inputs "
                        "(a mesh skinned in its vertex shader) also gets its vertex-stage bindings, copies of its "
                        "CPU-written inputs and first vertices, and its vertex shader's bytecode (32 such draws)."},
    "skin-dump": {"category": "Direct3D 12", "title": "Diagnostic: skin-check dumps the skinning data",
                "kind": "bool", "default": "0",
                "note": "Default off. 1, with skin-check on: in the first window's first two frames the compute "
                        "shaders that skin a mesh have their inputs and the stream they wrote copied whole (up to 256 KB "
                        "each) and logged as base64 (4 MB at most), so the skinning can be recomputed on a PC. Uses a "
                        "24 MB capture buffer."},
    "typed-view-align": {"category": "Direct3D 12", "title": "Typed buffer view alignment",
                "kind": "int", "default": "0",
                "note": "Default 0 (64 bytes, as before). 16 or 256: a typed buffer view's texture starts at that "
                        "boundary, never below Metal's minimum for its format (logged once per format); 16 is what "
                        "Apple's converter documents, so a float4 view has no padding elements. 4: every view's texture "
                        "starts exactly at its first element, for the element sizes a GPU probe at the first view shows "
                        "read right (logged); the others start at 16. A view Metal refuses there is made at 16, then 64. "
                        "Read once per game start."},
    "typed-view-shadow": {"category": "Direct3D 12", "title": "Aligned copies of offset typed views",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a typed shader-resource view of UPLOAD memory whose first element is not on a "
                        "16-byte boundary reads a 16-byte-aligned copy of its bytes, made when the view is made and "
                        "refreshed at every ExecuteCommandLists (the GPU rounds a texture buffer's start down to 16 bytes "
                        "and the shader converter ignores the element offset). view-census counts them. Read once per "
                        "game start."},
    "vis-trace": {"category": "Direct3D 12", "title": "Diagnostic: per-frame draws and culling readback",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: one log line per present (the HUD's frame number): draws, depth-only and "
                        "3+-target draws, indices, dispatches, depth-pyramid readback copies, new offset typed views, and "
                        "Queue::Wait calls (how many passed before the awaited batch was committed); and every value of the "
                        "22x10, 11x5 and 5x2 mips of the pyramid a game culls with, as the GPU wrote them. The GPU also "
                        "copies each of those mips into Madeira's own memory, and a mip whose readback memory holds "
                        "something else is flagged (an earlier frame's values: STALE). Read once per game start."},
    "readback-far": {"category": "Direct3D 12", "title": "Experiment: empty culling readback",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a readback of a depth pyramid (an R32_FLOAT mip of 1 or more of a texture with 4+ "
                        "mips, up to 64x64) is not copied; the CPU fills it with 4096, so a game that culls on the CPU "
                        "against it culls nothing (everything is drawn: slower). A test, not a fix. Read once per game "
                        "start."},
    "static-cbv": {"category": "Direct3D 12", "title": "Constant buffers as the draw was recorded",
                "kind": "int", "default": "0",
                "note": "Default off: the GPU reads every descriptor of a table when it runs. 1: a descriptor table's "
                        "single constant-buffer ranges are read when each draw or dispatch is recorded, as NVIDIA's "
                        "driver and vkd3d-proton do; a game that rewrites one after recording the draw no longer makes "
                        "that draw use another object's constants. Ranges marked VOLATILE stay as before. 2: VOLATILE "
                        "ones too (vkd3d-proton's force_static_cbv). 3: only count the rewrites ([static-cbv] lines). "
                        "Read once per game start."},
    "readback-swap": {"category": "Direct3D 12", "title": "D3D12 readback buffers on file-backed memory",
                "kind": "bool", "default": "1",
                "note": "Default on: like upload buffers (upload-swap), READBACK buffers of 8 MB or more live on "
                        "file-backed storage, off the memory footprint. 0: READBACK buffers get Metal's own memory "
                        "(Horizon Zero Dawn: two 32 MB buffers), so what the GPU writes into them reaches the CPU "
                        "without the file tier between; upload buffers stay where upload-swap puts them. Read once per "
                        "game start."},
    # madeira-bcd: A/B switches for the Sony ports' corrupted meshes (Horizon Zero Dawn, Ghost of Tsushima).
    "d3d12-wave-ops": {"category": "Direct3D 12", "title": "Report wave operations",
                "kind": "bool", "default": "1",
                "note": "On by default. 0: OPTIONS1 reports WaveOps FALSE, so a game with a fallback picks shaders "
                        "without wave intrinsics (an A/B for the shader converter's wave code; Horizon Zero Dawn reads "
                        "it). Read once per game start."},
    "d3d12-binding-tier": {"category": "Direct3D 12", "title": "Reported resource binding tier",
                "kind": "int", "default": "2",
                "note": "Default 2. 3: OPTIONS reports resource binding tier 3, as Apple's D3DMetal and vkd3d-proton do; "
                        "a game can take another binding path for it. Anything else keeps tier 2. Read once per game "
                        "start."},
    "d3d12-raw-typed-views": {"category": "Direct3D 12", "title": "Raw buffer views readable as typed",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: raw and structured buffer views also carry a texture-buffer view (R32, or "
                        "RG32/RGBA32 for a structured SRV whose stride allows it), as native drivers and vkd3d-proton "
                        "do, so a shader that reads one as Buffer<T> gets the data instead of zeros (vertices at the "
                        "origin). Costs one Metal texture object per such view."},
    "msc-fail-memo": {"category": "Direct3D 12", "title": "Remember refused shaders for the session",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a shader the converter refused is not converted again for the next pipeline "
                        "that uses it (same bytecode, root signature and options) until the game exits. Horizon Zero "
                        "Dawn converted each refused shader ~6 times, ~30,000 conversions in its first minutes."},
    "ring-share": {"category": "Direct3D 12", "title": "Share argument buffers between command lists",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a command list gives the argument-buffer chunks its replay wrote back as "
                        "soon as the GPU is done with them, instead of keeping them until it is recorded again; "
                        "all lists then share one pool. Red Dead Redemption 2 kept 1.5 GB of them (half of its "
                        "Metal memory) with the switch off."},
    # madeira-bcd: winemetal reads it (dxmt, the null-fragment change of this wave).
    "gs-null-fragment": {"category": "Direct3D 12", "title": "Empty fragment function for pipelines without a pixel shader",
                "kind": "bool", "default": "1",
                "note": "Default on. Metal aborts on a mesh pipeline (geometry shader or tessellation emulation) "
                        "with rasterization on and no fragment function, while D3D allows a pipeline with no pixel "
                        "shader. On: such a pipeline gets an empty fragment function and writes no render target, "
                        "as in D3D; depth and stencil work as before. Horizon Zero Dawn's pipeline thread died "
                        "without it and the game stopped after its first frame. 0: such a pipeline is refused "
                        "instead (the geometry shader is dropped). Pipelines with a pixel shader are not touched. "
                        "Read once per session."},
    "env.MADEIRA_BAND_CENSUS": {"category": "Debugging / logs", "title": "Log the 64 GB address band by piece",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: about once a minute and when a large reserve fails, [band] lines say what "
                        "each piece of [0x7000000000, 0x8000000000) uses (Social Club's pools and metadata, the "
                        "furniture, the V8 and Oilpan cages, the FEX arena), the largest free gap, and whether Red "
                        "Dead Redemption 2's 8960 MB reserve fits; 64 censuses at most. Logging only, changes no "
                        "placement; read at session start."},
    "env.MADEIRA_EC_HOOK_TRACE": {"category": "Debugging / logs", "title": "Log code patches the emulated copy misses",
                "kind": "bool", "default": "0",
                "note": "Default off, logging only. 1 compares executable PE sections and their pool copies before "
                        "sync, including x64 entry thunks. Separate budgets preserve later graphics-jump records "
                        "after native startup rewrites. A difference alone does not prove an inline hook."},
    # Upstream's switch (build/ntdll-unix/signal_arm64_ios.c); this wave's ntdll change adds
    # mode 2, which every game list sets.
    "env.MADEIRA_CTX_CPU_AREA": {"category": "Exceptions & threads", "title": "Cross-thread GetThreadContext from the x64 snapshot",
                "kind": "choice", "default": "",
                "choices": [("", "Off (default)"), ("1", "Control registers"), ("2", "Control and integer registers")],
                "note": "Another thread's GetThreadContext when the server has no control registers for it. Unset or "
                        "0 (default): off; the answer is the server's registers. 1 (upstream's opt-in): the control "
                        "registers (Pc/Sp/Fp/Lr) from the thread's last exit from emulated code. 2: also the integer "
                        "registers the caller asked for, and Cpsr 0, from the same snapshot; madeira-bcd's default "
                        "behaviour, which every game list sets (Ghost of Tsushima's loading screen froze without it). "
                        "The snapshot is where the thread last left emulated code, not where it is now: a context "
                        "written back moves the thread back there."},
    "env.MADEIRA_X64_GRAPHICS_ENTRY": {"category": "Direct3D 12", "title": "Patchable x64 graphics method entries",
                "kind": "bool", "default": "0",
                "note": "Default off. 1 exposes typed x64 ARM64EC entries for swapchain Present/Present1, "
                        "ResizeBuffers/ResizeBuffers1 and queue ExecuteCommandLists/GetTimestampFrequency/GetClockCalibration/GetDesc/Signal/Wait. "
                        "With a DXMT dxgi that has the x64 entries, "
                        "also selects the factory's patchable MakeWindowAssociation and swapchain-creation entries. "
                        "The x64 entries use the loader's PE addresses so code patches and nearby allocations agree. "
                        "Existing native implementations remain behind the entries. Restart the game session."},
    "env.MADEIRA_POOL_LOW_IMAGES": {"category": "Memory & JIT pool", "title": "Small images in spare code-buffer space",
                "kind": "bool", "default": "0",
                "note": "Default off. If the normal JIT image allocation fails, copies up to 16 MB may use "
                        "unallocated region C, preserving 4 MB for code buffers. Requires pool-low; 64-bit "
                        "processes only. Does not shrink live buffers or the pool-low-margin."},
    "env.MADEIRA_IMAGE_PATCH_TRACE": {"category": "Debugging / logs", "title": "DLL code patch trace", "kind": "bool", "default": "0",
                "note": "1 logs up to 64 successful 1–16 byte executable-image protection requests and their PE/pool bytes. Read-only, owner-aware diagnostics; does not alter hooks or code."},
    "env.MADEIRA_MOUSE_ROUTING": {"title": "Mouse routing and pointer-lock fixes",
        "note": "Default on. 0 restores the previous desktop cursor routing, mouse button callbacks, surface-touch handling and key-window-only pointer lock. Keyboard input and manual Ctrl+Alt+P remain available. Fully restart Madeira after changing this switch."},
    "donor-pool-mb": {"category": "Memory & JIT pool", "title": "Donor pool size", "kind": "choice",
                "note": "ml1150: RAM for the swap tier that is not counted against Madeira's limit, donated by the MadeiraMemoryHost extension (512 MB regions, created untouched, handed over, then the extension exits). With swap-mb it is the swap tier's first stage, taken before the swap file; without swap-mb it is the only stage (ml2200 donor-only, madeira.cfg donor-only = 0 turns that off) and what it cannot cover stays normal app memory. Taken while free RAM stays above MADEIRA_DONOR_POOL_MARGIN_MB and iOS reports no memory pressure. Off by default; read at launch.",
                "choices": [("", "Off"), ("2048", "2 GB"), ("4096", "4 GB"), ("6144", "6 GB")]},
    "donor-only": {"category": "Memory & JIT pool", "title": "Donor pool without a swap file", "kind": "bool", "default": "1",
                "note": "ml2200: on (the default), donor-pool-mb set and swap-mb unset start the swap tier with the donor pool as its only "
                        "stage: no swap file is made, and memory the pool cannot cover stays normal app memory (iOS compresses it "
                        "inside the app's limit). 0: without swap-mb the donor pool is not started, as before. Read at launch."},
    "env.MADEIRA_REPLY_OWN_WRITABLE": {"category": "Memory & JIT pool", "title": "Server replies: a writable page is written in place", "kind": "bool", "default": "1",
                "note": "ml2230: on (default): a server reply whose buffer lies in the JIT pool's address range but on a page that is writable at its own address (a page the pool gave up, which the system reused for a thread stack) is stored there, not through the pool's RW alias, which has no mapping for it. Before, a child process could die in its first reply (log 111: rpcss.exe, and the Steam client waited for it forever). 0: the pool's address range alone decides, as before."},
    "env.MADEIRA_CEF_VERBOSE": {"category": "Steam & Dock", "title": "Steam web helper: verbose CEF log", "kind": "bool", "default": "1",
                "note": "ml2230: on (default): steamwebhelper.exe gets --enable-logging=file --v=1 --log-severity=verbose, CEF's verbose file log. 0 (the Steam Big Picture list): Steam's own log level, which saves the UI threads the writes."},
    "env.MADEIRA_BIG_PICTURE_GPU": {"category": "Steam & Dock", "title": "Big Picture: draw the UI with the GPU", "kind": "bool", "default": "0",
                "note": "ml2230: 1 starts steam.exe without -cef-disable-gpu, so the web helper may draw with Chromium's ANGLE on the 32-bit D3D11 (DXMT) instead of the CPU. Off by default (software drawing, as before); a test switch."},
    "env.MADEIRA_BIG_PICTURE_LIBRARIES": {"category": "Steam & Dock", "title": "Big Picture: list Madeira's Steam games", "kind": "bool", "default": "1",
                "note": "ml2230: on (default): before each Big Picture start, Big Picture's libraryfolders.vdf (config/ and steamapps/) gets Madeira's Steam library (the Dock client's folder) and the libraries on connected drives, beside the client's own entries, so the games Madeira installed show as installed. 0: the files are left alone."},
    "env.MADEIRA_SUBFLOOR_HIGH": {"category": "Memory & JIT pool", "title": "Images based just above 4 GB run through a window", "kind": "bool", "default": "1",
                "note": "ml2240: on (default): a 64-bit exe or DLL without relocations whose base lies between 4 GB and the start of the app's address space (an old x64 linker's default 0x100000000, which iOS never maps) is mapped elsewhere, its header names the real base, and its own preferred-base addresses are served by the fault handler and FEX, as below 4 GB. The range is used only when a fixed allocation at its first and last page is refused as outside the map. Before, such an image failed to start (c0000018; log 115: the DirectX redistributable's x64 installer helper, so a game's first-run install script stopped). 0: the 4 GB limit, as before."},
    "env.MADEIRA_BIG_PICTURE_DOCK_LIBRARIES": {"category": "Steam & Dock", "title": "Big Picture: every library Madeira lists", "kind": "bool", "default": "1",
                "note": "ml2240: on (default): Big Picture's libraryfolders.vdf gets every library Madeira's Steam list reads: the Dock client's folder, the other C: libraries its libraryfolders.vdf names and the external drives' libraries. The log names each library with its number of install records. 0: only the Dock client's folder and the external drives (ml2230)."},
    "env.MADEIRA_SRW_HANG_DIAG_S": {"category": "Exceptions & threads", "title": "Diagnostic: 32-bit SRW-lock hangs", "kind": "int", "default": "30",
                "note": "ml2250: a 32-bit thread that has waited this many seconds without a timeout for an SRW lock held by shared owners has every 32-bit thread of its process logged once ([srw-hang]: x86 registers, EBP chain, module-resolved stack words), so the holders are named. Logs 116-119: Steam's 32-bit web helper stopped at start that way. 0: off."},
    "env.MADEIRA_SRW_HANG_KILL_S": {"category": "Exceptions & threads", "title": "End a process stuck on an SRW lock", "kind": "int", "default": "",
                "note": "ml2250: unset (default): never. N: once a 32-bit thread has waited N seconds for an SRW lock as above, the wineserver ends its process, as TerminateProcess from another process would, so a parent that restarts its helper gets a new one (Steam restarts its web helper). At most 3 per app run. The Steam Big Picture list sets 40."},
    "env.MADEIRA_FEX_PRELOADED_IMAGES": {"category": "x86 emulation (FEX)", "title": "FEX: record images loaded before it starts", "kind": "bool", "default": "1",
                "note": "ml2260: on (default): when FEX starts in a 64-bit process it records the code sections of every image already loaded (kernel32, kernelbase, ucrtbase are mapped for it before its notifications work). Before, their x64 export thunks were not known as code: a 64-bit x64 program's call into one ended it with c0000005 (log 120: the DirectX redistributable's x64 helper, at its first kernel32 call). 0: as before."},
    "env.MADEIRA_EPIC_LAUNCHER_PARENT": {"category": "App & front end", "title": "Start Epic games under the Epic client's name", "kind": "bool", "default": "1",
                "note": "ml2320: on (default): an Epic library game's x64 program starts as the child of C:\\windows\\system32\\EpicGamesLauncher.exe (build/epic-parent: starts its command line, waits, returns its exit code; not the Epic client, no window, no network), as it does under the Epic client on Windows. A publisher's launcher that did not find a process with that name treated the Epic copy as not owned and showed its store page (testers' log, 2026-10-31: a publisher's launcher started by an Epic copy said 'Failed to relaunch from third party platform' and offered the game for sale; Heroic does the same for that launcher). A batch or a 32-bit program starts as before. 0: the program starts directly."},
    "env.MADEIRA_STORE_STEAM_IDENTITY": {"category": "App & front end", "title": "Give games from other stores the fixed Steam identity", "kind": "bool", "default": "0",
                "note": "ml2310: off (default): a game from another store (an Epic library entry) starts without the fixed Steam identity (SteamAppId, SteamGameId, SteamAppPath) every other launch outside Madeira Dock gets. With it, a game's launcher took its Steam path, its Steam API start failed and it showed only an error (testers' log, 2026-10-31: a publisher's launcher started by an Epic copy, 'Steam failed to initialize'). 1: publishes it as before."},
    "env.MADEIRA_NO_STEAM_IDENTITY": {"category": "App & front end", "title": "", "kind": "text", "default": "",
                "note": "set by the library for one launch of a game from another store; not a setting"},
    "env.MADEIRA_THREAD_REAP_CHECKED": {"category": "Exceptions & threads", "title": "Check the previous exited thread before freeing it", "kind": "bool", "default": "1",
                "note": "ml2290: on (default): a thread that exits frees the previous exited thread's stacks only after finding that thread, by its process, thread id and pthread, in the live TEB list (the hand-off env.MADEIRA_EA_CEF = 1 already used). 32-bit processes started one after another can get the same window and TEB addresses; the unchecked hand-off then made a new thread free its own kernel stack at exit and hang there holding the memory lock (testers' log, 2026-10-31: a launcher installer's second VC++ redistributable, the installer waiting on that thread forever). 0: the upstream hand-off, unless MADEIRA_EA_CEF = 1."},
    "env.MADEIRA_EC_NATIVE_CHILD": {"category": "Wine core (ntdll)", "title": "Start aarch64 programs in a 64-bit x86 session", "kind": "bool", "default": "0",
                "note": "ml2280: off (default): an aarch64 program (services.exe, cmd.exe, conhost.exe) started in a session whose first program is 64-bit x86 (ARM64EC) is refused and CreateProcess fails at once. The session's ntdll loads the emulator into it and its threads have no CPU area, so it crashed at its first executable allocation and its exception path faulted until the storm handler ended it (testers' log, 2026-10-28: services.exe started on demand for a launcher installer, twice, 20 s each). A game that needs one starts in the Wine desktop. 1: starts them anyway; MADEIRA_EC_CONHOST=1 still lets conhost.exe through."},
    "env.MADEIRA_SCM_ON_DEMAND": {"category": "Wine libraries", "title": "Start the service manager when a program needs it", "kind": "bool", "default": "1",
                "note": "ml2270: on (default): when a 64-bit program opens the service manager and services.exe is not running (the session did not start Windows services first), sechost starts it once per process, waits up to 20 s for its pipe and asks again. Before, the call failed: a game from another store whose first start runs a launcher installer could not register the launcher's service and the installer stopped (testers' logs, 2026-10-28: a publisher's launcher installer run by an Epic copy's first start). 0: as before."},
    "env.MADEIRA_WOW_AREA_BY_REQUEST": {"category": "Memory & JIT pool", "title": "32-bit windows: judge a merged area by the request", "kind": "bool", "default": "1",
                "note": "ml2220: on (default): when two adjacent guest windows' reserved areas have merged into one (a slot carved from the holdback beside slot 0), a 32-bit process's allocation is judged by the window that holds its request. Before, the first window in the merged area decided, the second process was refused its own window and failed to create its TEB (every second concurrent 32-bit process of a session). 0: as before."},
    "env.MADEIRA_WOW_AFFINITY32": {"category": "Exceptions & threads", "title": "32-bit thread group affinity", "kind": "bool", "default": "1",
                "note": "ml2210: on (default): a 32-bit program's GROUP_AFFINITY thread attribute (12 bytes, a 32-bit mask) is decoded field by field when the thread is created; read as the 16-byte native struct, NtCreateThreadEx failed with c000000d and a 32-bit Chromium's thread pool threw. 0: read as before."},
    "env.MADEIRA_STEAM_ALLOW_CRASHPAD": {"category": "Steam & Dock", "title": "Steam web helper: allow its crash reporter", "kind": "bool", "default": "0",
                "note": "ml2210: 1 (the Steam Big Picture list) lets steamwebhelper.exe start exactly one kind of child, --type=crashpad-handler, with its command line unchanged; without it the 32-bit web helper ends itself at start (crash server failed to launch). Every other --type= child stays refused. Off (default): all are refused."},
    "env.MADEIRA_BIG_PICTURE_PIN": {"category": "Steam & Dock", "title": "Big Picture: keep the installed 32-bit client", "kind": "bool", "default": "1",
                "note": "ml2210: on (default): once Big Picture's folder holds the 32-bit client's web helper (bin/cef/cef.win7), steam.exe starts with -nobootstrapperupdate -skipinitialbootstrap, so it cannot move itself to the 64-bit client, whose CEF pools do not fit the address space. 0: Steam updates itself at every start, as before."},
    "donor-pool-kind": {"category": "Memory & JIT pool", "title": "Donor pool memory kind", "kind": "choice",
                "note": "ml1152: how the extension creates each donated region. ledger (the default): a named memory entry tagged to the extension's ledger. purgeable: a purgeable allocation in the extension named by a memory entry (the way MeloNX donates RAM). Everything else in the tier is the same, so the two can be compared.",
                "choices": [("", "Ledger-tagged entry (default)"), ("purgeable", "Purgeable allocation")]},
    "env.MADEIRA_DISPLAY_SYNC": {"category": "Windows, display & input", "title": "Metal layer: keep display sync", "kind": "bool", "default": "0",
                "note": "ml2021 A/B: 1 leaves the game's Metal layer in CoreAnimation's display-sync scheduling. Off (the default) sets the private displaySyncEnabled=false (the MeloNX pattern, 2026-07-03). For a title parked 18-72 ms a frame in nextDrawable with the display link honoured at 120 Hz, this is one of the two suspects for late drawables (the other: env.MADEIRA_PROMOTE_KICK)."},
    "env.MADEIRA_PROMOTE_KICK": {"category": "Windows, display & input", "title": "Display link: commit a transaction per tick", "kind": "bool", "default": "0",
                "note": "ml2021 experiment: 1 adds a one-pixel layer whose opacity alternates on every display-link tick, so each tick commits a CoreAnimation transaction. For a title parked 80 ms a frame in nextDrawable with the 120 Hz link armed: if the waits fall with this on, the compositor needed a transaction, not an intent."},
    "donor-pool-guard": {"category": "Memory & JIT pool", "title": "Donor pool: memory-pressure guard", "kind": "choice",
                "note": "ml2021: what iOS's memory-pressure notification does to the pool. Unset: nothing, the pool is spent like MeloNX's (on an 8 GB phone the critical notification refused 502 takes and left 2.6 GB of the pool unused while the title's own memory, compressed, filled the app's limit; donated pages are the extension's to compress, not the app's). 1: a critical notification stops takes. 2: warning and critical (the old behaviour).",
                "choices": [("", "Off (spend the pool)"), ("1", "Stop at critical pressure"), ("2", "Stop at warning")]},
    "env.MADEIRA_DONOR_WINDOWS": {"category": "Memory & JIT pool", "title": "Donor pool: permanent region windows", "kind": "bool", "default": "0",
                "note": "ml2021: 1 maps every donated region into the address space when it is registered, as the first port did. Off (the default) maps only the range being freed, for its zeroing: the permanent windows were placed before Wine held the 32-bit guest-window slot and took it, so 32-bit programs failed at guest-window-reserve."},
    "env.MADEIRA_DONOR_POOL_MARGIN_MB": {"category": "Memory & JIT pool", "title": "Donor pool free-RAM margin (MB)",
                "note": "ml1150: the donor pool takes no more memory while the host's free RAM is below this many MB. Off (0) since ml2021: iOS keeps free RAM low on purpose, so 1024 and then 256 refused most takes on device; the memory-pressure notification alone guards. Set 256 to restore the old floor."},
    "env.MADEIRA_SWAP_X64_CHURN": {"category": "Memory & JIT pool", "title": "Swap tier: churn filter for 64-bit programs beside a 32-bit one", "kind": "bool", "default": "0",
                "note": "ml2021: off (the default) sends a 64-bit program's short-lived allocation sizes to the swap file too while a 32-bit program is in the session, instead of leaving them anonymous (the ml1258 churn filter): beside a 32-bit title the launcher chain is idle, and its anonymous pages were compressed into the footprint. 1 keeps the filter for them."},
    "swap-x64": {"category": "Memory & JIT pool", "title": "Swap tier: where 64-bit programs go first", "kind": "choice",
                "note": "ml2021: the stage a 64-bit program's memory takes first; the other is the fallback. Unset: the swap file while a 32-bit program is in the session (a guest window held or in use), so the kernel can evict the launcher chain's idle pages and the donor pool stays for the 32-bit program, which may not use the file; donor RAM first otherwise. 1: donor RAM first, always (the old behaviour). 2: the swap file first, always.",
                "choices": [("", "File while a 32-bit program runs, else donor RAM"), ("1", "Donor RAM first"), ("2", "Swap file first")]},
    "swap-wow64": {"category": "Memory & JIT pool", "title": "Swap tier for 32-bit programs", "kind": "choice",
                "note": "ml2021: what the tier may do with memory a 32-bit program commits (inside its WoW64 guest window). Unset: donor RAM only, the memory stays ordinary RAM when the pool has none; it never goes to the swap file, which paged a 32-bit title's heap in and out of flash and froze it for seconds at a time. 1: donor RAM, then the swap file, like 64-bit programs (the old behaviour). 2: never tiered. The 64-bit launcher and helpers next to it still use the pool and the file.",
                "choices": [("", "Donor RAM only (default)"), ("1", "Donor RAM, then the swap file"), ("2", "Never tiered (RAM only)")]},
    "swap-mb": { "note": "Moves game data to a file on this device's storage when memory runs short, up to this size. Off by default; read at launch.", "category": "Memory & JIT pool","title": "Swap tier size", "kind": "choice",
                "choices": [("", "Off"), ("1024", "1 GB"), ("2048", "2 GB"), ("3072", "3 GB"), ("4096", "4 GB")]},
    "env.MADEIRA_SWAP_COVERAGE": {"category": "Memory & JIT pool", "note": "Which allocations the swap tier backs with its file (only when the tier is on). Large allocations (classic, the default): single 8 MB+ commits in the guest band. All allocations of 1 MB+ (blocks). 1 MB+ and overflow (wide): blocks plus allocations outside the band and fresh reservations. Whole reservations 4 MB+ (broad, ml1257): every new reservation of at least swap-min-mb (4 MB) below FEX's band backed whole when made, holes punched on decommit, swap-mb caps the disk it uses (a soft cap, checked when a block is backed). Unset: broad if swap-mode = 2, else classic.", "title": "Swap tier coverage", "kind": "choice",
                "choices": [("", "Large allocations (8 MB+)"), ("blocks", "All allocations of 1 MB+"), ("wide", "1 MB+ and overflow"), ("broad", "Whole reservations 4 MB+ (broad)")]},
    "swap-mode": {"category": "Memory & JIT pool", "title": "Swap tier mode (2 = broad)",
                "note": "2 selects broad swap coverage (ml1257) when env.MADEIRA_SWAP_COVERAGE is unset; any other value, classic. The coverage key wins when set."},
    "swap-min-mb": {"category": "Memory & JIT pool", "title": "Swap tier floor (MB)",
                "note": "The smallest allocation the swap tier backs (ml1257): 8 MB in classic, 1 MB in blocks and wide, 4 MB in broad unless set. MADEIRA_SWAP_MIN_KB overrides it for blocks, wide and broad."},
    "inproc-sync": { "category": "Synchronisation","title": "Madsync (in-process sync)", "default": "0",
                "note": "1 selects madsync (Settings > Sync engine > Madsync). Unset: fastsync, the default engine; 0 without env.MADEIRA_FASTSYNC: Wine standard sync."},
    "env.MADEIRA_FASTSYNC": {"category": "Synchronisation", "title": "Fastsync (in-process sync, default)", "kind": "choice",
                "note": "Fastsync is the default engine: with neither this nor inproc-sync set, the app exports auto. Settings > Sync engine > Fastsync removes both keys. Never runs while madsync is on. auto arms the fast wake path on heavy event traffic, 1 from the start, cells only answers polls, 0 is off.",
                "choices": [("", "Default (auto)"), ("auto", "Auto"), ("1", "On"), ("cells", "Poll answers only"), ("0", "Off")]},
    # Read by winemetal (the DXGI budget) and, for the opt-in D3DKMT adapter, by
    # build/win32u-unix/d3dkmt_ios.c; keep the DXMT category and note.
    "vram-mb": {"title": "Video memory budget (MB)", "category": "Direct3D 9/10/11 (DXMT)",
                "note": "ml1095: madeira.cfg vram-mb = N"},
    "pool": { "category": "Memory & JIT pool","title": "JIT pool size (MB)"},
    "totalphys": { "category": "Memory & JIT pool","title": "Reported physical memory (MB)"},
    "eco": { "note": 'Runs guest threads at a lower iOS QoS class so the system favours efficiency and saves power; can cost speed. Class chosen by eco-qos.',"title": "Eco scheduling"},
    "eco-qos": {"title": "Eco QoS class", "kind": "choice", "note": "The QoS class guest threads run at while eco is on.",
                "choices": [("", "Utility (default)"), ("background", "Background"), ("initiated", "User initiated")]},
    "env.MADEIRA_WG_VIDEO": {"title": "Media: MP4 video (32-bit programs)",
                "note": "0 limits the media parser to MP3/WAV; by default MP4 with H.264/HEVC video decodes through VideoToolbox."},
    "env.MADEIRA_WOW_RWX_PLAIN": {"category": "Memory & JIT pool", "note": "Unset: a 32-bit window's anonymous RWX memory is plain read/write to the host once Wine Mono's libmono-2.0-x86.dll is mapped there (ml1279/ml1282). 1: in every 32-bit window. 0: never (stores go through the JIT pool's alias, and FEX's Mono bridge stays off)."},
    "env.MADEIRA_WINEMONO_BRIDGE": {"note": "FEX's Mono backpatcher bridge (ml712). On by itself for Wine Mono, 32- and 64-bit (ml1282/ml1286); for the 32-bit runtime in a guest window it also turns SMC detection off once the backpatcher is found (ml1280). 0 keeps it off."},
    "env.MADEIRA_MONO_DEFAULTS": {"category": "Wine libraries", "note": "Wine Mono, 32- and 64-bit: mscoree sets MONO_THREADS_SUSPEND=coop and adds keep-delegates to MONO_DEBUG before Mono loads, and puts the previous values back once Mono has read them (ml1282); values already set win. 0 sets nothing."},
    "cpu-count": {"title": "Reported CPU count (0 = device)"},
    "desktop-size": {"title": "Virtual desktop size (WxH)",
                     "note": "The developer interface's Wine desktop size (ml1127); its Resolution menu writes it (ml1157). Madeira Dock sessions without a game's Resolution use it too. Unset: this screen's shape at 1280x720's pixel count (ml1172: 1408x648 on a 19.5:9 iPhone, 1152x800 on an 11-inch iPad). Applies at the next app start."},
    "d3d9": {"title": "Direct3D 9 frontend", "kind": "choice",
             "choices": [("", "Default (emulated)"), ("native", "Native ARM64 frontend"),
                         ("wined3d", "Wine wined3d on OpenGL (Zink)")],
             "note": "Unset or \"emulated\": DXMT's D3D9 frontend, translated by FEX in 32-bit programs (x64 programs "
                     "always get DXMT's native ARM64EC build). \"native\": 32-bit programs run DXMT's frontend as native "
                     "ARM64 code. \"wined3d\": 32- and 64-bit programs get Wine's own d3d9 on wined3d's OpenGL renderer "
                     "(opengl32 on Zink/MoltenVK; needs gl-backend = zink, the default when the bundle has gl/)."},
    "fence-chain": {"title": "D3D12 fence chain mode"},
    "async-submit": {"title": "D3D12 asynchronous submission"},
    "upload-swap": {"title": "D3D12 upload buffers on file-backed memory"},
    "d3d12-typed-uav-load": {"title": "D3D12 typed UAV loads (report support)"},
    # The Vulkan routes: vkd3d-proton for Direct3D 12, DXVK for Direct3D 10/11 and the
    # Vulkan library (WineProcessBridge.m, madeira_setup_vulkan; docs/BUILDING.md
    # "winevulkan and vkd3d-proton", docs/DXVK.md).
    "d3d11": {"category": "Vulkan routes", "title": "Direct3D 10/11 runtime (x64)", "kind": "choice",
              "choices": [("", "DXMT (default)"), ("dxvk", "DXVK on Vulkan")],
              "note": "Unset: DXMT, Direct3D 10/11 on Metal. \"dxvk\": this session's d3d11.dll, d3d10core.dll and "
                      "dxgi.dll are DXVK's (Direct3D 10/11 and DXGI on Vulkan, the bundle's vulkan/ folder), replacing "
                      "DXMT for Direct3D 10/11 and DXGI; Vulkan is on (see vulkan). DXVK's DXGI only presents for Vulkan "
                      "devices, so Direct3D 12 pairs with vkd3d-proton: with d3d12 unset this implies d3d12 = vkd3d. "
                      "x64 programs only; read at session start; also from a game's own lines. Experimental, not "
                      "device-tested."},
    "d3d12": {"category": "Vulkan routes", "title": "Direct3D 12 runtime (x64)", "kind": "choice",
              "choices": [("", "madeira-d3d12 (default)"), ("vkd3d", "vkd3d-proton on Vulkan")],
              "note": "Unset: madeira-d3d12, Direct3D 12 on Metal. \"vkd3d\": this session's d3d12.dll and d3d12core.dll "
                      "are vkd3d-proton's (Direct3D 12 on Vulkan, the bundle's vulkan/ folder) and Vulkan is on (see "
                      "vulkan). x64 programs only; read at session start; also from a game's own lines. Not "
                      "device-tested. \"1\" (ml1095, developer) runs madeira-d3d12's shader converter canary at app start."},
    "vulkan": {"category": "Vulkan routes", "title": "Vulkan library (x64)", "kind": "choice",
               "choices": [("", "Off, MoltenVK with d3d12 = vkd3d or d3d11 = dxvk"), ("moltenvk", "MoltenVK"),
                           ("kosmickrisp", "KosmicKrisp"), ("off", "Off")],
               "note": "The Vulkan driver Wine's winevulkan loads: moltenvk = gl/libMoltenVK.dylib (the one Zink uses), "
                       "kosmickrisp = gl/libvulkan_kosmickrisp.dylib, or a .dylib path (absolute or bundle-relative). "
                       "Setting it turns Vulkan on for x64 programs (vulkan-1.dll and winevulkan.dll in the prefix); "
                       "unset, Vulkan is off unless d3d12 = vkd3d or d3d11 = dxvk. Read at session start; also from a "
                       "game's own lines."},
    "env.VKD3D_DEBUG": {"category": "Vulkan routes", "title": "vkd3d-proton log level",
               "note": "vkd3d-proton's log: none, err, warn, fixme (default), info, trace. Passed to the Windows "
                       "environment like any env line; only with d3d12 = vkd3d."},
    "env.VKD3D_SHADER_DEBUG": {"category": "Vulkan routes", "title": "vkd3d-proton shader log level",
               "note": "The shader translators' log level (none, err, warn, fixme, info, trace); with d3d12 = vkd3d."},
    "env.VKD3D_CONFIG": {"category": "Vulkan routes", "title": "vkd3d-proton options",
               "note": "Comma-separated vkd3d-proton flags (e.g. no_upload_hvv, force_static_cbv, skip_driver_workarounds); "
                       "with d3d12 = vkd3d. See vkd3d-proton's README."},
    "env.DXVK_LOG_LEVEL": {"category": "Vulkan routes", "title": "DXVK log level",
               "note": "DXVK's log (none, error, warn, info, debug, trace), written to the session log through Wine's "
                       "debug output. d3d11 = dxvk sets info unless this is set."},
    "env.DXVK_CONFIG_FILE": {"category": "Vulkan routes", "title": "DXVK config file",
               "note": "A dxvk.conf to read instead of the one in the program's working folder (a Windows path, "
                       "e.g. C:\\users\\madeira\\dxvk.conf); with d3d11 = dxvk. See DXVK's dxvk.conf for the options."},
    "env.DXVK_CONFIG": {"category": "Vulkan routes", "title": "DXVK options",
               "note": "dxvk.conf options inline, separated by ';' (e.g. dxgi.maxFrameRate=60;d3d11.cachedDynamicResources=a); "
                       "applied after the config file; with d3d11 = dxvk."},
    # opengl32 32-bit thunks (patches/wine-opengl-winios.patch, applied to the wine tree at
    # build time, so the scanner never sees it): ml1340 query-buffer offsets.
    "env.MADEIRA_GL_QUERY_BUFFER_OFFSETS": {"category": "Graphics", "title": "32-bit GL query results as buffer offsets",
               "kind": "bool", "default": "1",
               "note": "On (default): a 32-bit program's glGetQueryObject*v result pointer is an offset into the bound "
                       "GL_QUERY_BUFFER (wined3d reads occlusion results that way; converting it as a pointer left "
                       "the game spinning at 1 fps, ml1340). 0: the old pointer conversion."},
    # build/win32u-unix/opengl_ios.c (ml1344): ZINK_VULKAN_LIBRARY for the desktop OpenGL backend.
    "gl-vulkan": {"category": "Graphics", "title": "Vulkan driver for OpenGL (Zink)", "kind": "choice",
               "note": "The Vulkan driver Zink runs desktop OpenGL (and d3d9 = wined3d) on: MoltenVK (default) or "
                       "KosmicKrisp (gl/libvulkan_kosmickrisp.dylib); any other value is a .dylib name in the gl "
                       "folder or an absolute path. env.MADEIRA_GL_VULKAN is the fallback. Read when a program "
                       "first creates an OpenGL context; the log says \"ml1344 zink Vulkan library: ...\".",
               "choices": [("", "MoltenVK (default)"), ("moltenvk", "MoltenVK"), ("kosmickrisp", "KosmicKrisp")]},
    # Read by DXMT's DXGI (dxmt/src/dxgi/dxgi_swapchain_vk.cpp, ml1320).
    "env.MADEIRA_DXGI_VK_SWAPCHAIN": {"category": "Vulkan routes", "title": "DXGI swapchains for vkd3d-proton",
               "kind": "bool", "default": "1",
               "note": "On (default): DXMT's DXGI presents for a Direct3D 12 device on Vulkan (d3d12 = vkd3d) by "
                       "wrapping vkd3d-proton's swapchain (IDXGIVkSwapChainFactory); windowed only, a fullscreen "
                       "request keeps the window. 0: CreateSwapChain fails with \"Unsupported device type\" for "
                       "those devices, as before."},
    # madeira-bcd: the packed shader cache (madeira-d3d12/src/unix/madeira_sc_pack.c).
    "d3d12-shader-pack": {"category": "Direct3D 12", "title": "D3D12 shader cache in two pack files",
                "kind": "bool", "default": "0",
                "note": "Off by default: one file per converted shader in Documents/shadercache, as before. 1: the "
                        "converter keeps its DXBC and DXIL cache entries in two append-only files "
                        "(shadercache/pack/dxbc.mdpk, dxil.mdpk); loose entries of earlier runs move in as games use "
                        "them. Off again, the packs are not read: what moved into them converts again. Bounds: DXIL as "
                        "env.MADEIRA_D3D12_DXIL_CACHE_MB (512 MB), DXBC 2 GB; a full pack starts over. Read once per "
                        "app start; the game's own file wins."},
    # madeira-bcd: madeira-d3d12's shader cache without Wine's file API (winemetal ops 20-22, dxmt).
    "shader-cache-native": {"category": "Direct3D 12", "title": "D3D12 shader cache files read natively",
                "kind": "bool", "default": "1",
                "note": "On by default. The Direct3D 12 runtime's shader cache (AppData\\Local\\Madeira\\ShaderCache) "
                        "is read and written by Madeira itself instead of through Wine's file calls, which asked "
                        "Wine's server three times per entry (~3.5 ms each in Horizon Zero Dawn's menu, ~1,000 "
                        "entries a second, with the server on a performance core). The same files either way. "
                        "0: Wine's file calls, as before. Read when the game creates its first pipeline.",
                "sources": ["madeira-d3d12/src/pe/madeira_d3d12.c"]},
    # Read by DXMT's DXGI and by win32u's display adapter (sysparams_ios.c); a
    # library entry's "Report an NVIDIA GPU" sets it.
    "env.DXMT_ENABLE_NVEXT": {"category": "Direct3D 9/10/11 (DXMT)", "title": "Report an NVIDIA GPU (all games)",
                "note": "1: DXGI names NVIDIA as the vendor, DXMT's NVAPI answers and win32u registers the display "
                        "adapter as a GeForce RTX 3060 (driver 581.57). Per game: Game details > Report an NVIDIA GPU, "
                        "which also sets the matching DXGI device id."},
    "ags-rewrite": {"title": "D3D12 AMD AGS 64-bit atomics rewrite"},
    "env.MADEIRA_EXE": {"title": "Program to start at launch (Windows path or name)"},
    "env.MADEIRA_ONBOARDING": {"title": "First-run Steam setup"},
    "env.MADEIRA_XINPUT": {"title": "Physical controllers (XInput)"},
    "env.MADEIRA_TOUCH_XINPUT": {"title": "Touch controller as XInput player 1"},
    "env.MADEIRA_DINPUT_PAD": {"title": "DirectInput joystick from the host gamepad"},
    # ml2100: the HID controller (build/wineserver/hidpad_ios.c, docs/CONTROLLERS.md).
    "env.MADEIRA_PAD_MODE": {"category": "Controllers", "title": "Controller API (player 1)", "kind": "choice",
                "note": "XInput (default): every controller is an Xbox pad. hid: player 1 becomes a HID game controller, "
                        "a DualSense (054C:0CE6) when it is a PlayStation pad, and leaves XInput; any other pad stays "
                        "on XInput. dualsense/generic force the identity. Read at session start; the game's own file wins.",
                "choices": [("", "XInput (default)"), ("hid", "DirectInput / HID"), ("dualsense", "HID, always a DualSense"),
                            ("generic", "HID, always a generic gamepad")],
                "sources": ["app/Madeira/GamepadInput.swift"]},
    "env.MADEIRA_HIDPAD": {"category": "Controllers",
                "note": "Set by the app at session start from env.MADEIRA_PAD_MODE (dualsense or generic) for the "
                        "wineserver and ntdll; not meant to be set by hand."},
    "env.MADEIRA_HIDPAD_NAME": {"category": "Controllers",
                "note": "Set by the app: the product string a generic HID gamepad reports (the physical pad's name)."},
    "env.MADEIRA_HIDPAD_XINPUT": {"category": "Controllers", "title": "HID mode: keep player 1 on XInput too", "kind": "bool",
                "default": "0",
                "note": "1: with the HID controller on, player 1 also stays an XInput pad. Off by default, so a game "
                        "that reads both APIs does not see the same pad twice.",
                "sources": ["app/Madeira/GamepadInput.swift"]},
    "env.MADEIRA_HIDPAD_AUTO_GENERIC": {"category": "Controllers", "title": "HID mode: other pads as a generic HID gamepad",
                "kind": "bool", "default": "0",
                "note": "1: with env.MADEIRA_PAD_MODE = hid, a pad that is not a PlayStation one becomes a generic HID "
                        "gamepad and leaves XInput (the old behaviour). Off: it stays on XInput.",
                "sources": ["app/Madeira/GamepadInput.swift"]},
    "env.MADEIRA_PSO_ARCHIVE_INLINE": {"category": "Direct3D 12", "title": "Pipeline archive: compile once",
                "kind": "bool", "default": "1",
                "note": "With pso-archive on: 1 (default) compiles a pipeline the saved archive does not have once, into "
                        "an open archive, and creates it from there. 0: created, then compiled again on one queue to be "
                        "added (the first version; it kept about a quarter of a session's pipelines).",
                "sources": ["dxmt/src/winemetal/unix/winemetal_unix.c"]},
    "env.MADEIRA_PSO_ARCHIVE_MB": {"category": "Direct3D 12", "title": "Pipeline archive: size cap (MB)",
                "kind": "int", "default": "1024",
                "note": "With pso-archive on: the most a game's pipeline archive folder keeps across builds. Over it, the "
                        "oldest chunks are deleted at launch down to three quarters; a session adds none once it is reached.",
                "sources": ["dxmt/src/winemetal/unix/winemetal_unix.c"]},
    "env.MADEIRA_PSO_ARCHIVE_PER_BUILD": {"category": "Direct3D 12", "title": "Pipeline archive: one per build",
                "kind": "bool", "default": "0",
                "note": "1: the archive folder sits in the build's shader cache directory and goes with it when a new build "
                        "prunes it (the first version). Off: Madeira/PipelineArchive in LOCALAPPDATA, kept across builds.",
                "sources": ["madeira-d3d12/src/pe/madeira_d3d12.c"]},
    "env.MADEIRA_X18_TRAMP_ALIGN": {"category": "Memory & JIT pool", "title": "x18 trampolines on their own page",
                "kind": "bool", "default": "1",
                "note": "1 (default): an image whose .data was shifted to a 16 KB page gets its x18 trampolines on the "
                        "page after it, not on its last .data page (mapped without exec). 0: the old offsets.",
                "sources": ["build/ntdll-unix/virtual_ios.c"]},
    # ml2106: game output to the physical pad (app/Madeira/PadOutput.m).
    "env.MADEIRA_PAD_OUTPUT": {"category": "Controllers", "title": "Rumble, adaptive triggers and lightbar to the pad",
                "kind": "choice",
                "note": "On (default): XInput rumble plays on the controller (CoreHaptics), and in DualSense HID mode the "
                        "game's output reports drive rumble, adaptive triggers (closest GameController mode), lightbar "
                        "and player LEDs. hid: only the DualSense's; xinput: only XInput rumble; 0: none. Read at "
                        "session start; the game's own file wins.",
                "choices": [("", "On (default)"), ("hid", "DualSense output only"), ("xinput", "XInput rumble only"),
                            ("0", "Off")],
                "sources": ["app/Madeira/GamepadInput.swift", "app/Madeira/PadOutput.m"]},
    # ml2170/ml2171: XInput battery and Windows.Gaming.Input host pads (docs/CONTROLLERS.md).
    "env.MADEIRA_XINPUT_BATTERY": {"category": "Controllers", "title": "Controller battery level to XInput",
                "kind": "bool", "default": "1",
                "note": "On (default): XInputGetBatteryInformation reports each pad's GameController battery (wired "
                        "while charging, else a level) and XInputGetCapabilities flags a battery-powered pad as "
                        "wireless. 0: an unknown battery, as before."},
    "env.MADEIRA_XINPUT_SLOT0_RECONNECT": {"category": "Controllers",
                "title": "Reconnected controller back to player 1", "kind": "bool", "default": "1",
                "note": "On (default): when player 1's controller reconnects and GameController reports it as a new "
                        "controller before the old one leaves, it is moved from the slot it landed in back to slot 0. "
                        "0: it stays where it landed, as before."},
    "env.MADEIRA_XINPUT_PROFILE_CHECK": {"category": "Controllers",
                "title": "Re-read a controller's input profile", "kind": "bool", "default": "1",
                "note": "ml2190: on (default): every 2 s the app checks each connected controller's extended-gamepad profile and, "
                        "when GameController has replaced it (a remap or a mode change after the controller joined), reads the "
                        "live one; the first 8 times the sticks leave rest the raw values are logged ([xinput] ml2190). 0: a "
                        "slot keeps the profile its controller had when it joined, as before."},
    "env.MADEIRA_XINPUT_ENABLE_FOREGROUND": {"category": "Controllers",
                "title": "Ignore a stale XInput disable while the game is in front", "kind": "bool", "default": "1",
                "note": "On (default): when a game has switched XInput off (XInputEnable(FALSE), usually on losing "
                        "focus) but its window is in front, it still reads the pad; activation messages at startup can "
                        "leave it off for good. 0: the pad reads at rest while disabled, as before. Read by win32u, so "
                        "32- and 64-bit games alike."},
    "env.MADEIRA_PROMOTE": {"title": "Hold the display at its maximum rate"},
    # madeira-bcd: GTA V Enhanced's Social Club (StikJITHelper.swift, process_ios.c, virtual_ios.c).
    "pool-split": {"category": "Memory & JIT pool", "title": "Split JIT pool around the main thread's stack",
                "kind": "bool", "default": "0",
                "note": "1: when the pool would shrink below its size (pool, 896 MB by default) because the main "
                        "thread's stack splits the only executable band, the free run above the stack becomes a "
                        "second debugger region and both form one pool (about 880 MB instead of 560-630 MB). Costs "
                        "the second region's size in memory. Off by default; read at launch, the game's own file "
                        "wins."},
    "pool-page-fit": {"category": "Memory & JIT pool", "title": "Fit split pool regions to memory pages",
                "kind": "bool", "default": "0",
                "note": "With pool-split on: fit regions A/B to 16 KB pages instead of 16 MB steps, retaining small "
                        "remainders in free runs without increasing the requested pool budget. With pool-low on, "
                        "also fit region C to pages while preserving pool-low-margin. Costs the additional pages in memory. Off by default; read at "
                        "launch, the game's own file wins. Restart Madeira and enable JIT again after changing it."},
    "pool-pair": {"category": "Memory & JIT pool", "title": "Split JIT pool: prefer two runs above the window",
                "kind": "bool", "default": "1",
                "note": "With pool-split on: the pool takes two runs above the 0x140000000 executable window when "
                        "together they are larger than the single run it would get -- whether that run lies below the "
                        "window, where the pool cannot split (GTA V: 368 + 320 MB instead of 464 MB), or is the higher "
                        "of two runs above it (The Adventures of Elliot: 240 + 288 MB instead of 288 MB). Falls back to "
                        "the single run if the placement misses. On by default; 0 turns it off. Read at launch, the "
                        "game's own file wins."},
    "pool-mid": {"category": "Memory & JIT pool", "title": "Split JIT pool: use the free run between the regions",
                "kind": "bool", "default": "0",
                "note": "With pool-split on: when another mapping sits between the pool's two regions and leaves a "
                        "free run of 64 MB or more there, that run becomes a third debugger region in the same pool "
                        "(RDR2 build 470: 604 MB pool, a 71 MB mapping and 213 MB free between the regions; the "
                        "DLL copies ran out and the game failed with ERR_GFX_INIT). Only from what the two regions "
                        "left of the pool size; costs that region's size in memory. Off by default (RDR2's list turns "
                        "it on); read at launch, the game's own file wins.",
                "sources": ["app/Madeira/StikJITHelper.swift", "build/ntdll-unix/virtual_ios.c"]},
    "pool-low": {"category": "Memory & JIT pool", "title": "JIT code buffers below the executable window",
                "kind": "bool", "default": "0",
                "note": "1: a free run below the 0x140000000 executable window (less pool-low-margin) "
                        "becomes a third debugger region for the emulator's code buffers, so the whole JIT pool is "
                        "left to DLL copies (GTA V: about 300 MB more). Needs the pool above the window; costs the "
                        "region's size in memory. Off by default; read at launch, the game's own file wins."},
    "exe-window-mb": {"category": "Memory & JIT pool", "title": "Executable window size (MB)",
                "kind": "int", "default": "128",
                "note": "The address range at 0x140000000 kept for a game exe without relocations, which can only run there. Unset: 128 MB, or for a Madeira Dock launch the size of the largest such exe in the game's folder (The Adventures of Elliot: 473 MB -> 480). The JIT pool then starts above it and is that much smaller, so a large one also needs env.MADEIRA_X64_IMAGE_NOCOPY = 1 and pool-split = 1. A number sets it (129 to 960); 128 or less keeps 128 MB. Read at launch, the game's own file wins.",
                "sources": ["app/Madeira/StikJITHelper.swift"]},
    "pool-low-margin": {"category": "Memory & JIT pool", "title": "Code-buffer region: MB left free below the window",
                "kind": "int", "default": "128",
                "note": "With pool-low on: how much of the free run below the executable window stays free for "
                        "programs that load there (child processes' main executables). A run with a free run at "
                        "least this large below it keeps none. 128 by default."},
    "env.MADEIRA_SC_CEF": {"category": "Wine core (ntdll)", "title": "Social Club's Chromium in one process",
                "kind": "bool", "default": "1",
                "note": "On by default; 0 turns it off. SocialClubHelper.exe runs --single-process with "
                        "PartitionAllocBackupRefPtr disabled and V8 --jitless (MADEIRA_JITLESS = 0 keeps V8's JIT), its "
                        "--type= children are refused, and a process with socialclub.dll mapped that is not the "
                        "helper (the game) gets no JIT-pool copy of libcef.dll: its load fails, as it did when the "
                        "pool was full. No effect on programs without Social Club."},
    "env.MADEIRA_SC_CEF_FLAGS": {"category": "Wine core (ntdll)", "title": "Extra SocialClubHelper.exe switches",
                "note": "Appended verbatim to SocialClubHelper.exe's command line while env.MADEIRA_SC_CEF is on, "
                        "e.g. --disable-gpu or --enable-logging=file --v=1. A --js-flags= in it gets --jitless as its "
                        "first flag (Chromium keeps only the last --js-flags=), unless MADEIRA_JITLESS = 0."},
    "env.MADEIRA_SC_PA_POOLS": {"category": "Memory & JIT pool", "title": "Room for Social Club's PartitionAlloc pools",
                "kind": "choice", "default": "",
                "choices": [("", "Off"), ("1", "Layout 1 (chrome_elf.dll only)"), ("2", "Layout 2 (chrome_elf, libcef, Oilpan)")],
                "note": "1: Wine boots with the emulator's arena at 0x7d00000000 (12 GB instead of 16 GB) and keeps "
                        "0x7c00000000 +4 GB free, so SocialClubHelper.exe's 32 GB PartitionAlloc reservation, which "
                        "must start on a 32 GB boundary, gets 0x7800000000 (20 GB of it really reserved). 2: also "
                        "libcef.dll's (0x7000000000) and Oilpan's; the JIT pool's RW alias moves to 0x7900000000. "
                        "Off by default; set it in the game's own file; read at session start."},
    "avail-phys": {"category": "Memory & JIT pool", "title": "Report the memory left before the app's limit as available",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: Windows programs' available physical memory (GlobalMemoryStatusEx) is what "
                        "remains before Madeira's memory limit instead of the phone's free memory, so Chromium "
                        "(Social Club, Steam) frees caches below 1000 MB and 400 MB left, and a game can see memory "
                        "running out. Set it in the game's own file; read at session start."},
    # madeira-bcd: the memory before the game (2026-10-09, virtual_ios.c ios_avail_phys / ios_swap_image_flush).
    "avail-phys-cef-mb": {"category": "Memory & JIT pool", "title": "Available memory Chromium sees (MB)",
                "kind": "int", "default": "0",
                "note": "0 (default): off. N: Social Club's SocialClubHelper.exe and Steam's steamwebhelper.exe see at "
                        "most N MB of available physical memory, nobody else (the game and the launcher keep the real "
                        "figure). Below 400 (e.g. 300) Chromium reports critical memory pressure every 5 s and purges "
                        "caches and garbage; 400-999 (e.g. 900), moderate every 10 s. Independent of avail-phys. Set it "
                        "in the game's own file; read at session start."},
    "swap-images": {"category": "Memory & JIT pool", "title": "Swap tier: pure-x64 DLLs and programs in the file",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: the sections of pure-x64 images (with env.MADEIRA_X64_IMAGE_NOCOPY = 1: "
                        "libcef.dll, steamclient64.dll, launchers, the game exe) move to the swap tier's file once they "
                        "are read, so they stop counting against the memory limit (iOS writes them back and may drop "
                        "them). Needs swap-mb. Page edges shared with a neighbouring section stay in memory. Set it in "
                        "the game's own file; read at session start."},
    # madeira-bcd: budget-change events in DXMT's dxgi (the dxmt change of this wave).
    "env.MADEIRA_DXGI_BUDGET_EVENTS": {"category": "Direct3D 9/10/11 (DXMT)",
                "title": "Tell the game when its video memory budget changes",
                "kind": "bool", "default": "0",
                "note": "Read by DXMT's dxgi with the budget-event change. The video memory budget DXGI reports "
                        "shrinks as Madeira nears its memory limit (vram-trim-mb below it). 1: a game's budget-change event is "
                        "registered for real, signalled at once and again whenever the budget moves by 32 MB, so a "
                        "game that waits for it (Red Dead Redemption 2) reads the smaller budget and frees textures. "
                        "Off (default): the registration is refused, as before. Set it in the game's own file; read "
                        "at session start."},
    # the video budget's trim counts the swap tier's donor pool (winemetal, log 96).
    "vram-count-donor": {"category": "Direct3D 9/10/11 (DXMT)",
                "title": "Video memory budget counts donated RAM",
                "kind": "bool", "default": "0",
                "note": "The video memory budget a game reads shrinks as memory runs short (vram-trim-mb), judged "
                        "by the app's own memory. 1: the donor pool's memory counts as well, since it is the device's "
                        "RAM even though it is not under the app's limit, so with a full pool on a phone with less "
                        "RAM the game is told to keep fewer textures. Off by default (a test option). Read at "
                        "session start."},
    # a 64-bit title beside 32-bit helpers keeps the churn filter (virtual_ios.c, log 96).
    "env.MADEIRA_SWAP_TITLE_CHURN": {"category": "Memory & JIT pool",
                "title": "Short-lived memory of the game stays in RAM",
                "kind": "bool", "default": "1",
                "note": "On by default: a 64-bit game started beside 32-bit helpers keeps memory it frees and "
                        "allocates again soon in RAM instead of the swap file, until less than "
                        "MADEIRA_SWAP_CHURN_TIGHT_MB is left before the memory limit. 0: that memory goes to the "
                        "donor pool or the swap file like the rest (slower once the device is out of free RAM). "
                        "Read at session start."},
    # browsers' memory stays off the donor pool (virtual_ios.c, log 99).
    "env.MADEIRA_DONOR_BROWSERS": {"category": "Memory & JIT pool",
                "title": "Browsers take donor RAM",
                "kind": "bool", "default": "0",
                "note": "Off by default: memory of the Chromium browsers next to a game (Social Club's "
                        "SocialClubHelper.exe, Steam's steamwebhelper.exe) is backed by the swap file, never by the "
                        "donor pool. The pool is handed out by reserved size whether the pages are used or not, and "
                        "Social Club's 4 GB allocator reservation used to take all of it before the game asked. "
                        "1: browsers take donor RAM like any program. Read at session start."},
    "env.MADEIRA_DONOR_WHOLE_MAX_MB": {"category": "Memory & JIT pool",
                "title": "Largest reservation given donor RAM (MB)",
                "kind": "int", "default": "0",
                "note": "0 (default): no limit. N: a reservation larger than N MB is backed by the swap file only, "
                        "never by the donor pool (a test; a game's own big heap is usually hot and runs faster in "
                        "donor RAM). Read at session start."},
    "env.MADEIRA_DONOR_CHURN": {"category": "Memory & JIT pool",
                "title": "Short-lived memory takes donor RAM",
                "kind": "bool", "default": "1",
                "note": "On by default: memory a game frees and allocates again soon takes donor RAM while the "
                        "pool has room, instead of counting against the app's memory limit. 0: it stays in the "
                        "app's own memory as before. Read at session start."},
    # madeira-bcd: the wineserver names an opened file with F_GETPATH (build/wineserver/fd_ios.c).
    "env.MADEIRA_SRV_FGETPATH": {"category": "Wine core (ntdll)", "title": "Name opened files with one call (server)",
                "kind": "bool", "default": "0",
                "sources": ["app/Madeira/WineProcessBridge.m", "build/wineserver/fd_ios.c"],
                "note": "1: the Wine server takes the path of a file it has just opened from its descriptor "
                        "(fcntl F_GETPATH) instead of realpath, which checks the path one folder at a time "
                        "(~0.5 ms a file on the device). Same resolved path; realpath stays the fallback. For "
                        "games that open many files a second (Horizon Zero Dawn's shader cache in its menu). "
                        "Off (default): realpath as before. Read at each launch; a later game of the same app run does not "
                        "inherit it."},
    # madeira-bcd: one default keyed event per guest process (build/ntdll-unix/loader_ios.c).
    "env.MADEIRA_KEYED_EVENT_PER_PROCESS": {"category": "Wine core (ntdll)", "title": "A default keyed event per process",
                "kind": "bool", "default": "1",
                "sources": ["build/ntdll-unix/loader_ios.c"],
                "note": "On (default): each Windows process gets its own keyed event for the waits and wakes that "
                        "pass no handle (RtlRunOnce among them), created on first use. 0: every "
                        "process uses the one the first process created, as before, whose handle is not valid in the "
                        "others (Slay the Spire 2 failed in RtlRunOnceComplete). Read once per app run."},
    "env.MADEIRA_SRV_DIRECT": {"category": "Wine server", "title": "Run simple server requests on the calling thread",
                "kind": "text", "default": "0",
                "choices": [("", "Off (default)"), ("1", "Files, handles, registry, events, semaphores"),
                            ("2", "Also waits, timers and the cursor")],
                "sources": ["build/wineserver/request_ios.c", "build/wineserver/fd_ios.c", "build/ntdll-unix/server_ios.c"],
                "note": "Default off. 1: the Wine server's simplest requests (opening files and their descriptors, "
                        "closing handles, mappings looked up, registry keys and values, events, semaphores, mutexes, "
                        "completion ports) run on the thread that asks, under the server's lock, instead of a round "
                        "trip through a pipe to the server thread: no thread switches, and the work runs on the asking "
                        "thread's core. 2: waits (select), timers and set_cursor too. Every other request goes through "
                        "the pipe as before. Horizon Zero Dawn's menu sends ~7000 requests a second. Read at each launch."},
    "env.MADEIRA_SRV_ECO_FOLLOW": {"category": "Wine server", "title": "Server thread follows ECO",
                "kind": "bool", "default": "0",
                "sources": ["build/wineserver/fd_ios.c", "app/Madeira/WineProcessBridge.m"],
                "note": "Default off. 1: while ECO is on, the Wine server thread runs at utility QoS (ECO's default "
                        "class) instead of user-interactive, so it moves to the efficiency cores with the game's "
                        "threads, and back when ECO goes off. In Horizon Zero Dawn's menu with "
                        "eco = 1 the server was the only thread left on a performance core (0.54 cores at ~3.9 GHz). "
                        "Server requests may take longer. Read at each launch."},
    "env.MADEIRA_SRV_IDLE_US": {"category": "Wine server", "title": "Server loop's longest sleep (us)",
                "kind": "int", "default": "1000",
                "sources": ["build/wineserver/fd_ios.c", "app/Madeira/WineProcessBridge.m"],
                "note": "Default 1000 (1 ms, as before); 100 to 50000. Requests and timers wake the Wine server at "
                        "once; only its socket polls and fd scans wait for this tick, so a longer one means fewer "
                        "server wake-ups while idle (1000 a second at the default) and slower readiness of network "
                        "sockets and pipes. Mostly useful with env.MADEIRA_SRV_DIRECT. Read at each launch."},
    "env.MADEIRA_SRV_FD_SOCKET": {"category": "Wine server", "title": "File descriptors through the process socket",
                "kind": "bool", "default": "0",
                "sources": ["build/ntdll-unix/server_ios.c", "build/wineserver/fd_ios.c"],
                "note": "Kill switch, default 0: a file's descriptor comes back in the server's get_handle_fd reply "
                        "(a copy the server makes; it shares this process's descriptor table), the same descriptor "
                        "without a sendmsg, a recvmsg, an fcntl and two server log lines per file. 1: through the "
                        "process socket, as before. Read once per app run."},
    "env.MADEIRA_FILE_INFO_FULL": {"category": "Wine core (ntdll)", "title": "File size queries read attributes too",
                "kind": "bool", "default": "0",
                "note": "Kill switch, default 0: a file's size, index or end-of-file query (GetFileSizeEx and the "
                        "like) is answered from one fstat; the two extended-attribute reads that came after it fed "
                        "only file attributes, which these queries do not return. 1: as before. Read once per app run."},
    "env.MADEIRA_DIRCACHE": {"category": "Wine core (ntdll)", "title": "Remember directory listings for file lookups",
                "kind": "bool", "default": "1",
                "note": "Kill switch, default 1: a file name that does not match in its exact case is looked up in "
                        "an in-memory copy of its directory instead of a volume query and a directory read each "
                        "time (twice when the name is absent). Source-engine games such as Team Fortress 2 probe "
                        "thousands of absent paths while loading and during play. 0: as before. Read once per app run."},
    "env.MADEIRA_DIRCACHE_TTL_MS": {"category": "Wine core (ntdll)", "title": "Directory listing trust window (ms)",
                "kind": "int", "default": "1000",
                "note": "How long a remembered listing is used without checking the directory, while no file was "
                        "created, renamed, linked or deleted through Wine. After that one stat of the directory "
                        "decides whether it is read again. 0 checks it on every lookup. Read once per app run."},
    "env.MADEIRA_SRV_LOG_ALL": {"category": "Wine server", "title": "Every per-descriptor server log line",
                "kind": "bool", "default": "0",
                "sources": ["build/wineserver/fd_ios.c", "build/wineserver/request_ios.c"],
                "note": "Kill switch, default 0: the Wine server's add_poll_user and send_client_fd log lines (one per "
                        "opened file or descriptor sent, each a formatted write to the log file on the server thread) "
                        "are written for their first 64 and then every 1000th; a failed send is always written. 1: "
                        "every line, as before. Read at each launch."},
    # madeira-bcd: WM_TIMER not starved by WM_PAINT (build/wineserver/queue_ios.c).
    "env.MADEIRA_TIMER_FAIRNESS": {"category": "Wine server", "title": "Timers run while a window keeps repainting",
                "kind": "bool", "default": "1", "sources": ["build/wineserver/queue_ios.c"],
                "note": "Default on. A thread gets its paint messages before its timers, so a window that "
                        "invalidates itself while it paints starved every timer of that thread for good: the "
                        "Rockstar Games Launcher installer, whose status text and finish page run on a timer, "
                        "stayed at \"Preparing to Install...\" after its work was done. A timer that has waited "
                        "100 ms now goes before such a paint. 0: the strict order, as before. Read once per app run."},
    # madeira-bcd: lean periodic diagnostics (build/ntdll-unix/server_ios.c, virtual_ios.c).
    "env.MADEIRA_LEAN_DIAG": {"category": "Debugging / logs", "title": "Lean diagnostics (no thread-suspending samplers)",
                "kind": "bool", "default": "0",
                "sources": ["build/ntdll-unix/server_ios.c", "build/ntdll-unix/virtual_ios.c"],
                "note": "1: the samplers that suspend threads stop ([thread-sample] bursts every 20 s, the guest RIP "
                        "profile behind [rip-profile] and [cpu-split], [wprof]); the warmer's address-space walks "
                        "([phys-map], slot and window inventory) run every ~10 min instead of every minute, its zone "
                        "check and allocation probe every minute instead of every 2 s; mprotect_exec's per-call ERR "
                        "line is kept for the first 200 calls, then every 1000th. [xp], [xp-t], [xp-api] and "
                        "[sync-census] keep their rates. Off (default): every diagnostic as before. Read at session start."},
    # madeira-bcd: the runtime's native helper threads at utility QoS (build/ntdll-unix/thread_ios.c).
    "env.MADEIRA_ECO_NATIVE": {"category": "Wine core (ntdll)", "title": "Runtime helper threads on efficiency cores",
                "kind": "bool", "default": "0",
                "sources": ["build/ntdll-unix/thread_ios.c", "build/ntdll-unix/virtual_ios.c",
                            "build/ntdll-unix/signal_arm64_ios.c"],
                "note": "1: the JIT-pool warmer (page warming and the periodic memory walks) and the stale-pointer "
                        "healer run at utility QoS, on the efficiency cores, ECO on or off; neither does work a frame "
                        "waits for. The wineserver thread, the exception thread, audio and the interface keep their "
                        "QoS. Off (default): they keep the QoS they were created with. Read at session start."},
    # madeira-bcd: the power probe (build/ntdll-unix/server_ios.c ios_power_probe_tick).
    "env.MADEIRA_POWER_PROBE": {"category": "Debugging / logs", "title": "Log GPU and device power every 5 s",
                "kind": "bool", "default": "0",
                "sources": ["build/ntdll-unix/server_ios.c"],
                "note": "1: every 5 s a [power] line next to [xp]'s CPU energy: the GPU energy and time the driver "
                        "charged to the app's coalition, the SoC's Energy Model counters (IOReport) and the battery's "
                        "voltage and current (the whole device while unplugged), each source named unavailable once "
                        "when the system gives nothing; and [power-t], the threads that used the most energy. Off "
                        "(default): nothing is read. Needs the [xp] sampler. Read at session start."},
    # madeira-bcd: the frame-cap power governor (build/ntdll-unix/server_ios.c ios_fps_gov_step,
    # madeira-d3d12 Present, winemetal's frame cap in dxmt).
    "env.MADEIRA_FPS_CAP": {"category": "Windows, display & input", "title": "Fixed frame cap (fps)",
                "kind": "int", "default": "",
                "sources": ["build/ntdll-unix/server_ios.c", "madeira-d3d12/src/pe/madeira_d3d12.c"],
                "note": "Unset (default): no cap beyond the FPS limit. 10-120: frames start at most N times a second for "
                        "the whole session: a Direct3D 12 game's thread waits after each Present, a DXMT game's encode "
                        "thread before each present (a timed kernel wait, not a spin). Any value, e.g. 20 or 24, unlike "
                        "the FPS limit's 30/40/60; the lower of the two applies. While it is set, env.MADEIRA_FPS_GOV_MW "
                        "is ignored. Needs the [xp] sampler (MADEIRA_PROBES not 0). Read at session start."},
    "env.MADEIRA_FPS_GOV_MW": {"category": "Windows, display & input", "title": "Hold CPU power with a frame cap (mW)",
                "kind": "int", "default": "",
                "sources": ["build/ntdll-unix/server_ios.c", "madeira-d3d12/src/pe/madeira_d3d12.c"],
                "note": "Unset (default): off. N: while the game presents, the process's CPU power ([xp]'s energy) is "
                        "held at N mW on average by moving a frame cap between 60, 40, 30, 24 and 20 fps (at most one "
                        "step per 3 s; held while nothing presents). Unlike env.MADEIRA_POWER_GOV_MW it moves no thread "
                        "to the efficiency cores. Menus and loading at 3-4 W fill the budget after which iOS clamps the "
                        "CPU; e.g. 1500 keeps a 60 fps menu near 30-40 fps. [fps-gov] lines every 10 s. "
                        "env.MADEIRA_FPS_GOV_MIN / _MAX (20 / 60) bound the cap, _BAND_MJ (1500) is the energy the "
                        "average may drift before it moves. Needs the [xp] sampler. Read at session start."},
    "env.MADEIRA_FPS_GOV_MAX": {"category": "Windows, display & input", "title": "Frame-cap governor: highest cap (fps)",
                "kind": "int", "default": "60", "sources": ["build/ntdll-unix/server_ios.c"],
                "note": "Only with env.MADEIRA_FPS_GOV_MW set: the highest frame cap the governor uses, the largest of "
                        "60, 40, 30, 24 and 20 at or below this value (20 when lower). Unset: 60. Read at session start."},
    "env.MADEIRA_FPS_GOV_MIN": {"category": "Windows, display & input", "title": "Frame-cap governor: lowest cap (fps)",
                "kind": "int", "default": "20", "sources": ["build/ntdll-unix/server_ios.c"],
                "note": "Only with env.MADEIRA_FPS_GOV_MW set: the lowest frame cap the governor goes down to, the "
                        "smallest of 60, 40, 30, 24 and 20 at or above this value, never above the highest cap. "
                        "Unset: 20. Read at session start."},
    "env.MADEIRA_FPS_GOV_BAND_MJ": {"category": "Windows, display & input", "title": "Frame-cap governor: energy band (mJ)",
                "kind": "int", "default": "1500", "sources": ["build/ntdll-unix/server_ios.c"],
                "note": "Only with env.MADEIRA_FPS_GOV_MW set: how much energy the running balance may drift above or "
                        "below the target before the cap moves one step (100-100000; unset or out of range: 1500). "
                        "Smaller moves the cap sooner and more often. Read at session start."},
    "env.MADEIRA_LOCK_ORPHAN": {"category": "Wine core (ntdll)", "title": "Orphan-lock reaper mode",
                "kind": "choice", "default": "",
                "choices": [("", "Only stamped locks (default)"), ("stamped", "Only stamped locks"), ("0", "Off")],
                "note": "Default and stamped: only a lock seen held by FEX can be released, after three monitor "
                        "cycles with the same lock word and no live owner stamp. Guest locks are never released. "
                        "0: no orphan-lock releases. The dead-thread reaper is unchanged. Restart the session after changing it."},
    # madeira-bcd: small staging rings in DXMT's d3d11 (the dxmt change of this wave).
    "env.DXMT_SMALL_RINGS": {"category": "Direct3D 9/10/11 (DXMT)", "title": "Small DXMT staging rings for these programs",
                "kind": "text", "default": "",
                "note": "Read by DXMT's d3d11 with the small-rings change. Program file names separated by ';' "
                        "(e.g. Launcher.exe;SocialClubHelper.exe), or 1 for every program: in those programs DXMT's staging "
                        "ring, copy-temp ring and upload heap use 4 MB Metal blocks instead of 32 MB. A ring keeps its "
                        "blocks until 300 later submissions and an idle program keeps them for good (Rockstar Games "
                        "Launcher 132 MB, Social Club 68 MB through a whole RDR2 session). Larger uploads still get a "
                        "block of their own; each named program logs one [small-rings] line. Unset or 0 (default): "
                        "32 MB, as before. Set it in the game's own file; read when the program starts."},
    # Mesa's opengl32 on D3D12 over Wine's stub (WineProcessBridge.m, build/mesa-d3d12).
    "env.MADEIRA_OPENGL": {"category": "Windows, display & input", "title": "OpenGL through Mesa on D3D12",
                "kind": "bool", "default": "0",
                "note": "On: x64 games get Mesa's opengl32.dll (OpenGL 3.3 on D3D12, then Metal) "
                        "when build/mesa-d3d12/build.sh has put it in the app. 0: Wine's builtin opengl32, "
                        "which uses the native WGL OpenGL ES/Zink route. A game folder's own opengl32.dll still wins. Read at session start."},
    # The D3D12/DXGI GPU as a D3DKMT adapter (build/win32u-unix/d3dkmt_ios.c).
    "env.MADEIRA_KMT_ADAPTER": {"category": "Windows, display & input", "title": "D3DKMT adapter for the GPU (WDDM 3.1)",
                "kind": "bool", "default": "0",
                "note": "1: D3DKMTEnumAdapters2 lists the GPU DXGI and D3D12 report (same LUID) and "
                        "D3DKMTQueryAdapterInfo answers like a WDDM 3.1 driver (driver version, caps, device ids, "
                        "memory, performance data). Off (default): no adapter is listed, as before. Read at "
                        "session start."},
    # The registry's Fonts values for C:\windows\Fonts (wine dlls/win32u/font.c, update_external_font_keys).
    "env.MADEIRA_FONT_KEYS_REPAIR": {"category": "Windows, display & input", "title": "Repair the registry's font list",
                "kind": "bool", "default": "1",
                "note": "On (default): a session that found no fonts leaves the registry's Fonts key alone, stale "
                        "external entries that name a font of C:\\windows\\Fonts are dropped, and the Windows "
                        "directory's fonts get their Fonts values back (DirectWrite lists only those, so without "
                        "them embedded browsers crash and dialogs draw no text). 0: upstream Wine's font key "
                        "update. Read at session start."},
    # madeira-bcd: the ARM64EC JIT's boundary with native code (FEX, the jit-boundary change of this wave; all on by default).
    "env.MADEIRA_FEX_CALLRET_ELIDE": {"category": "x86 emulation (FEX)", "title": "64-bit JIT without the call-return shadow stack",
                "kind": "bool", "default": "1",
                "note": "Default on. The 64-bit (ARM64EC) JIT no longer keeps FEX's call-return shadow stack, which "
                        "nothing reads on iOS: 9 instructions less per guest CALL and per RET, and linked calls become "
                        "`bl`, so the CPU's return predictor follows guest calls. 0: the stack as before. Read when a "
                        "program starts."},
    "env.MADEIRA_FEX_EC_RET_DIRECT": {"category": "x86 emulation (FEX)", "title": "Returns from native code straight into the JIT",
                "kind": "bool", "default": "1",
                "note": "Default on. When a native (ARM64EC) function returns to the game's x64 code, the return enters "
                        "the 64-bit JIT at once instead of testing the native-code bitmap first; the JIT's dispatcher "
                        "already tests every address it has no translation for. 11 instructions less per return from a "
                        "system DLL. 0: the test as before. Read when a program starts."},
    "env.MADEIRA_FEX_EC_RET": {"category": "x86 emulation (FEX)", "title": "Returns from native code through the return predictor",
                "kind": "bool", "default": "1",
                "note": "Default on. A guest call into native (ARM64EC) code leaves the JIT with BLR and its return "
                        "comes back with RET after an L1 lookup (10 instructions instead of 22), so the CPU's "
                        "return-address predictor stays in step with the guest's calls. 0: BR and the dispatcher loop "
                        "as before. Read when a program starts."},
    "env.MADEIRA_FEX_EC_BITMAP_CACHE": {"category": "x86 emulation (FEX)", "title": "Native-code check with the thread's bitmap pointer",
                "kind": "bool", "default": "1",
                "note": "Default on. The 64-bit JIT's dispatcher tests the native-code bitmap through a pointer kept in "
                        "the thread's state instead of walking TPIDRRO_EL0, the TEB and the PEB: 4 instructions less on "
                        "every call into a system DLL through its import table. 0: the walk as before. Read when a "
                        "program starts."},
    "env.MADEIRA_FEX_EC_EXIT_LEAN": {"category": "x86 emulation (FEX)", "title": "Lean exit from the JIT into native code",
                "kind": "bool", "default": "1",
                "note": "Default on while AFP is off (the default). Calls from the 64-bit JIT into native (ARM64EC) code "
                        "use a shorter stub: no FPCR read, the CPU area and suspend doorbell from the thread's state, the "
                        "call counted per thread instead of with an atomic, and the alias lookup starting at the thread's "
                        "own last hit; 31 instructions instead of 44. [xp-api] x64->EC rates lag by under 64 calls per "
                        "thread. 0: ExitFunctionEC as before. Read when a program starts."},
    # 2026-10-26 merge wave: engine switches read by build/ntdll-unix, build/win32u-unix and madeira-d3d12
    # (titles and notes for the scan's entries; a key whose reader is not merged yet is listed all the same).
    "env.LC_ALL": {"category": "Wine core (ntdll)", "title": "Wine's locale for this game", "kind": "text", "default": "",
                "note": "Empty: Wine takes the user locale from the device's language. en_US.UTF-8 gives the game an English "
                        "system and user locale, for a game that fails right after loading a non-English OEM code page. "
                        "Read at session start."},
    "env.MADEIRA_NLS_EXTRA": {"category": "Wine core (ntdll)", "title": "Extra code page tables", "kind": "bool", "default": "0",
                "note": "Default off. 1: a code page table that is not loaded for every game (932, 936, 949, 950, 874, 1250, "
                        "1251, 1253-1258) is read from the app's nls/extra folder when the game asks for it; without the line "
                        "such a request fails (GetCPInfo and MultiByteToWideChar return an error), as before. For a game that "
                        "converts its text in one of those pages. Logged as [nls-extra]; [nls-missing] names a table that was "
                        "not found. Read at every request."},
    "env.MADEIRA_ALIAS_RELEASE": {"category": "Memory & JIT pool", "title": "Drop a released arena's code copies", "kind": "bool",
                "default": "0",
                "note": "Default off. 1: anonymous memory the game made executable (copied into the JIT pool) follows the game's "
                        "MEM_RELEASE and MEM_DECOMMIT: a released view drops its copies' records, a decommit zeroes each copy in "
                        "its pool slot. For a game that releases a memory arena and reserves it again at the same base. Logged "
                        "as [alias-release]. Read once per session."},
    "env.MADEIRA_JUMBO_HALF": {"category": "Memory & JIT pool", "title": "Give a too-large probe reservation half its size",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a reserve-only request of 4 GB or more (a power of two) that finds no hole gets half its "
                        "size at a half-aligned free slot below the emulator's arena, for a game that finds each aligned arena "
                        "with a double-size probe and keeps only half. A game that uses the whole reservation would fault, so "
                        "set it per game. Logged as [jumbo-half]."},
    "env.MADEIRA_FEX_BAND_KEEP_MB": {"category": "Memory & JIT pool",
                "title": "Keep the lowest MB of the emulator's address range for the emulator", "kind": "int", "default": "0",
                "note": "Default 0 (off). N MB: reservations of 32 MB to 1 GB that are placed above the game's own range because "
                        "that range is tight may not take the lowest N MB of the emulator's 16 GB range; what no longer fits goes "
                        "below it. For a game that reserves many 511 MB ranges and then ends with \"FEXAlloc could not "
                        "allocate\"; 6144 keeps 6 GB. Only with the 16 GB range at 0x7c00000000. Logged as [fex-keep]. Read once "
                        "per session."},
    "env.MADEIRA_WOW_CPU_POOL_ONLY": {"category": "Memory & JIT pool", "title": "32-bit emulator module runs from its JIT-pool copy only",
                "kind": "bool", "default": "1",
                "note": "Default on. Where the kernel lets an image become executable in place (iOS 18; iOS 26 without TXM), the "
                        "32-bit emulator module (xtajit.dll) kept an executable view beside its JIT-pool copy, and its start-up "
                        "code ran in the view while the emulator was called in the copy. On: EXEC is taken back from that view "
                        "once the copy exists. 0: as before. Logged as [wow-cpu-pool]. Read once per session."},
    "d3d12-pso-cached-blob": {"category": "Direct3D 12", "title": "Cached blob of a pipeline", "kind": "bool", "default": "0",
                "note": "Default off: ID3D12PipelineState::GetCachedBlob fails (E_NOTIMPL), as before. 1: it answers a 16-byte "
                        "blob, for an engine that treats the failure as fatal. Creating a pipeline never reads a blob handed "
                        "back. Read once per game start."},
    "d3d12-fl-12-1": {"category": "Direct3D 12", "title": "Claim feature level 12_1", "kind": "bool", "default": "0",
                "note": "Default off: 12_0 is the highest feature level the runtime claims. 1: 12_1, for a game that creates its "
                        "device at 12_1 and stops when that is refused; OPTIONS still reports no conservative rasterization or "
                        "ROVs. Read once per game start."},
    "d3d12-sm-6-7": {"category": "Direct3D 12", "title": "Report shader model 6.7", "kind": "bool", "default": "0",
                "note": "Default off: SHADER_MODEL reports up to 6.6. 1: up to 6.7, for a game that requires it; the converter "
                        "may still refuse a 6.7 shader, which fails its pipeline like any other conversion failure. Read once "
                        "per game start."},
    "d3d12-raytracing-tier": {"category": "Direct3D 12", "title": "Experiment: report a ray-tracing tier", "kind": "int",
                "default": "0",
                "note": "Experiment, default 0. 10 or 11 reports DXR tier 1.0 or 1.1 in OPTIONS5 although the runtime has no ray "
                        "tracing (its calls stay unimplemented stubs, logged once). Only for finding out whether a game's "
                        "device check wants it."},
    "dxil-tess-patch-topology": {"category": "Direct3D 12", "title": "Experiment: DXIL tessellation with the patch input topology",
                "kind": "bool", "default": "0",
                "note": "Experiment, default off. 1: the stages of a DXIL tessellation pipeline are converted with the "
                        "converter's patch input topology instead of triangles; such shaders are cached apart."},
    "fence-early": {"category": "Direct3D 12", "title": "Fences advance when the GPU reached their batch", "kind": "bool",
                "default": "0",
                "note": "Default off. 1: a job whose command buffers have no query results advances its fence right after the "
                        "GPU's shared event, and its buffers are retired in order on a second thread; under the CPU clamp the "
                        "completion bookkeeping took 2-5 ms per job, which a game that polls its fences many times a frame "
                        "waited for. Jobs with query results, a full ring or upload-guard take the old order. Read once per "
                        "game start; [perf] fence-early lines show it."},
    "query-timestamps": {"category": "Direct3D 12", "title": "Timestamp queries from the CPU clock", "kind": "bool", "default": "0",
                "note": "Default off: every timestamp resolves to zero. 1: a resolved timestamp is the process's monotonic clock "
                        "in ns when the resolve is recorded (plus its place in the range), and GetClockCalibration's GPU value is "
                        "the same clock, for a game that spins on zero timestamps. Nothing is measured on the GPU. Read once per "
                        "game start."},
    "write-buffer-immediate": {"category": "Direct3D 12", "title": "WriteBufferImmediate writes its values", "kind": "bool",
                "default": "0",
                "note": "Default off: the method stays a stub (nothing written). 1: the values are written by the GPU in list "
                        "order and a submission that wrote one is committed at once. CheckFeatureSupport still reports no "
                        "support either way. Read once per game start."},
    "env.MADEIRA_D3D12_CAPS_BY_FAMILY": {"category": "Direct3D 12", "title": "Report 64-bit atomics and wave operations by GPU",
                "kind": "bool", "default": "0",
                "note": "Default off: both are claimed on every GPU, as before. 1: 64-bit atomics (OPTIONS9, OPTIONS11) only on "
                        "Apple9 GPUs (A17 Pro, A18, M3 and later) and wave operations (OPTIONS1) only from Apple7 (A14, M1), for "
                        "an engine that picks shader paths the GPU cannot run."},
    "ignore-volatile-metadata": {"category": "x86 emulation (FEX)", "title": "FEX: x86 ordering for the whole image", "kind": "bool",
                "default": "0",
                "note": "Default off. 1: an x64 image's PE volatile metadata (MSVC /volatileMetadata) is cleared when it is "
                        "mapped, so FEX orders every instruction of it by its TSO settings instead of only the listed ones. "
                        "Slower; for testing memory-ordering bugs. Logged as [fex-vmeta]. Read at session start."},
    "env.MADEIRA_AUDIO_RESUME": {"category": "Audio", "title": "Bring game audio back after an interruption", "kind": "bool",
                "default": "0",
                "note": "Default off: after a call, Siri, an alarm or a suspension the sound stays off until the game restarts. "
                        "1: the audio session is activated again and the output restarted; while iOS holds it stopped the game's "
                        "audio clock keeps running. Logged as [audio] interruption began / ended. Read when the session starts."},
    "env.MADEIRA_AUDIO_GAIN": {"category": "Audio", "title": "Game volume at the output (%)", "kind": "int", "default": "100",
                "note": "Percent of the game's level, 10-200; unset or 100 leaves it unchanged. Read once, at the first audio "
                        "endpoint. Set it in the game's own file."},
    "env.MADEIRA_TAIL_CARVE_EXEC_CHECK": {"category": "Memory & JIT pool", "title": "Refuse a code buffer that cannot execute",
                "kind": "bool", "default": "1",
                "note": "Default on: a new emulator code buffer whose first 16 MB hold a JIT-pool page that lost execute "
                        "permission for good is refused, and the emulator asks for half the size elsewhere. 0: every buffer is "
                        "granted, as before. Read once per session."},
    "env.MADEIRA_EA_CEF": {"category": "Memory & JIT pool", "title": "A store launcher's Chromium in one process", "kind": "bool",
                "default": "0",
                "note": "Default off; set with env.MADEIRA_SC_PA_POOLS = 2 for the EA app's launcher. EADesktop.exe runs "
                        "--single-process with V8 --jitless (MADEIRA_JITLESS = 0 keeps V8's JIT), its --type= children are "
                        "refused, and its four PartitionAlloc pools get the four 16 GB slots of the address band instead of "
                        "overlapping. No effect on any other program."},
    "env.MADEIRA_EA_CEF_FLAGS": {"category": "Memory & JIT pool", "title": "Extra EADesktop.exe switches", "kind": "text", "default": "",
                "note": "Appended verbatim to EADesktop.exe's command line while env.MADEIRA_EA_CEF is on (e.g. --disable-gpu)."},
    "env.MADEIRA_EA_CEF_CMDLINE": {"category": "Memory & JIT pool", "title": "Rewrite EADesktop.exe's command line", "kind": "bool",
                "default": "1",
                "note": "Default on. 0: while env.MADEIRA_EA_CEF is on, EADesktop.exe's command line is not rewritten; its "
                        "--type= children are still refused. For testing a switch the launcher may not know."},
    "env.MADEIRA_NTDLL_DATA_SYNC_RANGE": {"category": "Memory & JIT pool", "title": "ntdll data patches copy only the bytes asked for",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: when a 64-bit game changes the protection of a few bytes of ntdll's writable data, only "
                        "those bytes are copied to the copy ntdll runs from, not the whole page (which also overwrote live "
                        "callbacks next to the slot). Logged as [ntdll-data-sync]. Read once per session."},
    "env.MADEIRA_FAULT_LOOP_GUEST_PROGRESS": {"category": "Exceptions & threads",
                "title": "A run of breakpoints at different addresses is not a stuck thread", "kind": "bool", "default": "0",
                "note": "Default off. 1: the loop breaker (50 faults at one place end the thread) no longer counts int3 traps at "
                        "different guest addresses as one stuck fault, though the emulator raises all of them from one host "
                        "instruction. Logged as [fault-progress]. Read once per session."},
    "env.MADEIRA_FAULT_GUARD_GUEST_RIP": {"category": "Exceptions & threads", "title": "Fault guards tell FEX's invalid instructions apart",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: the fault-storm guards also key an invalid-instruction delivery on the guest instruction "
                        "FEX saved, so a program that steps over a long run of them in its own handler is not ended while it "
                        "advances, and the 50-fault page breaker counts memory faults only. Logged as [redeliv] guest_rip. Read "
                        "once per session."},
    "env.MADEIRA_FAULT_GUARD_RATE": {"category": "Exceptions & threads", "title": "Fault-storm guards end only a real storm",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a run of 2000 faults at one instruction ends the game only when it is dense (inside half "
                        "a second) or presenting makes no progress, and the 5-repeat guard counts per thread within 5 ms; for a "
                        "Unity title that throws managed exceptions through null-check traps while it keeps drawing. Read once "
                        "per session."},
    "env.MADEIRA_VCRT_ARM64_KEY": {"category": "Wine core (ntdll)", "title": "ARM64 Visual C++ runtime marker", "kind": "text", "default": "",
                "note": "Default empty: nothing written. 1 (or a version such as 14.50.35717): the session has the ARM64 Visual "
                        "C++ 2015-2022 redistributable's Installed marker (volatile keys; one the prefix has is left alone), for "
                        "an Unreal bootstrap program that sees an ARM64 machine and stops asking for that redistributable "
                        "(exit 0x2329). Read at session start."},
    "env.MADEIRA_TINY_WINDOW_FIX": {"category": "Windows, display & input", "title": "Size a tiny game window to the screen",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: a window a swapchain presents into whose client area stays under 160x120 for 3 seconds "
                        "while the swapchain draws 320x200 or more is sized to the virtual screen (at most twice per window). "
                        "Needs a desktop (Dock) session. Logged as [tiny-win]. Read at session start."},
    "env.MADEIRA_RECOVERY_LOG_SAMPLE": {"category": "Exceptions & threads", "title": "Sample routine instruction recovery logs",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: of FEX's records about each recovered invalid instruction (C000001D) only the first 16 "
                        "and every 1024th are kept, and of the shared-trap ILL reports the first 8 and every 1024th; only the "
                        "log changes. For a game that recovers thousands a second. Read before guest threads start."},
    "env.MADEIRA_RESERVED_REMAP": {"category": "Memory & JIT pool", "title": "Last resort for a refused window placement",
                "kind": "bool", "default": "1",
                "note": "Default on, and only on the path that already fails: when the system refuses every placement of a "
                        "32-bit program's request inside its 4 GB window (ENOMEM), the first refused range, which Wine's tables "
                        "call free, is unmapped and mapped again without overwriting; if that fails the request fails as before. "
                        "0: no last resort. Read when a program starts."},
    "env.MADEIRA_VDCFG_PATH": {"category": "Windows, display & input", "title": "QueryDisplayConfig lists the monitor's path",
                "kind": "bool", "default": "0",
                "note": "Default off: success with no path, as before. 1: QueryDisplayConfig returns the virtual monitor's one path "
                        "(source and target mode, the desktop size) and DisplayConfigGetDeviceInfo names its source, target and "
                        "adapter, for a game that builds its fullscreen window from the paths."},
    "env.MADEIRA_REDELIV_CHILD_ONLY": {"category": "Exceptions & threads", "title": "A fault storm in a helper program ends only that program",
                "kind": "bool", "default": "1",
                "note": "Default on: when the fault-storm guard gives up on a thread of a program the session started (a "
                        "launcher's helper), that program ends and the app keeps running; the session's first program keeps the "
                        "old ending. 0: the whole app ends for every storm, as before."},
    "env.MADEIRA_USER_VA_GB": {"category": "Memory & JIT pool", "title": "Address space the game is told it has (GiB)", "kind": "int",
                "default": "0",
                "note": "Default 0 (off): a 64-bit game is told its user address space is what the device maps. N (4-4096, never "
                        "more than the real figure): it is told N GiB; only the figure changes, not placement. For a game that "
                        "sizes one reservation from it and quits when it cannot get it (32 is the value to try). Logged as "
                        "[user-va]. Read once per session."},
    "env.MADEIRA_ANON_CAS_FLUSH": {"category": "Exceptions & threads", "title": "Atomic code patches go through the emulator", "kind": "bool",
                "default": "0",
                "note": "Default off: a compare-and-swap the game does on its own executable memory (a .NET runtime patching a stub "
                        "it ran) is completed by the host. 1: it is handed to the emulator, which discards its translation of the "
                        "page first, as in older builds. Slower. Logged as [anon-cas]. Read once per session."},
    "env.MADEIRA_VA_PRESSURE_GAP_OK": {"category": "Memory & JIT pool", "title": "A slow scan through the refused hole is not pressure",
                "kind": "bool", "default": "0",
                "note": "Default off. 1: an address-space scan that succeeded after grinding through the hole iOS refuses below the "
                        "app image does not mark the address space as under pressure (which steers big reservations away from "
                        "the swap tier). Read once."},
    "env.MADEIRA_ATOM_ARG": {"category": "Windows, display & input", "title": "Atoms in a 32-bit program's class and property names",
                "kind": "bool", "default": "1",
                "note": "Default on: a class or property name given as an atom that arrives offset by the 32-bit program's window "
                        "base (inside its never-mapped first 64 KB) is taken as the atom, not read as a string pointer. 0 turns "
                        "it off."},
    "env.DOTNET_EnableWriteXorExecute": {"category": "Wine core (ntdll)", "title": ".NET runtime: W^X mapping", "kind": "text", "default": "",
                "note": "Passed into the game's environment and read by the .NET (CoreCLR) runtime itself. 0 turns off its "
                        "write-xor-execute double mapping of JIT code, for a .NET game whose JIT stops at start."},
    "env.DOTNET_GCRegionRange": {"category": "Wine core (ntdll)", "title": ".NET runtime: GC region reservation", "kind": "text", "default": "",
                "note": "Passed into the game's environment and read by the .NET runtime: the size (hex bytes) of the address "
                        "range its regions GC reserves at start, for a .NET game whose default reservation fails."},
    "env._JAVA_OPTIONS": {"category": "Wine core (ntdll)", "title": "Java runtime options", "kind": "text", "default": "",
                "note": "Passed into the game's environment and read by a bundled Java runtime (e.g. -XX:-UseZGC to leave a garbage "
                        "collector off that cannot map its heap here)."},
    "dxmt": {"title": "DXMT options (a=b;c=d)",
             "note": "Exported as DXMT_CONFIG with the options joined by ';', a library game's own dxmt options after these: "
                     "e.g. d3d11.mipClampBC=1;d3d11.preferredMaxFrameRate=30. DXMT reads at most 259 characters of it, "
                     "and nothing at all from a longer value (ml1255)."},
    "metalfx-upscale": {"title": "MetalFX upscaling factor", "kind": "choice",
             "note": "Scales the presented picture with Apple's MetalFX spatial scaler (Direct3D 11 and 12). Usually set per game in Game details > Display.",
             "choices": [("", "Off"), ("1.5", "1.5x"), ("2", "2x")]},
}


def category(path):
    p = path.replace("\\", "/")
    rules = [
        ("madeira-d3d12", "Direct3D 12"), ("dxmt", "Direct3D 9/10/11 (DXMT)"),
        ("madeira-dock", "Steam & Dock"), ("FEX/", "x86 emulation (FEX)"),
        ("winegstreamer", "Media"), ("audio", "Audio"), ("madsync", "Synchronisation"),
        ("/sync", "Synchronisation"), ("virtual_ios", "Memory & JIT pool"), ("JITAllocator", "Memory & JIT pool"),
        ("StikJIT", "Memory & JIT pool"), ("signal_", "Exceptions & threads"), ("thread", "Exceptions & threads"),
        ("wine/server", "Wine server"), ("wineserver", "Wine server"), ("win32u", "Windows, display & input"),
        ("Winios", "Windows, display & input"), ("Input", "Windows, display & input"), ("Gamepad", "Controllers"),
        ("Touch", "Controllers"), ("dinput", "Controllers"), ("xinput", "Controllers"),
        ("Steam", "Steam & Dock"), ("Dock", "Steam & Dock"), ("Onboarding", "Steam & Dock"),
        ("Library", "App & front end"), ("FPSOverlay", "App & front end"), ("app/Madeira", "App & front end"),
        ("ntdll", "Wine core (ntdll)"), ("wine/dlls", "Wine libraries"), ("build/", "Wine core (ntdll)"),
    ]
    for needle, name in rules:
        if needle in p:
            return name
    return "Other"


def comment_near(lines, i):
    """The comment on line i, else the nearest comment block within 8 lines above."""
    def trailing(line):
        for m in re.finditer(r'//+|/\*+', line):
            if line[:m.start()].count('"') % 2 == 0:   # not inside a string literal
                return line[m.end():]
        return None
    parts = []
    t = trailing(lines[i])
    if t and t.strip(" */"):
        parts.append(t)
    else:
        j = i - 1
        while j >= 0 and j >= i - 8 and not lines[j].strip().startswith(("//", "/*", "*")) \
                and not lines[j].rstrip().endswith("*/"):
            j -= 1
        block = []
        while j >= 0 and j >= i - 14:
            t = lines[j].strip()
            if t.startswith(("//", "/*", "*")) or t.endswith("*/"):
                if not t.startswith(("//", "/*", "*")):
                    t = trailing(t) or t
                block.insert(0, t)
                j -= 1
            else:
                break
        parts += block
    text = " ".join(parts)
    text = re.sub(r'/\*+|\*+/|//+', ' ', text)
    text = re.sub(r'(^|\s)\*(\s|$)', ' ', text)
    text = re.sub(r'\s+', ' ', text).strip(" *-")
    return (text[:237] + "...") if len(text) > 240 else text


def scan():
    opts = {}
    for repo, dirs in REPOS.items():
        base = os.path.join(ROOT, repo)
        if not os.path.isdir(base):
            continue
        out = subprocess.run(["git", "-C", base, "ls-files", "--"] + dirs,
                             capture_output=True, text=True).stdout.split()
        for rel in out:
            path = os.path.normpath(os.path.join(repo, rel))
            if not path.endswith(EXT) or any(s in path for s in SKIP):
                continue
            try:
                txt = open(os.path.join(ROOT, path), errors="ignore").read()
            except OSError:
                continue
            lines = txt.split("\n")
            for pat, is_env in ((CFG, False), (ENV, True)):
                for m in pat.finditer(txt):
                    reader, name, arg = m.group(1), m.group(2), (m.group(3) or "").strip()
                    if is_env or reader == "MadeiraConfig.flag":
                        key = "env." + name
                    else:
                        key = name
                    ln = txt.count("\n", 0, m.start())
                    kind = "bool" if reader in BOOL_READERS else "int" if reader in INT_READERS else "text"
                    dflt = ""
                    if reader in ("madeira_cfg_int", "madeira_cfg_bool", "mad_cfg_int_pe"):
                        dflt = arg if re.fullmatch(r'-?\d+|0x[0-9a-fA-F]+', arg or "") else ""
                    elif reader in ("MadeiraConfig.flag", "flag", "envFlag"):
                        dflt = "0" if arg.endswith("false") else "1" if (not arg or arg.endswith("true")) else ""
                    elif reader in ("madeiraSwitch", "madeira_switch_for_caller"):
                        dflt = "32-bit only"
                    elif reader == "MadeiraConfig.bool":
                        dflt = "1" if arg.endswith("true") else "0"
                    o = opts.setdefault(key, {"key": key, "kind": kind, "default": dflt, "sites": []})
                    if o["kind"] == "text" and kind != "text":
                        o["kind"] = kind
                    if not o["default"] and dflt:
                        o["default"] = dflt
                    o["sites"].append((path, ln + 1, comment_near(lines, ln)))
    # The engine code that acts on an option describes it better than the
    # Settings UI that merely reads it back: prefer sites outside app/.
    for o in opts.values():
        sites = sorted(o.pop("sites"), key=lambda s: (s[0].startswith("app/"), s[0], s[1]))
        o["category"] = category(sites[0][0])
        o["note"] = next((n for _, _, n in sites if n), "")
        files = []
        for p, _, _ in sites:                 # file names only: line numbers would make
            if p not in files:                # the catalog stale on every unrelated edit
                files.append(p)
        o["sources"] = files[:3]
    for key, extra in OVERLAY.items():
        o = opts.setdefault(key, {"key": key, "kind": "text", "default": "", "category": "App & front end",
                                  "note": "", "sources": []})
        o.update({k: v for k, v in extra.items()})
    return [opts[k] for k in sorted(opts, key=lambda k: (opts[k]["category"], k.lower()))]


def swift_str(s):
    return json.dumps(s, ensure_ascii=False)


def render(opts):
    out = ["// Generated by build/tools/gen-config-catalog.py from the sources that read each option.",
           "// Do not edit by hand: run the script (tests/host/check-config-catalog.py fails when stale).",
           "", "extension ConfigCatalog {", "    static let generated: [ConfigOption] = ["]
    for o in opts:
        choices = ", ".join(f"({swift_str(v)}, {swift_str(l)})" for v, l in o.get("choices", []))
        sources = ", ".join(swift_str(s) for s in o["sources"])
        out.append(f'        ConfigOption(key: {swift_str(o["key"])}, title: {swift_str(o.get("title", ""))}, '
                   f'kind: .{o["kind"]}, defaultValue: {swift_str(o["default"])}, '
                   f'category: {swift_str(o["category"])}, note: {swift_str(o["note"])}, '
                   f'choices: [{choices}], sources: [{sources}]),')
    out += ["    ]", "}", ""]
    return "\n".join(out)


def main():
    text = render(scan())
    if "--check" in sys.argv:
        cur = open(OUT).read() if os.path.exists(OUT) else ""
        if cur != text:
            print("ConfigCatalog.generated.swift is out of date: run build/tools/gen-config-catalog.py")
            return 1
        print("ConfigCatalog.generated.swift is current")
        return 0
    open(OUT, "w").write(text)
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
