// WineProcessBridge.m - Initialize Wine's ntdll Unix-side on iOS
// This calls __wine_main() to bootstrap the Wine process, connecting
// to the already-running wineserver thread.

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <pthread.h>
/* AVFoundation: AVAudioSession activation for the Tier-2 audio driver
 * (audio_null_ios.c RemoteIO backend). AudioToolbox: pulls the framework
 * in via autolink — the static-lib driver code can't autolink itself. */
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <setjmp.h>
#include <stdlib.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>
#include <limits.h>
#include <string.h>

#include "WineProcessBridge.h"
#include "WineServerBridge.h"
#include "PrefixExtractor.h"
#include "FEXBridge.h"  // fex_get_jit_write_offset()

// Thread-local globals for wine_ios_exit longjmp (used by wine_ios_exit.h shim in ntdll)
// Each Wine "process" thread has its own jmpbuf so child processes can exit independently.
_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;


static os_log_t wine_proc_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.madeira.emulator", "wine-proc"); });
    return log;
}

#define LOG(fmt, ...) os_log(wine_proc_log(), "[WineProc] " fmt, ##__VA_ARGS__)

/* ml803: the one override file the launch sequence reads directly rather than
 * handing to a native library. Returns its trimmed body, or nil when the file
 * is absent or empty (which means "use the built-in default"). The Settings
 * screen writes `-all` here to switch Wine's channels off for a performance
 * run; a hand-written value from the Files app works the same way. */
static NSString *madeira_winlog_file_body(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) return nil;
    NSString *path = [docs stringByAppendingPathComponent:@"madeira-winlog.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!text) return nil;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length ? text : nil;
}

/* ---- ml581: undo the hand-made AppData skeleton ------------------------
 *
 * While chasing the Steam login window I hand-created
 * drive_c/users/mobile/AppData/{Roaming,LocalLow}/... on the device with
 * devicectl, each leaf holding a placeholder ".keep" file (devicectl cannot
 * copy an empty directory). That was a mistake: Wine populates the profile
 * itself, and it decides per-directory by EXISTENCE. Pre-creating Roaming
 * made every one of those checks pass, so the population that builds
 * Start Menu\Programs never ran -- the taskbar lost its Start button and
 * the virtual desktop stopped booting properly, four runs running.
 *
 * devicectl has no delete verb, so the undo has to live in the app. This
 * deletes ONLY files literally named ".keep", then removes directories that
 * are empty as a result, walking bottom-up and stopping at AppData itself.
 * A directory holding anything real is left completely alone, so this can
 * never destroy user or Steam data -- it only restores the "absent" state
 * Wine's population is gated on. Idempotent: after the first clean boot
 * repopulates the tree, there are no .keep files left and it does nothing. */
static int madeira_prune_keep_tree(const char *dir, int depth)
{
    DIR *d = opendir( dir );
    if (!d) return 0;                       /* absent/unreadable => nothing to do */

    int survivors = 0;
    struct dirent *ent;
    while ((ent = readdir( d )))
    {
        if (!strcmp( ent->d_name, "." ) || !strcmp( ent->d_name, ".." )) continue;

        char path[PATH_MAX];
        if (snprintf( path, sizeof(path), "%s/%s", dir, ent->d_name ) >= (int)sizeof(path))
        {
            survivors++;                    /* can't address it => treat as real */
            continue;
        }

        struct stat st;
        if (lstat( path, &st ) != 0) { survivors++; continue; }

        if (S_ISDIR( st.st_mode ) && depth > 0)
        {
            if (madeira_prune_keep_tree( path, depth - 1 ) > 0) survivors++;
            else if (rmdir( path ) != 0) survivors++;   /* non-empty or denied */
            else LOG( "keep-prune: rmdir %{public}s", path );
        }
        else if (S_ISREG( st.st_mode ) && !strcmp( ent->d_name, ".keep" ))
        {
            if (unlink( path ) != 0) survivors++;
            else LOG( "keep-prune: unlink %{public}s", path );
        }
        else survivors++;                   /* anything real keeps the dir alive */
    }
    closedir( d );
    return survivors;
}

/* ---- ml666: PROFILE REPAIR — the "usersmadeira" escaping bug -------------
 *
 * The shipped .reg files wrote  "C:\\users\madeira\\AppData\\Roaming"  with a
 * SINGLE backslash before `madeira`. In .reg syntax `\\` is a literal backslash
 * and a lone `\` starts an escape; `\m` is not a valid escape, so the backslash
 * was dropped and every shell folder resolved to  C:\usersmadeira\...  -- a
 * directory that never existed. 57 sites across user.reg/userdef.reg plus 3
 * already-collapsed in system.reg.
 *
 * It degraded silently for months: %TEMP% pointed there too, so Wine happily
 * CREATED C:\usersmadeira\AppData\Local\Temp and filled it (683 files and a CEF
 * cache on the dev device). Only paths whose parents are NOT auto-created broke
 * -- notably LocalLow, where Unity's log CreateDirectory failed, which left
 * stdout closed at _file=-1 and fast-failed the CRT inside _isatty.
 *
 * The template is fixed, but an existing prefix keeps the collapsed strings in
 * its own user.reg (Wine rewrote them after parsing). So repair on disk, before
 * __wine_main, once:
 *   1. rewrite  C:\\usersmadeira  ->  C:\\users\\madeira  in the three .reg files
 *   2. MOVE (never delete) drive_c/usersmadeira/* into drive_c/users/madeira/*
 *   3. ensure the AppData skeleton exists
 * Idempotent and marker-gated. Step 2 merges and refuses to clobber: if a
 * destination already exists the source is left in place for manual review,
 * because that tree holds real user data. */

