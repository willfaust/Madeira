#import "JITAllocator.h"
#import "FEXBridge.h"
#import "WineServerBridge.h"
#import "WineProcessBridge.h"
#import "IOSDisplayShim.h"
#import "Winios/Winios.h"
#import "Winios/WiniosCursor.h"
// ml2106: rumble / DualSense output to the physical pad (PadOutput.m)
#import "PadOutput.h"
// Steam content decoders (liblzma shim, zstd decoder, zip chunks), used by the owned library's downloads.
#import "SwiftSteam/lzma_shim.h"
// On-device remote pairing for Built-in StikJIT (build/rppairing-ios, JITPairing.swift).
#import "MadeiraRPPairing.h"

// Wine file-based logging (server_ios.c)
void wine_log_set_file(const char *path);

// UI log callback (wine_log_ios.c) — forwards C logs to Swift UI
typedef void (*wine_ui_log_callback_t)(const char *message);
void wine_set_ui_log_callback(wine_ui_log_callback_t cb);

// DXMT present counter (winemetal_unix.c) — for SwiftUI FPS overlay
#include <stdint.h>
uint64_t madeira_get_present_count(void);
// DXMT presents plus OpenGL presents (Winios/WiniosGL.m)
uint64_t madeira_frame_count(void);
// ml1174: GPU busy time for the performance overlay (winemetal_unix.c). While
// enabled, each committed command buffer adds its GPU time (union) on completion.
void madeira_gpu_meter_enable(int on);
double madeira_gpu_meter_busy_seconds(void);
uint64_t madeira_gpu_meter_cmdbufs(void);
// ml1098: ask the D3D12 runtime to capture the next N frames (winemetal_unix.c)
void madeira_capture_request(int frames);
// ml1133: ECO switch (ntdll unix sync.c). 1 = every guest thread drops to a
// low QoS class (efficiency cores, lower clocks) to save the SoC burst budget.
void madeira_set_eco(int on);
int madeira_get_eco(void);
// ml1136: live GPU encoder-sync mode (winemetal_unix.c): 1, 5, 6; 7 = mode 0 (no fences).
// The D3D12 runtime applies it at the next Present, for lists that start after that.
void madeira_set_fence_mode(int mode);

// DXMT vsync-lock toggle (winemetal_unix.c) — 1 = pace presents to 60
// via afterMinimumDuration, 0 = free-run to display max (120 ProMotion,
// requires CADisableMinimumFrameDurationOnPhone in Info.plist).
// Read per present; safe to flip live mid-game.
void madeira_set_vsync_locked(int locked);
int madeira_get_vsync_locked(void);

// ml1050: what the PANEL can do and what we asked it for, published from
// Swift (only UIKit knows) so the native [frame] line can print the
// quantisation grid every present snaps to. panel_hz = the display's own
// maximum, intent_hz = the CADisplayLink rate currently requested (0 = no
// intent armed). Both are diagnostics; nothing branches on them.
// Defined by DXMT from willfaust/dxmt#1 on; IOSDisplayShim.m carries a weak
// no-op fallback, so the app links and runs against main's DXMT too.
void madeira_set_display_max_fps(int panel_hz, int intent_hz);
// 1 when DXMT's own madeira_set_display_max_fps (and with it the 30 FPS cap,
// vsync mode 3) is linked; valid after the first madeira_set_display_max_fps call.
int madeira_dxmt_has_display_pacing(void);
// 1 when DXMT has the 40 FPS cap (vsync mode 4). Defined by DXMT; IOSDisplayShim.m
// carries a weak fallback that returns 0, so the app links against a DXMT without it.
int madeira_dxmt_has_40_cap(void);

/* ml526: startup phase timeline (Winios.m) */
void winios_phase(const char *name);

/* madeira-d3d12: M1 shader-converter canary, compiled into libdxmt.
 * Returns the number of failed checks; 0 means the gate passed. Output goes to
 * stderr, which is already captured into madeira-log.txt. */
int madeira_d3d12_canary_run(const char *fixture_dir, const char *dylib_path,
                             void (*sink)(const char *));
/* Same run, but also writes the full per-check transcript to log_path, which is
 * how the in-app detail is captured: stderr is not redirected into
 * madeira-log.txt until later in startup. */
int madeira_d3d12_canary_run_log(const char *fixture_dir, const char *dylib_path,
                                 void (*sink)(const char *), const char *log_path,
                                 const char *build_id);