static int ios_reg_unmangle(const char *path)
{
    FILE *f = fopen( path, "rb" );
    if (!f) return 0;
    fseek( f, 0, SEEK_END ); long n = ftell( f ); fseek( f, 0, SEEK_SET );
    if (n <= 0 || n > (64 << 20)) { fclose( f ); return 0; }
    char *buf = malloc( (size_t)n + 1 );
    if (!buf) { fclose( f ); return 0; }
    size_t got = fread( buf, 1, (size_t)n, f );
    fclose( f );
    if (got != (size_t)n) { free( buf ); return 0; }
    buf[n] = 0;

    /* ml667: anchored on "C:" originally, which MISSED the one value that has
     * no drive letter -- HOMEPATH = "\\usersmadeira". HOMEDRIVE+HOMEPATH is a
     * standard way to reach the profile, so that single miss left the default
     * path broken while everything else looked repaired. Match the collapsed
     * token itself; it reconstructs correctly with or without a drive prefix. */
    static const char BAD[]  = "usersmadeira";
    static const char GOOD[] = "users\\\\madeira";
    const size_t bl = sizeof(BAD) - 1, gl = sizeof(GOOD) - 1;
    size_t hits = 0;
    for (char *q = buf; (q = strstr( q, BAD )); q += bl) hits++;
    if (!hits) { free( buf ); return 0; }

    char *out = malloc( (size_t)n + hits * (gl - bl) + 1 ), *w;
    if (!out) { free( buf ); return 0; }
    w = out;
    for (const char *r = buf; *r; )
    {
        if (!strncmp( r, BAD, bl )) { memcpy( w, GOOD, gl ); w += gl; r += bl; }
        else *w++ = *r++;
    }
    *w = 0;

    /* write via temp + rename so a kill mid-write cannot truncate the registry */
    char tmp[PATH_MAX];
    snprintf( tmp, sizeof(tmp), "%s.ml666", path );
    FILE *o = fopen( tmp, "wb" );
    int ok = 0;
    if (o)
    {
        ok = fwrite( out, 1, (size_t)(w - out), o ) == (size_t)(w - out);
        if (fclose( o ) != 0) ok = 0;
        if (ok && rename( tmp, path ) != 0) ok = 0;
        if (!ok) unlink( tmp );
    }
    LOG( "profile-repair: %{public}s %zu path(s) %{public}s", path, hits, ok ? "rewritten" : "FAILED" );
    free( buf ); free( out );
    return ok ? (int)hits : 0;
}

/* Move src into dst, merging. Existing destinations are never overwritten. */
static void ios_merge_move(const char *src, const char *dst, int depth)
{
    DIR *d;
    struct dirent *ent;
    if (depth <= 0) return;
    if (rename( src, dst ) == 0) { LOG( "profile-repair: moved %{public}s", src ); return; }
    if (errno != ENOTEMPTY && errno != EEXIST && errno != ENOTDIR) return;
    if (!(d = opendir( src ))) return;
    while ((ent = readdir( d )))
    {
        char sp[PATH_MAX], dp[PATH_MAX];
        struct stat st;
        if (!strcmp( ent->d_name, "." ) || !strcmp( ent->d_name, ".." )) continue;
        if (snprintf( sp, sizeof(sp), "%s/%s", src, ent->d_name ) >= (int)sizeof(sp)) continue;
        if (snprintf( dp, sizeof(dp), "%s/%s", dst, ent->d_name ) >= (int)sizeof(dp)) continue;
        if (lstat( dp, &st ) != 0) { if (rename( sp, dp ) == 0) continue; }
        if (lstat( sp, &st ) == 0 && S_ISDIR( st.st_mode ))
        {
            mkdir( dp, 0755 );
            ios_merge_move( sp, dp, depth - 1 );
        }
        /* a colliding FILE is left alone -- never clobber real user data */
    }
    closedir( d );
    rmdir( src );                       /* only succeeds once genuinely empty */
}

static void madeira_repair_profile(NSString *prefix)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *marker = [prefix stringByAppendingPathComponent:@".madeira-profile-repaired-ml667"];
    if ([fm fileExistsAtPath:marker]) return;

    int fixed = 0;
    for (NSString *reg in @[ @"user.reg", @"userdef.reg", @"system.reg" ])
        fixed += ios_reg_unmangle( [prefix stringByAppendingPathComponent:reg].fileSystemRepresentation );

    NSString *bad  = [prefix stringByAppendingPathComponent:@"drive_c/usersmadeira"];
    NSString *good = [prefix stringByAppendingPathComponent:@"drive_c/users/madeira"];
    if ([fm fileExistsAtPath:bad])
    {
        [fm createDirectoryAtPath:good withIntermediateDirectories:YES attributes:nil error:nil];
        ios_merge_move( bad.fileSystemRepresentation, good.fileSystemRepresentation, 12 );
    }

    /* The skeleton Wine's existence checks gate on. Creating it is safe here --
     * unlike the ml581 mistake, these are the REGISTERED profile paths. */
    for (NSString *leaf in @[ @"AppData/Roaming", @"AppData/Local", @"AppData/LocalLow",
                              @"AppData/Roaming/Microsoft/Windows/Start Menu/Programs" ])
        [fm createDirectoryAtPath:[good stringByAppendingPathComponent:leaf]
      withIntermediateDirectories:YES attributes:nil error:nil];

    /* ml667: only claim completion once the collapsed tree is actually gone.
     * ios_merge_move refuses to clobber, so a colliding file leaves the source
     * alive -- marking done there would strand that data forever. */
    if (![fm fileExistsAtPath:bad])
        [@"ml667" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    else
        LOG( "profile-repair: %{public}s still present -- will retry next launch", bad.UTF8String );
    LOG( "profile-repair: complete (%d registry path(s) rewritten)", fixed );
}

static void madeira_undo_appdata_skeleton(NSString *prefix)
{
    /* ml666: SCOPED DOWN. As written this walked EVERY user and removed ANY
     * empty tree, which made it far more destructive than its own comment
     * claimed. Two consequences, both observed:
     *
     *   - It deleted the legitimate, registered users/madeira AppData skeleton
     *     that prefix-template.tar.gz ships -- the very directories Wine's
     *     population and Unity's log path depend on.
     *   - Given a freshly created empty Roaming/LocalLow it removed those too,
     *     and nothing recreates them, so the profile stayed permanently absent.
     *
     * It also never actually worked on the artifacts it was written for: the
     * ml581 devicectl push left those directories owned by uid 0, so unlink()
     * inside them always failed. It has been a silent no-op since it shipped.
     *
     * Now: users/mobile ONLY (the sole path the ml581 experiment touched), the
     * three leaf roots are never themselves removed, and the whole thing is
     * marker-gated so it runs once instead of on every launch. */
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *marker = [prefix stringByAppendingPathComponent:@".madeira-keepprune-done-ml666"];
    if ([fm fileExistsAtPath:marker]) return;

    NSString *appdata = [prefix stringByAppendingPathComponent:@"drive_c/users/mobile/AppData"];
    for (NSString *leaf in @[ @"Roaming", @"LocalLow", @"Local" ])
    {
        /* depth 6 covers Roaming/<Vendor>/<Product>/<...> comfortably; the
         * recursion is bounded so a symlink loop can't run away. Only the
         * .keep placeholders and the empty dirs they propped up are removed --
         * the leaf root itself always stays. */
        NSString *path = [appdata stringByAppendingPathComponent:leaf];
        madeira_prune_keep_tree( path.fileSystemRepresentation, 6 );
    }
    [@"ml666" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}


// Wine's main entry point (from ntdll unix loader.c, statically linked)
extern void __wine_main(int argc, char *argv[]);

// File-based logging (from server_ios.c)
extern void wine_log_set_file(const char *path);

static pthread_t g_wine_thread;
static volatile int g_wine_running = 0;
static char *g_prefix_path = NULL;

/***********************************************************************
 *           madeira_seed_prefix_if_needed
 *
 * Extract the bundled prefix template on first launch and (re)create the
 * dosdevices links. Idempotent: the .update-timestamp probe makes every call
 * after the first a single stat().
 *
 * ml588 — MUST RUN BEFORE THE WINESERVER STARTS. This used to live inside
 * wine_process_thread(), which starts ~2s AFTER wineserver_start(). On a fresh
 * prefix that ordering silently destroyed the shipped registry: wineserver's
 * init_registry() (server/main.c:268) found no system.reg, built an EMPTY
 * registry, and its first save then overwrote the 3.7MB / 17,479-key file the
 * template had just written -- ml587's device prefix was left with 24 keys.
 * Everything registry-backed broke on a fresh install while a hand-maintained
 * dev prefix kept working, which is why this hid for so long: no WinRT
 * ActivatableClassId (Thumper aborts on RoGetActivationFactory for
 * Windows.Gaming.Input.Gamepad), and no Fonts keys (the #61/#70 dwrite fix).
 */
void madeira_seed_prefix_if_needed(const char *prefix_path) {
    @autoreleasepool {
        if (!prefix_path) return;
        NSString *prefix = [NSString stringWithUTF8String:prefix_path];
        NSString *stamp = [prefix stringByAppendingPathComponent:@".update-timestamp"];
        NSFileManager *fm = [NSFileManager defaultManager];

        [fm createDirectoryAtPath:prefix withIntermediateDirectories:YES attributes:nil error:nil];

        if (![fm fileExistsAtPath:stamp]) {
            NSString *tgz = [[NSBundle mainBundle] pathForResource:@"prefix-template" ofType:@"tar.gz"];
            if (!tgz) {
                LOG("prefix-template.tar.gz missing from bundle!");
            } else {
                LOG("Seeding prefix from %{public}s", tgz.UTF8String);
                if (madeira_extract_prefix_tgz(tgz.UTF8String, prefix_path) != 0) {
                    LOG("prefix extraction FAILED");
                } else {
                    LOG("prefix seeded to %{public}s", prefix_path);
                }
            }
        }

        // (Re)create dosdevices/c: -> ../drive_c. The tarball omits
        // dosdevices because Mac's z: -> / is wrong here.
        NSString *dosdev = [prefix stringByAppendingPathComponent:@"dosdevices"];
        [fm createDirectoryAtPath:dosdev withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *cLink = [dosdev stringByAppendingPathComponent:@"c:"];
        [fm removeItemAtPath:cLink error:nil];
        [fm createSymbolicLinkAtPath:cLink withDestinationPath:@"../drive_c" error:nil];

        /* ml666: repair the usersmadeira escaping damage BEFORE anything reads
         * the registry, then the (now scoped) ml581 legacy cleanup. */
        madeira_repair_profile( prefix );
        /* ml581: see madeira_undo_appdata_skeleton() above. */
        madeira_undo_appdata_skeleton( prefix );
    }
}

static void *wine_process_thread(void *arg) {
    @autoreleasepool {
        /* Perf: the guest main thread runs ON this pthread. Promote to
         * USER_INTERACTIVE so it schedules on P-cores with minimal kernel
         * timer coalescing (same rationale as start_thread in
         * thread_ios.c — default QoS costs tens of ms of sleep leeway). */
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        LOG("Wine process thread started");

        /* ml588: seeding itself now happens in wineserver_start(), BEFORE the
         * server loads the registry. Kept here as a safety net for any path
         * that reaches Wine without going through wineserver_start() — the
         * stamp probe makes it a no-op stat once the prefix exists. */
        madeira_seed_prefix_if_needed(g_prefix_path);

        // Set environment for Wine
        setenv("WINEPREFIX", g_prefix_path, 1);
        setenv("HOME", g_prefix_path, 1);

        // Skip check_command_line / reexec_loader
        setenv("WINELOADERNOEXEC", "1", 1);

        // Set DLL search path to app bundle (contains aarch64-windows/ with PE DLLs)
        {
            NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
            setenv("WINEDLLPATH", bundlePath.UTF8String, 1);
            LOG("WINEDLLPATH=%{public}s", bundlePath.UTF8String);
        }

        /* Wine trace channels.
         *
         * 2026-05-19 perf pivot: the verbose default (err+all, fixme+all,
         * warn+module, warn+file, trace+process, trace+module, trace+loaddll,
         * trace+loadorder, trace+win, trace+user32, trace+syscall, trace+file)
         * was generating ~220 KB/sec of log writes — the dominant source of
         * the 1.35s-per-frame menu rendering. trace+syscall + trace+file alone
         * are likely 90%+ of the volume (every Nt* call writes 3-5 log lines).
         *
         * Default is now PERF: only err+all (so we still see real failures).
         * For debugging, set MADEIRA_DEBUG_VERBOSE=1 in the environment to
         * restore the full trace channel set. */
        {
            const char *verbose = getenv("MADEIRA_DEBUG_VERBOSE");
            if (verbose && *verbose && *verbose != '0') {
                setenv("WINEDEBUG", "err+all,fixme+all,warn+module,warn+file,trace+process,trace+module,trace+loaddll,trace+loadorder,trace+win,trace+user32,trace+syscall,trace+file", 1);
                /* The renderer's own logger is separate from Wine's, so a debug
                 * run must clear a level a previous run in this process set. */
                unsetenv("DXMT_LOG_LEVEL");
                LOG("WINEDEBUG = verbose (MADEIRA_DEBUG_VERBOSE set)");
            } else {
                /* err+all keeps real failure messages, but subtract err+virtual
                 * because our iOS virtual_ios.c uses ERR() for informational
                 * traces ("iOS vm_protect RW+COPY OK", "iOS JIT: pool size",
                 * "iOS JIT: copied image"). Those produce thousands of lines
                 * per boot. Real failures in virtual_ios.c use distinctive
                 * FATAL/FAIL prefixes our app surfaces via other paths. */
                /* ml740: warn+seh removed again now the tracing it existed for is
                 * done. It routes every OutputDebugStringA through an exception
                 * dispatch, which is real overhead in hot paths; re-add it only
                 * alongside MADEIRA_TF_TRACE. */
                /* ml803: Documents/madeira-winlog.txt wins over this default.
                 * The Settings screen writes it, and it is the only way to ask
                 * for "no Wine output at all" without a rebuild: an enabled
                 * channel formats a string and writes it, and err+all still
                 * covers page-protection failures and SEH, which are hot on
                 * this stack. MADEIRA_DEBUG_VERBOSE stays the loudest word. */
                NSString *body = madeira_winlog_file_body();
                if (body) {
                    setenv("WINEDEBUG", body.UTF8String, 1);
                    LOG("WINEDEBUG = %{public}s (madeira-winlog.txt)", body.UTF8String);
                } else {
                    setenv("WINEDEBUG", "err+all,err-virtual", 1);
                    LOG("WINEDEBUG = err+all,err-virtual (perf default — set MADEIRA_DEBUG_VERBOSE=1 for full trace)");
                }
                /* ml803: WINEDEBUG does not reach the renderer's own logger.
                 *
                 * DXMT resolves __wine_dbg_output in ntdll and writes every
                 * warn/info line through it, which bypasses Wine's channel
                 * filtering entirely -- so a run with WINEDEBUG=-all still
                 * formats a string, takes a mutex and writes to stderr for
                 * every "unsupported format"-style warning, and those warnings
                 * are per-occurrence, so they land in the middle of a frame.
                 * DXMT_LOG_LEVEL is its own gate: the level names are
                 * trace/debug/info/warn/error/none and the default is info.
                 *
                 * Asking for a silent log means the renderer too, but errors
                 * stay: they are the lines that explain a black screen.
                 *
                 * Cleared in the other branch as well -- this environment
                 * outlives a run, so the level must follow the setting rather
                 * than reflect whichever run set it last. */
                if ([body isEqualToString:@"-all"])
                    setenv("DXMT_LOG_LEVEL", "error", 1);
                else
                    unsetenv("DXMT_LOG_LEVEL");
            }
        }

        // Phase 3D investigation: re-enabled. Investigation C concluded
        // wineserver dispatch is fine; the `ws_log drops at high rate`
        // artifact was the prior false signal. Now chasing a real bug:
        // get_desktop_window's returned HWND fails get_user_object lookup
        // when create_window receives it as req->parent.
        setenv("MADEIRA_WIN32U", "1", 1);

        /* iOS-Madeira ml711: default FNA to its D3D11 backend.
         *
         * FNA3D picks OpenGL by default, and there is no GL on iOS -- our graphics stack
         * is DXMT (D3D11 -> Metal). Marvel Cosmic Invasion loaded FNA3D.dll, immediately
         * pulled in OPENGL32.DLL, created SDL's hidden 10x10 pixel-format probe window,
         * and stopped there: d3d11.dll and dxgi.dll never loaded at all. FNA3D.dll ships
         * the D3D11 backend (D3D11Driver plus the MOJOSHADER_d3d11* set are present in the
         * shipped binary), so it only needs to be selected.
         *
         * This is a platform policy rather than a per-title override: FNA's GL backend
         * cannot work through this stack for ANY title, while D3D11 routes into DXMT.
         *
         * overwrite=0 on purpose -- D3D11 becomes the iOS default while an explicit
         * developer or user setting still wins. Wine copies this verbatim into the Windows
         * environment (get_initial_environment ignores only NIXPKGS_/QT_/VK_ and the SDL
         * audio+video driver names), and env_ios.c logs an [iOS env] INCLUDED line for it
         * so the next log proves it arrived rather than leaving us to infer it. */
        setenv("FNA3D_FORCE_DRIVER", "D3D11", 0);

        /* ml720: make Mono report unhandled exceptions and assembly-load failures.
         *
         * DIAGNOSTIC — revisit before shipping; this is chatty and costs startup time.
         *
         * Marvel Cosmic Invasion now reaches its own managed catch block (exit code went
         * 0 -> 1 once /gldevice: and -AllowMultiInstance cleared the two early returns in
         * Main), so there IS a real exception -- but the game cannot tell us what it is:
         * NLog's file target never gets written and NBug leaves no artifact, both because
         * the failure happens before logging is usable.
         *
         * Mono itself will say. asm+dll masks also surface a missing or mismatched
         * assembly, which is a common startup failure in a repack and would otherwise look
         * like an opaque managed exception.
         *
         * overwrite=0 so an explicit setting still wins; MONO_ is already in env_ios.c's
         * [iOS env] beacon list, so the next log proves whether these arrived. */
        /* ml733: was "debug"/"asm,dll", which existed to diagnose DLL
         * resolution. That work is finished, and it now emits ~62,000 identical
         * assembly-load lines in a single run -- most of a 100k-line log, plus
         * the I/O cost of writing them, on a title we are trying to time.
         * "warning" keeps genuine failures and drops the chatter. */
        setenv("MONO_LOG_LEVEL", "warning", 0);

        /* 2026-07-05 quiet/release mode: disables the heavyweight
         * diagnostics — the PROF sampler (thread_suspends the game thread
         * ~500x/s), per-present log lines (100+/s at RAW rates), winios
         * poll heartbeat. Counters (present count for the FPS overlay,
         * machexc, srvw) keep ticking; ERR-level and boot logging are
         * untouched. Worth a few %% of frame time and, more importantly,
         * HEAT — thermals are what cap ProMotion at 60. COMMENT THIS OUT
         * for diagnostic/profiling sessions. */
        setenv("MADEIRA_QUIET", "1", 1);

        /* task #34 share/purge-probe experiments CONCLUDED 2026-07-14
         * (remap-sharing dead; pool not purgeable; ml76 wall = mismatched
         * MADV_FREE/MADV_FREE_REUSE pair). Probe machinery stays in
         * ntdll-unix, gated on MADEIRA_SHARE_PROBE — set it here to re-run. */

        /* 2026-07-05 audio: activate the AVAudioSession before Wine boots
         * so the RemoteIO unit in the mmdevapi driver can start. Playback
         * category = ignores silent switch (it's a game). */
        {
            NSError *aerr = nil;
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayback error:&aerr];
            if (aerr) LOG("AVAudioSession setCategory failed: %{public}s",
                          aerr.localizedDescription.UTF8String);
            aerr = nil;
            [session setActive:YES error:&aerr];
            if (aerr) LOG("AVAudioSession setActive failed: %{public}s",
                          aerr.localizedDescription.UTF8String);
            else LOG("AVAudioSession active: rate=%.0f latency=%.1fms",
                     session.sampleRate, session.outputLatency * 1000.0);
        }

        /* 2026-07-04 BISECT RESULT: arm A (this env set, all handler fixes
         * on) booted to menu at 17-18 FPS with the x18-access emulator
         * firing 135K+ times cleanly — handler fixes EXONERATED. The
         * libsystem_malloc death is specific to UNIXCALL-DIRECT. Env
         * removed; next crash run carries an fp-walk backtrace + malloc
         * prologue dump to name the Metal call handing free() a garbage
         * pointer. */

        /* 2026-07-04: MADEIRA_HEAL retried with XLATE-HOOK-REV in place and
         * STILL fatal — same C000001D libplatform (os_unfair_lock abort)
         * seconds after healing the ntdll dispatch-thunk VA at boot. One of
         * the rewritten slots has a consumer doing identity/offset math on
         * the PE VA, which no unwinder fix helps. Blanket healing is dead;
         * the fault-latency attack needs slot-level forensics (which slot
         * is the pure branch-feeder) or a writer-side fix. Healer stays
         * opt-in-off. */

        /* Steam game vars. One title reads SteamAppPath as its asset base path and
         * queries it dozens of times during init, so it must be present before that
         * title starts.
         *
         * KNOWN DEFECT, deliberately left in place for now: this publishes ONE title's
         * identity to EVERY guest, with overwrite=1. A different title that links a Steam
         * wrapper therefore sees the wrong app ID. Removing it outright was tested and is
         * NOT the fix -- it regresses the title that needs the path, and it did not change
         * the behaviour of the title that was mis-identified, so the mismatch is real but
         * was not the failure being chased.
         *
         * The durable design belongs in the title-launch layer: publish nothing by
         * default, take the ID from explicit title metadata or the game's own
         * steam_appid.txt, set SteamAppPath to that game's directory, and give each child
         * its own environment rather than mutating one process-global set shared by every
         * pseudo-process. This path usually launches explorer.exe and cannot know which
         * title the desktop will start later, so a conditional here cannot work. */
        setenv("SteamAppPath", "C:\\Program Files\\Thumper", 1);
        setenv("SteamGameId", "356400", 1);
        setenv("SteamAppId",  "356400", 1);

        /* iOS-Madeira 2026-07-02: publish the TRUE JIT-pool RX->RW offset to
         * xtajit64.dll (its own FEXCore copy reads this via getenv in
         * ProcessInit). Set HERE — beside SteamAppPath, the point where
         * Wine snapshots the environment — so it forwards reliably; setting
         * it in FEXBridge.mm::jit_pool_init was too early and did not reach
         * Wine's GetEnvironmentVariableW. jit_pool_init has already run by
         * now (fex_initialize is a prerequisite for launching the guest),
         * so the offset is available. */
        {
            int64_t jit_off = fex_get_jit_write_offset();
            if (jit_off != 0) {
                char off_str[32];
                snprintf(off_str, sizeof(off_str), "0x%llx", (unsigned long long)jit_off);
                setenv("MADEIRA_JIT_WRITE_OFFSET", off_str, 1);
                LOG("setenv MADEIRA_JIT_WRITE_OFFSET=%{public}s", off_str);
            } else {
                LOG("WARNING: fex_get_jit_write_offset() returned 0 — JIT pool not initialized?");
            }
        }

        /* iOS-Madeira: TSO stays ENABLED (default). The unaligned LDAR/LDAPR/
         * STLR backpatch is now in signal_arm64_ios.c's Mach handler, which
         * replicates FEX's HandleUnalignedAccess (Arm64.cpp:2072) so iOS
         * EXC_BAD_ACCESS faults get the same in-place LDAR→LDR+DMB_LD
         * recovery FEX does for Windows EXCEPTION_DATATYPE_MISALIGNMENT. */

        /* iOS-Madeira: a tiny stub steamclient64.dll is shipped in the game
         * directory (built from /tmp/steamclient_stub/stub.c). It exports
         * just VR_InitInternal (returns NULL) — that's the only function
         * CODEX64.dll imports from steamclient64. The real steamclient64.dll
         * (heavily packed, RWX self-modifying, unwind info v5) was
         * blowing up Wine's loader; the stub lets CODEX bind imports and
         * proceed without OpenVR support. Note: no WINEDLLOVERRIDES needed
         * — we just shipped a different file at the same path. */

        LOG("WINEPREFIX=%{public}s", g_prefix_path);

        // Set up file-based logging for Wine C code
        {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *logPath = [docs stringByAppendingPathComponent:@"madeira-log.txt"];
            wine_log_set_file(logPath.UTF8String);
            /* ml519: start the freeze detector as soon as logging works, so
             * every launch (Thumper as well as Steam) yields a measurement. */
            { extern void winios_freeze_watch_start(void); winios_freeze_watch_start(); }
            LOG("Wine log file: %{public}s", logPath.UTF8String);
            /* Expose the app Documents dir to Wine code (e.g. for fex-jit-dump.bin) */
            setenv("MADEIRA_DOCS_DIR", docs.UTF8String, 1);
        }

        // Steam S0: root CA trust. iOS has no API to enumerate system
        // roots, so crypt32's unix rootstore (crypt32_unixlib_ios.c)
        // reads the bundled Mozilla CA set from this path instead.
        {
            NSString *caPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
            if (caPath) {
                setenv("MADEIRA_CA_BUNDLE", caPath.UTF8String, 1);
                LOG("CA bundle: %{public}s", caPath.UTF8String);
            } else {
                LOG("WARNING: cacert.pem missing from bundle — HTTPS cert verification will fail");
            }
        }

        // Redirect stderr AND stdout to log file so Wine debug output (WINEDEBUG)
        // and the guest program's printf are both captured.
        {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *logPath2 = [docs stringByAppendingPathComponent:@"madeira-log.txt"];
            int logfd = open(logPath2.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (logfd >= 0) {
                dup2(logfd, STDERR_FILENO);
                dup2(logfd, STDOUT_FILENO);
                close(logfd);
            }
        }

        // Pick which exe to run (env var override, default = cube.exe).
        // Set MADEIRA_EXE=hello-x64.exe in env to launch the ARM64EC test path.
        const char *madeira_exe = getenv("MADEIRA_EXE");
        if (!madeira_exe || !*madeira_exe) madeira_exe = "cube.exe";
        // Heuristic: x86_64 guest exes (cube-x64, hello-x64, real games like
        // Thumper) need the arm64ec-windows bundle (ARM64EC hybrid system
        // DLLs that interop with FEX-translated x86_64 code). ARM64-native
        // tests (cube.exe) use the aarch64-windows bundle.
        // MADEIRA_USE_ARM64EC=1 forces the arm64ec path explicitly.
        // Otherwise: detect "x64" in the exe name (cube-x64, fib-x64, etc.)
        // OR a Win32 full path (real game launches typically need ARM64EC).
        const char *force_ec = getenv("MADEIRA_USE_ARM64EC");
        BOOL use_arm64ec = (force_ec && *force_ec == '1') ||
                           (strstr(madeira_exe, "x64") != NULL) ||
                           (strchr(madeira_exe, '\\') != NULL);
        const char *bundle_subdir = use_arm64ec ? "arm64ec-windows" : "aarch64-windows";
        LOG("Target exe: %{public}s (bundle=%{public}s)", madeira_exe, bundle_subdir);
        dprintf(STDERR_FILENO, "[WineProc] Target exe: %s (bundle=%s)\n", madeira_exe, bundle_subdir);

        // Ensure Wine prefix has system32 directory with DLLs from bundle
        {
            NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
            NSString *dllSource = [bundlePath stringByAppendingPathComponent:[NSString stringWithUTF8String:bundle_subdir]];
            NSString *prefix = [NSString stringWithUTF8String:g_prefix_path];
            NSString *sys32Dir = [prefix stringByAppendingPathComponent:@"drive_c/windows/system32"];
            NSFileManager *fm = [NSFileManager defaultManager];

            [fm createDirectoryAtPath:sys32Dir withIntermediateDirectories:YES attributes:nil error:nil];

            NSArray *dlls = [fm contentsOfDirectoryAtPath:dllSource error:nil];
            int linked = 0;
            for (NSString *dll in dlls) {
                NSString *src = [dllSource stringByAppendingPathComponent:dll];
                NSString *dst = [sys32Dir stringByAppendingPathComponent:dll];
                // Remove stale symlinks and re-create (bundle path changes on reinstall)
                [fm removeItemAtPath:dst error:nil];
                if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                    linked++;
            }
            LOG("Symlinked %d DLLs from %{public}s to %{public}s", linked, bundle_subdir, sys32Dir.UTF8String);
            dprintf(STDERR_FILENO, "[WineProc] Symlinked %d DLLs from %s -> sys32\n", linked, bundle_subdir);

            // X3 mixed-mode: also link NON-COLLIDING files from the other
            // bundle arch so cross-arch child exes resolve by Win32 path
            // (e.g. proc-test-x64.exe in an aarch64 desktop session).
            // Canonical DLL names (ntdll.dll, ...) already link to the
            // session's set above and are skipped here; children load their
            // system DLLs arch-correctly via WINEDLLPATH + pe_dir probing.
            {
                const char *other_subdir = use_arm64ec ? "aarch64-windows" : "arm64ec-windows";
                NSString *otherSource = [bundlePath stringByAppendingPathComponent:[NSString stringWithUTF8String:other_subdir]];
                NSArray *others = [fm contentsOfDirectoryAtPath:otherSource error:nil];
                int crossLinked = 0;
                for (NSString *f in others) {
                    NSString *dst = [sys32Dir stringByAppendingPathComponent:f];
                    // fileExistsAtPath FOLLOWS symlinks: YES means the session
                    // (main) pass already linked this name to a resolvable
                    // file — that arch wins, leave it.
                    if ([fm fileExistsAtPath:dst]) continue;
                    // NO means absent OR a stale/dangling symlink left by a
                    // previous install (bundle UUID changed on reinstall).
                    // createSymbolicLink fails with EEXIST on a dangling link
                    // that still occupies the path — which silently left the
                    // -x64 files pointing at a dead bundle, so they vanished
                    // from Wine's dir enumeration. Clear then recreate, like
                    // the main pass does.
                    [fm removeItemAtPath:dst error:nil];
                    NSString *src = [otherSource stringByAppendingPathComponent:f];
                    if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                        crossLinked++;
                }
                dprintf(STDERR_FILENO, "[WineProc] Cross-linked %d non-colliding files from %s -> sys32\n",
                        crossLinked, other_subdir);
            }

            // X3c mixed-mode: full per-arch DLL farms. A cross-arch child's
            // private ntdll retries C:\windows\sysx64 (SysWOW64-style) when a
            // system32 name resolves to the session arch's binary — colliding
            // names (ucrtbase, kernel32, ...) always do. sysaa64 is the
            // mirror for the future inverse case (aarch64 child in an EC
            // session, e.g. rpcss under Steam).
            {
                struct { const char *farm; const char *arch; } farms[] = {
                    { "sysx64",  "arm64ec-windows" },
                    { "sysaa64", "aarch64-windows" },
                };
                for (int i = 0; i < 2; i++) {
                    NSString *farmDir = [prefix stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"drive_c/windows/%s", farms[i].farm]];
                    NSString *archSource = [bundlePath stringByAppendingPathComponent:
                        [NSString stringWithUTF8String:farms[i].arch]];
                    [fm createDirectoryAtPath:farmDir withIntermediateDirectories:YES attributes:nil error:nil];
                    NSArray *files = [fm contentsOfDirectoryAtPath:archSource error:nil];
                    int farmLinked = 0;
                    for (NSString *f in files) {
                        NSString *dst = [farmDir stringByAppendingPathComponent:f];
                        [fm removeItemAtPath:dst error:nil];  // self-heal stale links on reinstall
                        NSString *src = [archSource stringByAppendingPathComponent:f];
                        if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                            farmLinked++;
                    }
                    dprintf(STDERR_FILENO, "[WineProc] Farm %s: %d links -> %s\n",
                            farms[i].farm, farmLinked, farms[i].arch);
                }
            }

            /* ml719: REPAIR THE SHELL FOLDERS. They ship as symlinks to the BUILD
             * MACHINE's home directory.
             *
             * prefix-template.tar.gz contains six absolute links --
             *   drive_c/users/madeira/Documents -> /Users/willfaust/Documents
             * and the same for Desktop, Downloads, Music, Pictures, Videos. That path
             * exists on no device, so every one of them is dangling everywhere the app has
             * ever been installed, including testers' phones. Anything resolving a Windows
             * shell folder silently fails: Marvel Cosmic Invasion's NLog target is
             * ${specialfolder:MyDocuments}/Tribute Games/... which is why no game log was
             * ever produced, and it is a live candidate for why the game exits at startup
             * (a title that cannot write its settings or save directory quitting cleanly is
             * ordinary behaviour).
             *
             * Regenerating the archive is necessary but NOT sufficient: the template is
             * extracted once, so existing prefixes keep the broken links forever. Hence
             * this runtime migration.
             *
             * Deliberately conservative -- lstat so a dangling link is still seen, and only
             * a symlink whose target is absent is touched. A real directory, or a link the
             * user made themselves that resolves, is left completely alone. Ordinary
             * directories rather than container-absolute symlinks: the container UUID
             * changes across reinstalls, so an absolute link would rot the same way. */
            {
                static const char *shell_dirs[] = {
                    "Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos"
                };
                int repaired = 0, already = 0;
                for (int i = 0; i < 6; i++) {
                    NSString *sp = [prefix stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"drive_c/users/madeira/%s", shell_dirs[i]]];
                    const char *cp = sp.fileSystemRepresentation;
                    struct stat lst;
                    if (lstat(cp, &lst) != 0) {          /* nothing there at all */
                        if (mkdir(cp, 0755) == 0) repaired++;
                        continue;
                    }
                    if (!S_ISLNK(lst.st_mode)) { already++; continue; }   /* real dir: leave */
                    struct stat tgt;
                    if (stat(cp, &tgt) == 0) { already++; continue; }     /* link resolves: leave */
                    char buf[1024]; ssize_t n = readlink(cp, buf, sizeof(buf) - 1);
                    if (n > 0) buf[n] = 0; else buf[0] = 0;
                    if (unlink(cp) == 0 && mkdir(cp, 0755) == 0) {
                        repaired++;
                        dprintf(STDERR_FILENO, "[shell-dir] ml719 repaired %s (was dangling -> %s)\n",
                                shell_dirs[i], buf);
                    } else {
                        dprintf(STDERR_FILENO, "[shell-dir] ml719 FAILED to repair %s (was -> %s) errno=%d\n",
                                shell_dirs[i], buf, errno);
                    }
                }
                dprintf(STDERR_FILENO, "[shell-dir] ml719 %d repaired, %d already good\n",
                        repaired, already);
            }

            // Layer Microsoft's real VC++ Runtime DLLs ON TOP of the ARM64EC
            // bundle (only for x86_64 guests). These overwrite Wine's stub
            // builtins — Wine then loads the real MS x86_64 implementation
            // (via FEX) instead of its partial ARM64EC reimplementation.
            //
            // Same pattern Proton/Winlator use: drop in the real concrt140 /
            // msvcp140 / vcruntime140 binaries from VC_redist.x64.exe so games
            // that exercise the full C++ runtime (parallel_for, atomic_wait,
            // <filesystem>, etc.) don't trip __wine_unimplemented stubs.
            if (use_arm64ec) {
                NSString *vcrtSource = [bundlePath stringByAppendingPathComponent:@"x86_64-vcruntime"];
                NSArray *vcrtDlls = [fm contentsOfDirectoryAtPath:vcrtSource error:nil];
                int vcrtLinked = 0, vcrtSkipped = 0;
                for (NSString *dll in vcrtDlls) {
                    /* NOTE 2026-07-03 (late): retried lifting BOTH exemptions
                     * below after the fast-write bisect, hoping trap-mode had
                     * fixed the corruption class (and to keep hot CRT calls
                     * like memcpy inside the JIT — they cost a full x64→EC
                     * round trip as ARM64EC builtins, a large share of the
                     * 57ms menu frame). Result: guest RIP jumped to junk
                     * (0x600000010xx, lr=0xa59696ff...) right after
                     * MSVCP140/VCRUNTIME140 loaded x86_64, before present #1.
                     * So the x86→EC SEH/transition corruption is NOT the
                     * fast-write bug — it's still unfixed, and these
                     * exemptions must stay until it is. */
                    /* Keep vcruntime140.dll as the ARM64EC builtin: its
                     * __C_specific_handler is invoked by Wine's SEH dispatch,
                     * and routing that through FEX corrupts x86 RSP (SEH
                     * dispatcher's exit-thunk arg setup is broken). With the
                     * native arm64ec vcruntime140, Wine calls the handler
                     * directly in ARM64 — no FEX bridging on the exception
                     * path. Other vcruntime/msvcp/concrt DLLs still overlay. */
                    if ([[dll lowercaseString] isEqualToString:@"vcruntime140.dll"]) {
                        vcrtSkipped++;
                        continue;
                    }
                    /* msvcp140.dll: same exemption as vcruntime140, found
                     * 2026-07-03. The MS x86_64 msvcp140 throws a C++
                     * exception during its own DllMain; the x86 throw-record
                     * builder calls RtlPcToFileHeader cross-arch and the
                     * exception-path exit thunk corrupts guest RSP — the
                     * returned module base lands in the return-address slot
                     * and RIP jumps to the MZ header (NoExec loop, no
                     * splash). Keep the ARM64EC builtin so msvcp140's EH
                     * runs natively, like vcruntime140. */
                    if ([[dll lowercaseString] isEqualToString:@"msvcp140.dll"]) {
                        vcrtSkipped++;
                        continue;
                    }
                    NSString *src = [vcrtSource stringByAppendingPathComponent:dll];
                    NSString *dst = [sys32Dir stringByAppendingPathComponent:dll];
                    [fm removeItemAtPath:dst error:nil];
                    if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                        vcrtLinked++;
                }
                LOG("Symlinked %d MS VC++ Runtime DLLs (x86_64 native) over arm64ec builtins, skipped %d", vcrtLinked, vcrtSkipped);
                dprintf(STDERR_FILENO, "[WineProc] Symlinked %d MS VC++ Runtime DLLs over arm64ec builtins (skipped %d for native EC SEH)\n", vcrtLinked, vcrtSkipped);
            }
        }

        // Build the launch path for Wine's PE loader.
        // If MADEIRA_EXE contains a backslash or starts with a drive letter
        // (e.g. "C:\\Program Files\\Thumper\\THUMPER_win10.exe"), use it
        // as-is. Otherwise treat it as a bare exe name in system32 (legacy
        // path used by cube/fib/hello tests).
        char exe_path[512];
        if (strchr(madeira_exe, '\\') || (madeira_exe[0] && madeira_exe[1] == ':')) {
            snprintf(exe_path, sizeof(exe_path), "%s", madeira_exe);
        } else {
            snprintf(exe_path, sizeof(exe_path), "C:\\windows\\system32\\%s", madeira_exe);
        }

        // Optional MADEIRA_ARGS env var: space-separated args appended to argv.
        // Tokenized in-place; max 16 extra tokens.
        static char args_buf[1024];
        char *extra_argv[16] = {0};
        int extra_argc = 0;
        const char *madeira_args = getenv("MADEIRA_ARGS");
        if (madeira_args && *madeira_args) {
            strncpy(args_buf, madeira_args, sizeof(args_buf) - 1);
            args_buf[sizeof(args_buf) - 1] = 0;
            char *saveptr = NULL;
            for (char *tok = strtok_r(args_buf, " ", &saveptr);
                 tok && extra_argc < 16;
                 tok = strtok_r(NULL, " ", &saveptr)) {
                extra_argv[extra_argc++] = tok;
            }
        }

        char *argv[24];
        int argc = 0;
        argv[argc++] = "wine";
        argv[argc++] = exe_path;
        for (int i = 0; i < extra_argc; i++) argv[argc++] = extra_argv[i];
        argv[argc] = NULL;
        dprintf(STDERR_FILENO, "[WineProc] argv[1] = %s\n", exe_path);
        for (int i = 0; i < extra_argc; i++) {
            dprintf(STDERR_FILENO, "[WineProc] argv[%d] = %s\n", 2 + i, extra_argv[i]);
        }

        /* iOS-Madeira: chdir to the unix path that maps to the exe's Wine
         * directory BEFORE __wine_main. Wine inherits the iOS app sandbox
         * cwd, which becomes a `unix\private\var\mobile\...\Documents\wine\`
         * Wine path — and Thumper's relative cache opens (e.g.,
         * "cache/721e72f7.pc") then resolve to doubled paths that don't
         * exist. Per GPT diagnosis 2026-05-12. Only chdir for full-path EXE
         * launches; bare-name launches (cube, hello-x64) use C:\windows\system32. */
        if (strchr(madeira_exe, '\\') || (madeira_exe[0] && madeira_exe[1] == ':')) {
            /* Convert "C:\Program Files\Thumper\X.exe" → unix path */
            char unix_dir[1024];
            const char *drive_c = "drive_c";
            const char *after_drive = madeira_exe + 3; /* skip "C:\" */
            char *last_sep = strrchr(madeira_exe, '\\');
            if (last_sep && last_sep > madeira_exe + 3) {
                /* Get "Program Files\Thumper" from "C:\Program Files\Thumper\X.exe" */
                size_t dir_len = (size_t)(last_sep - after_drive);
                char windir[512];
                memcpy(windir, after_drive, dir_len);
                windir[dir_len] = 0;
                /* Translate backslashes to forward slashes */
                for (char *p = windir; *p; p++) if (*p == '\\') *p = '/';
                snprintf(unix_dir, sizeof(unix_dir), "%s/%s/%s",
                         g_prefix_path, drive_c, windir);
                int rc = chdir(unix_dir);
                setenv("PWD", unix_dir, 1);
                /* Also set the iOS-specific override so env_ios.c's
                 * get_initial_directory bypasses unix_to_nt_file_name (which
                 * fails to resolve drive_c via dosdevices on iOS). */
                char wine_cwd[768];
                /* Strip trailing exe name from madeira_exe to get the dir part */
                {
                    const char *exe = madeira_exe;
                    size_t dir_len = (size_t)(last_sep - exe);
                    if (dir_len < sizeof(wine_cwd) - 2) {
                        memcpy(wine_cwd, exe, dir_len);
                        wine_cwd[dir_len] = '\\';
                        wine_cwd[dir_len + 1] = 0;
                        setenv("MADEIRA_INITIAL_CWD", wine_cwd, 1);
                    }
                }
                dprintf(STDERR_FILENO, "[WineProc] chdir(%s) = %d errno=%d, PWD + MADEIRA_INITIAL_CWD=%s\n",
                        unix_dir, rc, rc ? errno : 0, wine_cwd);
            }
        }

        // Record this thread so wine_ios_exit knows where to longjmp
        wine_ios_main_thread = pthread_self();
        wine_ios_exit_initialized = 1;

        LOG("Calling __wine_main...");

        if (setjmp(wine_ios_exit_jmpbuf) == 0) {
            __wine_main(argc, argv);
            dprintf(STDERR_FILENO, "[WineProc] __wine_main returned normally\n");
        } else {
            dprintf(STDERR_FILENO, "[WineProc] Wine exited with code %d (caught by longjmp)\n", wine_ios_exit_code);
        }

        g_wine_running = 0;

        // Stop wineserver to prevent CPU spin (iOS kills for excessive CPU)
        dprintf(STDERR_FILENO, "[WineProc] stopping wineserver...\n");
        wineserver_stop();

        dprintf(STDERR_FILENO, "[WineProc] Wine process thread finished cleanly\n");

        // Steam S0: this thread's TEB was mirrored into pthread TSD slot
        // 275 (FEX's hardcoded 0x898) which we don't own via
        // pthread_key_create. Returning from a pthread runs foreign key
        // destructors on whatever's in the slot -> objc_release(TEB)
        // crash wedged the app after every net-test run. Clear it, same
        // as ntdll's pthread_exit_wrapper does for Wine worker threads.
        {
            uintptr_t tsd_base;
            __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
            tsd_base &= ~7ULL;
            *(void **)(tsd_base + 275 * 8) = NULL;
        }
    }
    return NULL;
}

int wine_process_start(const char *prefix_path) {
    if (g_wine_running) {
        LOG("Wine process already running");
        return 0;
    }

    if (g_prefix_path) free(g_prefix_path);
    g_prefix_path = strdup(prefix_path);

    LOG("Starting Wine process with prefix: %{public}s", prefix_path);

    g_wine_running = 1;

    // Create socketpair to bypass broken iOS UDS accept()
    // pair[0] = wineserver side (injected as client fd)
    // pair[1] = ntdll side (used as fd_socket)
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == -1) {
        LOG("socketpair failed: %{public}s", strerror(errno));
        g_wine_running = 0;
        return -1;
    }
    LOG("socketpair created: server_fd=%d, client_fd=%d", pair[0], pair[1]);

    // Set env var for ntdll to pick up instead of server_connect()
    // Must use WINESERVERSOCKET — that's what Wine's server_init_process() checks
    char fd_str[16];
    snprintf(fd_str, sizeof(fd_str), "%d", pair[1]);
    setenv("WINESERVERSOCKET", fd_str, 1);

    // Inject wineserver side — the event loop will pick this up
    wineserver_inject_client_fd(pair[0]);

    // Lower priority so Wine init doesn't starve the main thread
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    struct sched_param sched = { .sched_priority = 20 };  // lower than default (31)
    pthread_attr_setschedparam(&attr, &sched);

    int ret = pthread_create(&g_wine_thread, &attr, wine_process_thread, NULL);
    pthread_attr_destroy(&attr);
    if (ret != 0) {
        LOG("Failed to create Wine process thread: %d", ret);
        close(pair[0]);
        close(pair[1]);
        g_wine_running = 0;
        return -1;
    }

    pthread_detach(g_wine_thread);
    LOG("Wine process thread created");
    return 0;
}

int wine_process_is_running(void) {
    return g_wine_running;
}

int madeira_write_continue_flag(void) {
    if (!g_prefix_path) return -1;
    char path[1024];
    snprintf(path, sizeof(path), "%s/drive_c/madeira-continue.flag", g_prefix_path);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        LOG("continue flag write FAILED: %{public}s errno=%d", path, errno);
        return -1;
    }
    close(fd);
    LOG("continue flag written: %{public}s", path);
    return 0;
}
