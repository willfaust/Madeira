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
#include "../../build/madeira_cfg.h"   /* ml1095: one config file */
#include <sys/stat.h>
#include <limits.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

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

/* ---------------------------------------------------------------------------
 * 2026-09-26 -- THE AUDIO SESSION, MADE ROBUST AND MADE VISIBLE.
 *
 * Device report: a tablet is silent while the phone is fine, and the engine
 * census on the tablet proves samples with real signal are being rendered
 * (the bus limiter engages, the RemoteIO IO thread runs). So the silence is
 * downstream of us: the session category, activation, route or volume.
 * A session that is NOT in the Playback category obeys the tablet Silent
 * Mode (a Control Centre toggle there, not a hardware switch) and is muted
 * with no error anywhere -- which is exactly what a failed or overridden
 * setCategory looks like. The previous code logged its results through os_log
 * only, so the exported log could not say which of these it was.
 *
 * So: one function that (a) sets Playback and activates, retrying as
 * mixable if a non-mixable activation is refused, (b) reports category,
 * route, volume and errors into the EXPORTED log (stderr), and (c) is called
 * again whenever the system tells us the session changed under us --
 * interruption ended, route change, media services reset -- and by the audio
 * driver every time it starts the output unit (weak symbol, see
 * build/ntdll-unix/audio_null_ios.c).
 * ------------------------------------------------------------------------- */
void madeira_audio_session_ensure(const char *why)
{
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        BOOL cat_ok, act_ok;

        cat_ok = [session setCategory:AVAudioSessionCategoryPlayback
                                 mode:AVAudioSessionModeDefault
                              options:0
                                error:&err];
        if (!cat_ok)
            dprintf(STDERR_FILENO, "[audio-route] setCategory(Playback) FAILED: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
        err = nil;
        act_ok = [session setActive:YES error:&err];
        if (!act_ok) {
            dprintf(STDERR_FILENO, "[audio-route] setActive FAILED (%ld): %s -- retrying as mixable\n",
                    (long)err.code, err.localizedDescription.UTF8String ?: "?");
            err = nil;
            [session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeDefault
                         options:AVAudioSessionCategoryOptionMixWithOthers
                           error:&err];
            err = nil;
            act_ok = [session setActive:YES error:&err];
            if (!act_ok)
                dprintf(STDERR_FILENO, "[audio-route] setActive (mixable) FAILED (%ld): %s\n",
                        (long)err.code, err.localizedDescription.UTF8String ?: "?");
        }

        NSMutableArray<NSString *> *outs = [NSMutableArray array];
        for (AVAudioSessionPortDescription *port in session.currentRoute.outputs)
            [outs addObject:[NSString stringWithFormat:@"%@(%@)", port.portType, port.portName]];
        NSString *joined = outs.count ? [outs componentsJoinedByString:@", "] : @"none";
        dprintf(STDERR_FILENO,
                "[audio-route] why=%s category=%s options=0x%lx active=%d outputs=<%s> "
                "outputVolume=%.2f sampleRate=%.0f ioBuffer=%.1fms otherAudioPlaying=%d "
                "secondaryHint=%d\n",
                why ? why : "?", session.category.UTF8String,
                (unsigned long)session.categoryOptions, act_ok ? 1 : 0, joined.UTF8String,
                session.outputVolume, session.sampleRate, session.IOBufferDuration * 1000.0,
                session.isOtherAudioPlaying ? 1 : 0,
                session.secondaryAudioShouldBeSilencedHint ? 1 : 0);
        if (session.outputVolume <= 0.001f)
            dprintf(STDERR_FILENO, "[audio-route] NOTE: the system output volume is 0 -- "
                                   "that alone explains silence\n");
    }
}

static void madeira_audio_session_observe(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
            NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
            dprintf(STDERR_FILENO, "[audio-route] interruption %s\n",
                    type == AVAudioSessionInterruptionTypeBegan ? "BEGAN" : "ENDED");
            if (type == AVAudioSessionInterruptionTypeEnded)
                madeira_audio_session_ensure("interruption-ended");
        }];
        [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
            NSUInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
            /* CategoryChange (3) is caused by our own setCategory: re-running
             * ensure() from it would loop. Report it, act on the others. */
            if (reason == AVAudioSessionRouteChangeReasonCategoryChange) {
                AVAudioSession *s2 = [AVAudioSession sharedInstance];
                dprintf(STDERR_FILENO, "[audio-route] category changed -> %s options=0x%lx\n",
                        s2.category.UTF8String, (unsigned long)s2.categoryOptions);
                return;
            }
            char why[48];
            snprintf(why, sizeof(why), "route-change-%lu", (unsigned long)reason);
            madeira_audio_session_ensure(why);
        }];
        [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n __unused) {
            madeira_audio_session_ensure("media-services-reset");
        }];
    });
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

/* 2026-09-27 -- THE PER-USER AppData SKELETON, EVERY LAUNCH, FOR EVERY PROFILE.
 *
 * shell32 answers SHGetKnownFolderPath / SHGetFolderPath for a per-user folder
 * only if the directory EXISTS (unless the caller passes KF_FLAG_CREATE or
 * DONT_VERIFY, and engines generally do not). A managed-runtime engine asks for
 * LocalAppDataLow to place its log and save data; when that fails it carries
 * on with an EMPTY base path, then opens "<Company>\<Product>\output_log.txt"
 * relative to the current directory, gets OBJECT_PATH_NOT_FOUND, hands the
 * NULL stream to the CRT, and the CRT's invalid-parameter handler fast-fails
 * the process (0xC0000409) before the first frame. The one-shot, marker-gated
 * repair above only ever created the skeleton under ONE hard-coded profile
 * name, once; a prefix whose live profile directory has another name (it is
 * derived from the host account name) or that was created later never got it.
 * mkdir -p is idempotent and costs nothing, so do it for every profile
 * directory present, on every launch, and say what was found. */
static void madeira_ensure_appdata(NSString *prefix)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *users = [prefix stringByAppendingPathComponent:@"drive_c/users"];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:users error:nil];
    NSMutableString *report = [NSMutableString string];

    for (NSString *name in names)
    {
        BOOL isDir = NO;
        NSString *home = [users stringByAppendingPathComponent:name];
        if ([name hasPrefix:@"."] || [name caseInsensitiveCompare:@"Public"] == NSOrderedSame) continue;
        if (![fm fileExistsAtPath:home isDirectory:&isDir] || !isDir) continue;

        int made = 0;
        for (NSString *leaf in @[ @"AppData/Roaming", @"AppData/Local", @"AppData/LocalLow",
                                  @"AppData/Local/Temp" ])
        {
            NSString *path = [home stringByAppendingPathComponent:leaf];
            if ([fm fileExistsAtPath:path]) continue;
            if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil])
                made++;
        }
        [report appendFormat:@" %@(+%d)", name, made];
    }
    dprintf(STDERR_FILENO, "[profile] AppData skeleton ensured for:%s\n",
            report.length ? report.UTF8String : " (no profile directories yet)");
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
static int g_wine_running = 0;
static char *g_prefix_path = NULL;

/***********************************************************************
 *           madeira_install_user_fonts
 *
 * "Double-click install" for iOS: anything the user drops into
 * Documents/fonts/ is installed into the prefix's C:\windows\Fonts.
 *
 * That directory is the ONE place a font has to be for Wine to install it:
 * win32u's font_init() -> load_file_system_fonts() scans
 * \??\C:\windows\fonts on every session start and registers every face it
 * finds in the font list and in the HKCU\Software\Wine\Fonts\Cache key —
 * which IS Wine's font cache — so a file copied here behaves exactly like one
 * of the preinstalled faces, for 32-bit and 64-bit guests alike. (The
 * HKLM\...\CurrentVersion\Fonts value only carries fonts that live OUTSIDE
 * that directory; Wine writes it itself, from the face's real name, in
 * update_external_font_keys().)
 *
 * Generic: no font name, no title, no app is special-cased — whatever is in
 * the folder gets installed. Runs before the wineserver starts, every
 * session, so a font added between runs is picked up on the next launch.
 */
static void madeira_install_user_fonts(NSString *prefix)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src = [[prefix stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:@"fonts"];
    NSString *dst = [prefix stringByAppendingPathComponent:@"drive_c/windows/Fonts"];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:src error:nil];
    NSUInteger installed = 0;

    if (!names.count) return;
    [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];

    for (NSString *name in names) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"ttf"] && ![ext isEqualToString:@"otf"] &&
            ![ext isEqualToString:@"ttc"] && ![ext isEqualToString:@"fon"]) continue;
        if ([name hasPrefix:@"."]) continue;

        NSString *from = [src stringByAppendingPathComponent:name];
        NSString *to   = [dst stringByAppendingPathComponent:name];
        NSDictionary *a = [fm attributesOfItemAtPath:from error:nil];
        NSDictionary *b = [fm attributesOfItemAtPath:to error:nil];

        /* already installed and unchanged: leave it alone (size is enough —
         * a replaced font of identical size is indistinguishable to the user
         * and re-copying every launch costs more than it is worth) */
        if (b && [a[NSFileSize] isEqual:b[NSFileSize]]) continue;

        [fm removeItemAtPath:to error:nil];
        if ([fm copyItemAtPath:from toPath:to error:nil]) {
            installed++;
            LOG("[fonts] installed %{public}s", name.UTF8String);
        } else {
            LOG("[fonts] FAILED to install %{public}s", name.UTF8String);
        }
    }
    LOG("[fonts] installed %lu from Documents/fonts", (unsigned long)installed);
}

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
        /* 2026-09-27: every launch -- see madeira_ensure_appdata(). */
        madeira_ensure_appdata( prefix );
        /* Fonts the user dropped into Documents/fonts. Must be in place before
         * the wineserver starts, so win32u's session-start scan of
         * C:\windows\fonts sees them. */
        madeira_install_user_fonts( prefix );
    }
}

/***********************************************************************
 *           madeira_pe_machine
 *
 * WOW64_DESIGN.md stage E: read IMAGE_FILE_HEADER.Machine straight off disk
 * (MZ -> e_lfanew -> "PE\0\0" -> Machine) instead of guessing from the exe
 * name, so an i386 target can be routed to the syswow64 farm generically —
 * this has nothing game-specific about it, it just answers "what machine is
 * this PE". Returns 0 (and touches nothing else) on any read/format failure,
 * which callers treat as "not i386" so behaviour for unreadable/odd inputs
 * never regresses.
 */
static uint16_t madeira_pe_machine(const char *unix_path) {
    if (!unix_path || !*unix_path) return 0;
    FILE *f = fopen(unix_path, "rb");
    if (!f) return 0;

    unsigned char dos[64];
    uint16_t machine = 0;
    if (fread(dos, 1, sizeof(dos), f) == sizeof(dos) && dos[0] == 'M' && dos[1] == 'Z') {
        uint32_t e_lfanew = (uint32_t)dos[0x3c] | ((uint32_t)dos[0x3d] << 8) |
                            ((uint32_t)dos[0x3e] << 16) | ((uint32_t)dos[0x3f] << 24);
        unsigned char pe[6];
        if (e_lfanew <= (16u << 20) &&  /* sanity bound, real headers are tiny */
            fseek(f, (long)e_lfanew, SEEK_SET) == 0 &&
            fread(pe, 1, sizeof(pe), f) == sizeof(pe) &&
            pe[0] == 'P' && pe[1] == 'E' && pe[2] == 0 && pe[3] == 0) {
            machine = (uint16_t)pe[4] | ((uint16_t)pe[5] << 8);
        }
    }
    fclose(f);
    return machine;
}

#define MADEIRA_IMAGE_FILE_MACHINE_I386  0x14c
#define MADEIRA_IMAGE_FILE_MACHINE_AMD64 0x8664
#define MADEIRA_IMAGE_FILE_MACHINE_ARM64 0xaa64

static void wine_process_finished(void *arg) {
    /* Also runs when SIGQUIT makes the main guest thread call pthread_exit. */
    wineserver_finish_session();
    __atomic_store_n(&g_wine_running, 0, __ATOMIC_RELEASE);
    dprintf(STDERR_FILENO, "[session-stop] ml1220 guest session retired\n");
}

static void *wine_process_thread(void *arg) {
    pthread_cleanup_push(wine_process_finished, NULL);
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
                setenv("WINEDEBUG", "err+all,err-virtual", 1);
                LOG("WINEDEBUG = err+all,err-virtual (perf default — set MADEIRA_DEBUG_VERBOSE=1 for full trace)");
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
         * category = ignores the silent switch (this is a game).
         * 2026-09-26: moved into madeira_audio_session_ensure() -- see it. */
        madeira_audio_session_observe();
        madeira_audio_session_ensure("session-start");

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

            /* ml1076: file-backed memory canary (Astra's memory-backing-canary.c,
             * run in-app on the phone, gated by Documents/madeira-swap-canary.txt).
             * Question: do dirty pages of a MAP_SHARED mapping of a private temp file
             * stay OUT of phys_footprint on iOS the way they do on macOS? If yes, a
             * file-backed tier for large guest commits is a real capacity lever. */
            if (madeira_cfg_bool("swap-canary", 0)) {   /* ml1095: madeira.cfg swap-canary = 1 */
                extern void madeira_memory_canary(const char *tmpdir);
                madeira_memory_canary(NSTemporaryDirectory().UTF8String);
            }

            /* ml1077: file-backed guest data tier. Documents/madeira-swap-mb.txt = cap
             * in MB; the sparse backing file lives in tmp with NO file protection so
             * the mapping survives the screen locking. See virtual_ios.c ml1077. */
            {
                long capMB = (long)madeira_cfg_int("swap-mb", 0);   /* ml1095: madeira.cfg swap-mb = N */
                if (capMB >= 64) {
                    NSString *swapPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"madeira-swap.bin"];
                    [[NSFileManager defaultManager] removeItemAtPath:swapPath error:nil];
                    if ([[NSFileManager defaultManager] createFileAtPath:swapPath contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionNone}]) {
                        setenv("MADEIRA_SWAP_FILE", swapPath.UTF8String, 1);
                        setenv("MADEIRA_SWAP_MB", [NSString stringWithFormat:@"%ld", capMB].UTF8String, 1);
                        LOG("ml1077 swap tier armed: %{public}s, %ld MB", swapPath.UTF8String, capMB);
                        fprintf(stderr, "[swap] ml1077 app: backing file %s, cap %ld MB\n", swapPath.UTF8String, capMB);
                    }
                }
            }

            /* ml1062: Documents/madeira-env.txt -- one KEY=VALUE per line, exported
             * before Wine starts. FEX reads its whole configuration from FEX_*
             * environment variables (EnvLoader over the process environment, which
             * Wine builds from ours), so this turns every FEX option -- TSO emulation,
             * multiblock, SMC checks, x87 precision -- into a file edit instead of a
             * rebuild. Lines starting with # are comments. Logged, so a run's log
             * always says what it ran with. */
            {
                /* ml1095: "env.NAME = value" lines of madeira.cfg; the legacy
                 * madeira-env.txt (KEY=VALUE lines) only when madeira.cfg is absent. */
                NSString *text = nil;
                if (madeira_cfg_present()) {
                    NSMutableString *acc = [NSMutableString string];
                    NSString *cfg = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@MADEIRA_CFG_FILE] encoding:NSUTF8StringEncoding error:nil];
                    for (NSString *raw in [cfg componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSRange eq = [line rangeOfString:@"="];
                        if (![line hasPrefix:@"env."] || eq.location == NSNotFound) continue;
                        NSString *k = [[line substringWithRange:NSMakeRange(4, eq.location - 4)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (k.length) [acc appendFormat:@"%@=%@\n", k, v];
                    }
                    text = acc;
                } else {
                    text = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-env.txt"] encoding:NSUTF8StringEncoding error:nil];
                }
                for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSRange eq = [line rangeOfString:@"="];
                    if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound || eq.location == 0) continue;
                    NSString *k = [line substringToIndex:eq.location], *v = [line substringFromIndex:eq.location + 1];
                    setenv(k.UTF8String, v.UTF8String, 1);
                    LOG("madeira.cfg env: %{public}s=%{public}s", k.UTF8String, v.UTF8String);
                    fprintf(stderr, "[madeira-env] ml1062 %s=%s\n", k.UTF8String, v.UTF8String);
                }
            }
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

        /* WOW64_DESIGN.md stage E: read the target's actual PE machine instead
         * of guessing from its name. A bare exe name lives directly in one of
         * the per-arch bundle dirs (same convention the farms below rely on);
         * a full Win32 path lives under the prefix's drive_c. Any lookup or
         * parse failure leaves target_machine at 0, i.e. "unknown", and the
         * name heuristic below is then used exactly as before. */
        BOOL is_full_path_exe = (strchr(madeira_exe, '\\') != NULL) ||
                                (madeira_exe[0] && madeira_exe[1] == ':');
        uint16_t target_machine = 0;
        {
            char probe[1024];
            probe[0] = 0;
            if (is_full_path_exe && strlen(madeira_exe) > 3 && madeira_exe[1] == ':') {
                /* stage C review F10: only skip the "C:\" prefix when there
                 * actually is one — otherwise madeira_exe + 3 reads past the
                 * end of a short name. */
                char windir[1024];
                /* verbatim apart from the separator flip: spaces, apostrophes
                 * and anything else in the path are copied as-is, and fopen()
                 * below takes the bytes with no shell in between */
                if (snprintf(windir, sizeof(windir), "%s", madeira_exe + 3) >= (int)sizeof(windir))
                    dprintf(STDERR_FILENO, "[WineProc] WARNING: exe path truncated in the PE-machine probe; "
                                           "a 32-bit target may be misdetected as 64-bit\n");
                for (char *p = windir; *p; p++) if (*p == '\\') *p = '/';
                if (snprintf(probe, sizeof(probe), "%s/drive_c/%s", g_prefix_path, windir) >= (int)sizeof(probe))
                    dprintf(STDERR_FILENO, "[WineProc] WARNING: probe path truncated; "
                                           "a 32-bit target may be misdetected as 64-bit\n");
            } else {
                /* A BARE NAME is resolved by the launch below as
                 * C:\windows\system32\<name>, which is symlinked from the
                 * 64-bit farm — so a name that exists in a 64-bit farm is NOT
                 * a 32-bit target, whatever i386-windows also happens to hold.
                 *
                 * This test is load-bearing now that the full i386 Wine set
                 * ships: i386-windows carries explorer.exe, cmd.exe, start.exe,
                 * notepad.exe, regedit.exe and friends under exactly the same
                 * names as the 64-bit farms. Probing i386-windows first would
                 * make the virtual-desktop launch (MADEIRA_EXE=explorer.exe)
                 * look like a 32-bit MAIN image, reserve a guest window for the
                 * whole session and route the exe at C:\windows\syswow64. To
                 * launch a 32-bit build of a colliding name on purpose, give its
                 * full path (C:\windows\syswow64\<name>) — the drive_c branch
                 * above reads that file's own header and needs no name rules. */
                NSString *bundlePathForProbe = [[NSBundle mainBundle] bundlePath];
                static const char * const farms64[] = { "aarch64-windows", "arm64ec-windows" };
                int in_64bit_farm = 0;
                for (size_t f = 0; f < sizeof(farms64) / sizeof(farms64[0]) && !in_64bit_farm; f++) {
                    char cand[1024];
                    snprintf(cand, sizeof(cand), "%s/%s/%s",
                             bundlePathForProbe.UTF8String, farms64[f], madeira_exe);
                    if (access(cand, R_OK) == 0) in_64bit_farm = 1;
                }
                if (in_64bit_farm) {
                    dprintf(STDERR_FILENO, "[WineProc] PE probe: bare name '%s' exists in a 64-bit farm — "
                                           "not probing i386-windows for it\n", madeira_exe);
                } else {
                    snprintf(probe, sizeof(probe), "%s/i386-windows/%s",
                             bundlePathForProbe.UTF8String, madeira_exe);
                    if (access(probe, R_OK) != 0) probe[0] = 0;
                }
            }
            if (probe[0]) target_machine = madeira_pe_machine(probe);
            /* Name the file that was (or was not) read. A typed path that does
             * not exist, or one under a folder the probe resolved differently,
             * otherwise shows up only as a target silently treated as 64-bit. */
            dprintf(STDERR_FILENO, "[WineProc] PE probe: '%s' -> machine=0x%x%s\n",
                    probe[0] ? probe : "(no probe path)", target_machine,
                    probe[0] && !target_machine ? "  (unreadable or not a PE)" : "");
        }
        BOOL is_i386_target = (target_machine == MADEIRA_IMAGE_FILE_MACHINE_I386);
        if (target_machine) {
            LOG("Target exe PE machine=0x%x (%{public}s)", target_machine,
                is_i386_target ? "i386" : "not i386");
            dprintf(STDERR_FILENO, "[WineProc] Target exe PE machine=0x%x (%s)\n",
                    target_machine, is_i386_target ? "i386" : "not i386");
        }

        /* Which 64-bit system-DLL farm this session's own Wine core runs on.
         * x86_64 guests need arm64ec-windows (ARM64EC hybrid DLLs that interop
         * with FEX-translated x86_64 code); everything else runs on plain
         * aarch64-windows. MADEIRA_USE_ARM64EC=1 forces it.
         *
         * Decided from the PROBED machine when the probe succeeded. The old
         * rule was "the name contains x64, or the path contains a backslash",
         * and that second clause is wrong for a 32-bit target given by full
         * path: a WoW64 process's 64-bit half is plain aarch64 (get_pe_dir()
         * resolves /aarch64-windows because the main image is i386, so
         * is_arm64ec() is false), yet the farm would have been populated with
         * ARM64EC builds. Bare-name inputs do not resolve in the probe, so they
         * fall back to the name heuristic and keep their existing behaviour;
         * an x86_64 full-path target probes 0x8664 and keeps arm64ec too. */
        BOOL use_arm64ec;
        if (force_ec && *force_ec == '1')
            use_arm64ec = YES;
        else if (target_machine == MADEIRA_IMAGE_FILE_MACHINE_AMD64)
            use_arm64ec = YES;
        else if (target_machine == MADEIRA_IMAGE_FILE_MACHINE_I386 ||
                 target_machine == MADEIRA_IMAGE_FILE_MACHINE_ARM64)
            use_arm64ec = NO;
        else
            use_arm64ec = (strstr(madeira_exe, "x64") != NULL) || is_full_path_exe;
        const char *bundle_subdir = use_arm64ec ? "arm64ec-windows" : "aarch64-windows";
        LOG("Target exe: %{public}s (bundle=%{public}s)", madeira_exe, bundle_subdir);
        dprintf(STDERR_FILENO, "[WineProc] Target exe: %s (bundle=%s, probed machine=0x%x)\n",
                madeira_exe, bundle_subdir, target_machine);

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
            // session, e.g. rpcss under Steam). syswow64 (WOW64_DESIGN.md
            // stage E) is the REAL Windows farm name for this pattern: it is
            // where a 32-bit ntdll.dll/kernel32.dll/kernelbase.dll and a
            // bare-name i386 test exe live, and where the unix ntdll's
            // machine->dir mapping (loader_ios.c) expects to find them.
            {
                struct { const char *farm; const char *arch; } farms[] = {
                    { "sysx64",   "arm64ec-windows" },
                    { "sysaa64",  "aarch64-windows" },
                    { "syswow64", "i386-windows" },
                };
                /* stage C review F11: derive the bound from the array so
                 * adding a farm cannot silently skip it. */
                for (size_t i = 0; i < sizeof(farms) / sizeof(farms[0]); i++) {
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

                    /* system32\wbem — the one SUBDIRECTORY of the farm.
                     *
                     * The bundle farms are flat, but WMI's registered
                     * InprocServer32 paths are C:\windows\system32\wbem\<name>
                     * (they are in the shipped registry, and wine.inf installs
                     * these five modules there: "11,wbem,mofcomp.exe" etc).
                     * A flat link leaves system32\wbem EMPTY, so
                     * CoCreateInstance(CLSID_WbemLocator) fails with
                     * c0000135 / "no class object" — which is what two
                     * different 32-bit programs hit in the device logs, both
                     * through dxdiagn asking WMI about the display adapter.
                     * The list is wine.inf's, not any program's. */
                    {
                        static const char *wbem[] = { "wbemprox.dll", "wbemdisp.dll",
                                                      "wmiutils.dll", "wmic.exe",
                                                      "mofcomp.exe" };
                        NSString *wbemDir = [farmDir stringByAppendingPathComponent:@"wbem"];
                        int wbemLinked = 0;
                        [fm createDirectoryAtPath:wbemDir withIntermediateDirectories:YES
                                       attributes:nil error:nil];
                        for (size_t w = 0; w < sizeof(wbem) / sizeof(wbem[0]); w++) {
                            NSString *n = [NSString stringWithUTF8String:wbem[w]];
                            NSString *src = [archSource stringByAppendingPathComponent:n];
                            NSString *dst = [wbemDir stringByAppendingPathComponent:n];
                            [fm removeItemAtPath:dst error:nil];
                            if (![fm fileExistsAtPath:src]) continue;  /* farm doesn't build it */
                            if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                                wbemLinked++;
                        }
                        dprintf(STDERR_FILENO, "[WineProc] Farm %s\\wbem: %d/%zu links -> %s\n",
                                farms[i].farm, wbemLinked,
                                sizeof(wbem) / sizeof(wbem[0]), farms[i].arch);
                    }
                }

                /* the same subdirectory for the session's own system32 (the
                 * flat pass above linked the session arch into system32, but
                 * never its wbem subdir) */
                {
                    static const char *wbem[] = { "wbemprox.dll", "wbemdisp.dll",
                                                  "wmiutils.dll", "wmic.exe", "mofcomp.exe" };
                    NSString *wbemDir = [sys32Dir stringByAppendingPathComponent:@"wbem"];
                    int wbemLinked = 0;
                    [fm createDirectoryAtPath:wbemDir withIntermediateDirectories:YES
                                   attributes:nil error:nil];
                    for (size_t w = 0; w < sizeof(wbem) / sizeof(wbem[0]); w++) {
                        NSString *n = [NSString stringWithUTF8String:wbem[w]];
                        NSString *src = [dllSource stringByAppendingPathComponent:n];
                        NSString *dst = [wbemDir stringByAppendingPathComponent:n];
                        [fm removeItemAtPath:dst error:nil];
                        if (![fm fileExistsAtPath:src]) continue;
                        if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                            wbemLinked++;
                    }
                    dprintf(STDERR_FILENO, "[WineProc] system32\\wbem: %d/%zu links -> %s\n",
                            wbemLinked, sizeof(wbem) / sizeof(wbem[0]), bundle_subdir);
                }
            }

            /* C:\windows\winsxs — THE SIDE-BY-SIDE ASSEMBLY STORE.
             *
             * DEVICE EVIDENCE, every 32-bit run and the desktop alike:
             *   fixme:actctx:parse_depend_manifests Could not find dependent
             *       assembly "Microsoft.Windows.Common-Controls" (6.0.0.0)
             *   err:commdlg:DllMain failed to create activation context ...
             *       14001
             * because the prefix has no winsxs directory AT ALL, so no program
             * in it can ever get a v6 common-controls activation context.
             * Non-fatal in Wine, but it is a permanent, prefix-wide gap: comdlg32
             * gives up on its activation context in DllMain, and every app
             * manifest that asks for Common-Controls 6.0.0.0 — which is nearly
             * all of them — takes the v5 path forever.
             *
             * WHY IT IS MISSING: the store is not in the shipped template
             * (scripts/build-prefix-snapshot.sh deletes drive_c/windows/winsxs
             * before tarring), and nothing recreates it here because this port
             * never runs wineboot's fake-DLL install — which is what builds it
             * on a normal Wine prefix.
             *
             * WHAT WINE ACTUALLY WRITES, reproduced here exactly
             * (dlls/setupapi/fakedll.c register_manifest/append_manifest_filename/
             *  create_manifest/create_winsxs_dll_path):
             *   windows\winsxs\manifests\<DIR>.manifest
             *   windows\winsxs\<DIR>\comctl32.dll        (= comctl32_v6.dll)
             * with
             *   <DIR> = <arch>_microsoft.windows.common-controls_
             *           6595b64144ccf1df_6.0.2600.2982_none_deadbeef
             * — lower case, publicKeyToken and version verbatim, and the literal
             * "deadbeef" where Microsoft puts a content hash (fakedll.c writes
             * that constant; ntdll's actctx.c lookup_manifest_file recognises it
             * and prefers a non-Wine assembly if one is ever present).
             * The manifest BYTES are dlls/comctl32_v6/comctl32.manifest with the
             * empty processorArchitecture="" filled in with the architecture —
             * fakedll.c does that substitution at install time, and actctx.c
             * validates the identity inside the file against the one parsed out
             * of the file NAME, so the two must agree.
             *
             * ntdll searches, for a dependency on 6.0.0.0 (actctx.c
             * build_manifest_filter/lookup_winsxs):
             *   windows\winsxs\manifests\
             *     <arch>_Microsoft.Windows.Common-Controls_6595b64144ccf1df_6.0.*.*_*_*.manifest
             * with <arch> = "x86" for a 32-bit process and "arm64" for both
             * aarch64 AND arm64ec (actctx.c current_archW). "amd64" is seeded
             * too because an arm64ec setupapi would have installed it under that
             * name (fakedll.c has no __arm64ec__ case and falls into __x86_64__),
             * and lookup_manifest_file's __arm64ec__ branch rewrites an explicit
             * "amd64_" request to the wildcard "a??64_", which matches either.
             *
             * ONLY WHEN THE DLL IS THERE. A manifest without
             * winsxs\<DIR>\comctl32.dll would make ntdll's find_actctx_dll
             * redirect every comctl32.dll load for that assembly into a
             * directory that has none — strictly worse than no manifest. So an
             * architecture whose farm has no comctl32_v6.dll is skipped, loudly.
             *
             * ------------------------------------------------------------------
             * ml760: THE SAME GAP, FOR THE VISUAL C++ RUNTIMES.
             *
             * DEVICE EVIDENCE, a 32-bit title in the last log:
             *   err:actctx:parse_depend_manifests Could not find dependent
             *       assembly "Microsoft.VC80.CRT" (8.0.50727.762)
             * This one is NOT cosmetic. A program built with Visual Studio 2005
             * or 2008 carries its CRT as a side-by-side dependency in its own
             * RT_MANIFEST and imports MSVCR80.dll/MSVCP80.dll by name. With no
             * VC80.CRT assembly in the store the activation context fails, the
             * loader falls back to a plain system32 search, and — crucially —
             * every DLL the program loads later that has the SAME dependency
             * gets the same failure. Wine ships the runtimes and the assembly
             * manifests; it is only the store that was never built here.
             *
             * Wine's assembly manifests are the ten WINE_MANIFEST resources in
             * the tree (grep -rn WINE_MANIFEST wine/dlls --include=*.rc):
             *   comctl32_v6  Microsoft.Windows.Common-Controls 6.0.2600.2982
             *   msvcr80      Microsoft.VC80.CRT   8.0.50727.9672
             *                 (msvcr80.dll, msvcp80.dll, msvcm80.dll)
             *   msvcr90      Microsoft.VC90.CRT   9.0.30729.6161
             *                 (msvcr90.dll, msvcp90.dll, msvcm90.dll)
             *   atl80        Microsoft.VC80.ATL   8.0.50727.4053
             *   atl90        Microsoft.VC90.ATL   9.0.30729.6161
             *   gdiplus      Microsoft.Windows.GdiPlus 1.0.6000.16386
             *                 and 1.1.7601.23038 (WINE_MANIFEST11, same DLL)
             *   msxml3       Microsoft-Windows-MSXML30 6.0.6000.16386
             *   msxml4       Microsoft.MSXML2          4.1.0.0
             *   msxml6       Microsoft-Windows-MSXML60 6.0.6000.16386
             *
             * A REQUEST FOR AN OLDER BUILD STILL MATCHES. actctx.c
             * build_manifest_filter only pins major.minor —
             *   <arch>_<name>_<key>_<major>.<minor>.*.*_*_*.manifest
             * — and lookup_manifest_file then accepts any candidate whose
             * build/revision is >= the requested one. So the 8.0.50727.762 the
             * title asked for is served by the 8.0.50727.9672 Wine ships, and
             * one seeded assembly per major.minor covers every service pack of
             * it. That is why these are worth seeding blind: the version a
             * given program asks for cannot be enumerated in advance, and it
             * does not have to be.
             *
             * NOT SEEDED, and why:
             *   Microsoft.VC100.* / VC110+ — VS2010 stopped deploying the CRT
             *     side-by-side; msvcr100 and later install into system32 and
             *     Wine ships no manifest for them. Nothing to seed.
             *   Microsoft.VC80.MFC / VC90.MFC — Wine has no mfc* module at all
             *     (there is no wine/dlls/mfc*), so the assembly would point at
             *     a DLL that does not exist. See the farm audit.
             */
            {
                /* One entry per WINE_MANIFEST assembly in the Wine tree.
                 *
                 *   name     assemblyIdentity name, verbatim (it is written
                 *            into the manifest and actctx.c compares it
                 *            case-insensitively against the parsed file name)
                 *   lname    the same, lower-cased: fakedll.c append_string()
                 *            lower-cases arch/name/language when it builds the
                 *            directory name, but copies publicKeyToken and
                 *            version through verbatim
                 *   files    <file name="..."> entries, in manifest order, each
                 *            paired with the farm file it is linked from. The
                 *            FIRST one is the assembly's reason to exist: if it
                 *            is missing from a farm the whole assembly is
                 *            skipped for that architecture. A later one that is
                 *            missing is dropped from BOTH the directory and the
                 *            manifest text, so the manifest never advertises a
                 *            file that is not there.
                 *   body     extra XML inside <file>…</file>; NULL means the
                 *            self-closing <file name="x"/> form Wine uses for
                 *            everything except comctl32.
                 */
                struct sxs_file { const char *in_assembly; const char *in_farm; };
                struct sxs_assembly {
                    const char *name, *lname, *key, *version, *body;
                    struct sxs_file files[4];
                };
                static const char *comctl32_body =
                    "    <windowClass>Button</windowClass>\n"
                    "    <windowClass>ButtonListBox</windowClass>\n"
                    "    <windowClass>ComboBoxEx32</windowClass>\n"
                    "    <windowClass>ComboLBox</windowClass>\n"
                    "    <windowClass>ComboBox</windowClass>\n"
                    "    <windowClass>Edit</windowClass>\n"
                    "    <windowClass>ListBox</windowClass>\n"
                    "    <windowClass>NativeFontCtl</windowClass>\n"
                    "    <windowClass>ReBarWindow32</windowClass>\n"
                    "    <windowClass>ScrollBar</windowClass>\n"
                    "    <windowClass>Static</windowClass>\n"
                    "    <windowClass>SysAnimate32</windowClass>\n"
                    "    <windowClass>SysDateTimePick32</windowClass>\n"
                    "    <windowClass>SysHeader32</windowClass>\n"
                    "    <windowClass>SysIPAddress32</windowClass>\n"
                    "    <windowClass>SysLink</windowClass>\n"
                    "    <windowClass>SysListView32</windowClass>\n"
                    "    <windowClass>SysMonthCal32</windowClass>\n"
                    "    <windowClass>SysPager</windowClass>\n"
                    "    <windowClass>SysTabControl32</windowClass>\n"
                    "    <windowClass>SysTreeView32</windowClass>\n"
                    "    <windowClass>ToolbarWindow32</windowClass>\n"
                    "    <windowClass>msctls_hotkey32</windowClass>\n"
                    "    <windowClass>msctls_progress32</windowClass>\n"
                    "    <windowClass>msctls_statusbar32</windowClass>\n"
                    "    <windowClass>msctls_trackbar32</windowClass>\n"
                    "    <windowClass>msctls_updown32</windowClass>\n"
                    "    <windowClass>tooltips_class32</windowClass>\n";
                static const struct sxs_assembly asms[] = {
                    /* dlls/comctl32_v6/comctl32.manifest */
                    { "Microsoft.Windows.Common-Controls", "microsoft.windows.common-controls",
                      "6595b64144ccf1df", "6.0.2600.2982", NULL /*set below*/,
                      { { "comctl32.dll", "comctl32_v6.dll" } } },
                    /* dlls/msvcr80/msvcr80.manifest */
                    { "Microsoft.VC80.CRT", "microsoft.vc80.crt",
                      "1fc8b3b9a1e18e3b", "8.0.50727.9672", NULL,
                      { { "msvcr80.dll", "msvcr80.dll" },
                        { "msvcp80.dll", "msvcp80.dll" },
                        { "msvcm80.dll", "msvcm80.dll" } } },
                    /* dlls/msvcr90/msvcr90.manifest */
                    { "Microsoft.VC90.CRT", "microsoft.vc90.crt",
                      "1fc8b3b9a1e18e3b", "9.0.30729.6161", NULL,
                      { { "msvcr90.dll", "msvcr90.dll" },
                        { "msvcp90.dll", "msvcp90.dll" },
                        { "msvcm90.dll", "msvcm90.dll" } } },
                    /* dlls/atl80/atl80.manifest */
                    { "Microsoft.VC80.ATL", "microsoft.vc80.atl",
                      "1fc8b3b9a1e18e3b", "8.0.50727.4053", NULL,
                      { { "atl80.dll", "atl80.dll" } } },
                    /* dlls/atl90/atl90.manifest */
                    { "Microsoft.VC90.ATL", "microsoft.vc90.atl",
                      "1fc8b3b9a1e18e3b", "9.0.30729.6161", NULL,
                      { { "atl90.dll", "atl90.dll" } } },
                    /* dlls/gdiplus/gdiplus.manifest and gdiplus11.manifest:
                     * two assemblies, one DLL. */
                    { "Microsoft.Windows.GdiPlus", "microsoft.windows.gdiplus",
                      "6595b64144ccf1df", "1.0.6000.16386", NULL,
                      { { "gdiplus.dll", "gdiplus.dll" } } },
                    { "Microsoft.Windows.GdiPlus", "microsoft.windows.gdiplus",
                      "6595b64144ccf1df", "1.1.7601.23038", NULL,
                      { { "gdiplus.dll", "gdiplus.dll" } } },
                    /* dlls/msxml3, msxml4 and msxml6 manifests */
                    { "Microsoft-Windows-MSXML30", "microsoft-windows-msxml30",
                      "31bf3856ad364e35", "6.0.6000.16386", NULL,
                      { { "msxml3.dll", "msxml3.dll" } } },
                    { "Microsoft.MSXML2", "microsoft.msxml2",
                      "6bd6b9abf345378f", "4.1.0.0", NULL,
                      { { "msxml4.dll", "msxml4.dll" } } },
                    { "Microsoft-Windows-MSXML60", "microsoft-windows-msxml60",
                      "31bf3856ad364e35", "6.0.6000.16386", NULL,
                      { { "msxml6.dll", "msxml6.dll" } } },
                };
                static const struct { const char *arch; const char *farm; } sxs[] = {
                    { "x86",   "i386-windows"    },   /* every 32-bit process */
                    { "arm64", "aarch64-windows" },   /* aarch64 AND arm64ec sessions */
                    { "amd64", "arm64ec-windows" },   /* what an arm64ec setupapi installs */
                };
                NSString *winsxsDir = [prefix stringByAppendingPathComponent:@"drive_c/windows/winsxs"];
                NSString *manifestsDir = [winsxsDir stringByAppendingPathComponent:@"manifests"];
                int sxsSeeded = 0, sxsSkipped = 0;
                size_t sxsWanted = (sizeof(asms) / sizeof(asms[0])) * (sizeof(sxs) / sizeof(sxs[0]));

                [fm createDirectoryAtPath:manifestsDir withIntermediateDirectories:YES
                               attributes:nil error:nil];
                for (size_t s = 0; s < sizeof(sxs) / sizeof(sxs[0]); s++) {
                    NSString *arch = [NSString stringWithUTF8String:sxs[s].arch];
                    NSString *archSource = [bundlePath stringByAppendingPathComponent:
                        [NSString stringWithUTF8String:sxs[s].farm]];
                    for (size_t a = 0; a < sizeof(asms) / sizeof(asms[0]); a++) {
                        const struct sxs_assembly *asmdef = &asms[a];
                        const char *body = asmdef->body;
                        /* the comctl32 window-class list, attached by index so
                         * the table itself stays a plain initialiser */
                        if (a == 0) body = comctl32_body;

                        NSString *first = [archSource stringByAppendingPathComponent:
                            [NSString stringWithUTF8String:asmdef->files[0].in_farm]];
                        if (![fm fileExistsAtPath:first]) {
                            dprintf(STDERR_FILENO,
                                    "[WineProc] winsxs: %s/%s SKIPPED -- %s has no %s, and a manifest "
                                    "without the assembly's DLL would redirect that DLL's loads into "
                                    "an empty directory (the i386 farm is built by "
                                    "build/wine-i386/build.sh)\n",
                                    sxs[s].arch, asmdef->name, sxs[s].farm, asmdef->files[0].in_farm);
                            sxsSkipped++;
                            continue;
                        }
                        NSString *dir = [NSString stringWithFormat:@"%@_%s_%s_%s_none_deadbeef",
                            arch, asmdef->lname, asmdef->key, asmdef->version];
                        NSString *asmDir = [winsxsDir stringByAppendingPathComponent:dir];
                        NSString *manifest = [manifestsDir stringByAppendingPathComponent:
                            [dir stringByAppendingString:@".manifest"]];

                        [fm createDirectoryAtPath:asmDir withIntermediateDirectories:YES
                                       attributes:nil error:nil];

                        /* Build the manifest and the directory together, so the
                         * <file> list and the directory contents cannot drift.
                         * LF only, no BOM: actctx.c assumes UTF-8 when there is
                         * no UTF-16 BOM. The architecture is spliced into the
                         * source manifest's empty processorArchitecture="",
                         * exactly as fakedll.c does at install time — actctx.c
                         * validates the identity inside the file against the one
                         * parsed out of the file NAME, so the two must agree. */
                        NSMutableString *text = [NSMutableString stringWithString:
                            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                            @"<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\n"];
                        [text appendFormat:
                            @"  <assemblyIdentity type=\"win32\" name=\"%s\" version=\"%s\" "
                            @"processorArchitecture=\"%@\" publicKeyToken=\"%s\"/>\n",
                            asmdef->name, asmdef->version, arch, asmdef->key];

                        BOOL ok = YES;
                        for (size_t f = 0; f < sizeof(asmdef->files) / sizeof(asmdef->files[0]); f++) {
                            if (!asmdef->files[f].in_assembly) break;
                            NSString *src = [archSource stringByAppendingPathComponent:
                                [NSString stringWithUTF8String:asmdef->files[f].in_farm]];
                            NSString *link = [asmDir stringByAppendingPathComponent:
                                [NSString stringWithUTF8String:asmdef->files[f].in_assembly]];
                            [fm removeItemAtPath:link error:nil];  /* the bundle path changes on reinstall */
                            if (![fm fileExistsAtPath:src]) continue;
                            if (![fm createSymbolicLinkAtPath:link withDestinationPath:src error:nil]) {
                                dprintf(STDERR_FILENO, "[WineProc] winsxs: FAILED to link %s\n",
                                        link.UTF8String);
                                ok = NO;
                                break;
                            }
                            if (body)
                                [text appendFormat:@"  <file name=\"%s\">\n%s  </file>\n",
                                    asmdef->files[f].in_assembly, body];
                            else
                                [text appendFormat:@"  <file name=\"%s\"/>\n",
                                    asmdef->files[f].in_assembly];
                        }
                        [text appendString:@"</assembly>\n"];
                        if (!ok) { sxsSkipped++; continue; }

                        if (![[text dataUsingEncoding:NSUTF8StringEncoding]
                                writeToFile:manifest atomically:YES]) {
                            dprintf(STDERR_FILENO, "[WineProc] winsxs: FAILED to write %s\n",
                                    manifest.UTF8String);
                            sxsSkipped++;
                            continue;
                        }
                        sxsSeeded++;
                    }
                }
                dprintf(STDERR_FILENO,
                        "[WineProc] winsxs: %d/%zu assemblies seeded, %d skipped "
                        "(Common-Controls 6.0, VC80/VC90 CRT+ATL, GdiPlus 1.0/1.1, MSXML 3/4/6 "
                        "x x86/arm64/amd64) -> %s\n",
                        sxsSeeded, sxsWanted, sxsSkipped, winsxsDir.UTF8String);
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
        // path used by cube/fib/hello tests) — or in syswow64 for an i386
        // target (WOW64_DESIGN.md stage E), matching where the syswow64 farm
        // above just symlinked it from i386-windows/.
        /* 1024, not 512: a typed Win32 path can be long, and a SILENT truncation
         * here turns into "file not found" far away from its cause. */
        char exe_path[1024];
        if (is_full_path_exe) {
            if (strlen(madeira_exe) >= sizeof(exe_path))
                dprintf(STDERR_FILENO, "[WineProc] ERROR: MADEIRA_EXE is %zu bytes, longer than the %zu-byte "
                                       "launch path buffer — it will be truncated and will not be found\n",
                        strlen(madeira_exe), sizeof(exe_path));
            snprintf(exe_path, sizeof(exe_path), "%s", madeira_exe);
        } else if (is_i386_target) {
            snprintf(exe_path, sizeof(exe_path), "C:\\windows\\syswow64\\%s", madeira_exe);
        } else {
            snprintf(exe_path, sizeof(exe_path), "C:\\windows\\system32\\%s", madeira_exe);
        }

        // Optional MADEIRA_ARGS env var: args appended to argv, max 64 tokens
        // (ml1500: was 16, too few for a launcher plus its lightweight-mode flags).
        //
        // Tokenized in place, honouring DOUBLE QUOTES. The old split was a plain
        // strtok_r on " ", so an argument containing a space (any Windows path —
        // "C:\Some Folder\data.pak") was silently torn into two argv entries and
        // the program received nonsense. Quotes group; the quote characters
        // themselves are removed, exactly as a Win32 command line would be
        // parsed, and Wine's build_command_line re-quotes on the way out so the
        // guest sees the argument whole again. Apostrophes are ordinary
        // characters here and in the shell-free path below — nothing strips or
        // escapes them.
        static char args_buf[4096];
        char *extra_argv[64] = {0};
        int extra_argc = 0;
        const char *madeira_args = getenv("MADEIRA_ARGS");
        if (madeira_args && *madeira_args) {
            if (strlen(madeira_args) >= sizeof(args_buf))
                dprintf(STDERR_FILENO, "[WineProc] WARNING: MADEIRA_ARGS is %zu bytes, truncating to %zu\n",
                        strlen(madeira_args), sizeof(args_buf) - 1);
            strncpy(args_buf, madeira_args, sizeof(args_buf) - 1);
            args_buf[sizeof(args_buf) - 1] = 0;

            char *src = args_buf;      /* read cursor */
            char *dst = args_buf;      /* write cursor: always <= src, so in place */
            while (*src && extra_argc < 64) {
                while (*src == ' ' || *src == '\t') src++;
                if (!*src) break;
                extra_argv[extra_argc++] = dst;
                int in_quotes = 0;
                while (*src && (in_quotes || (*src != ' ' && *src != '\t'))) {
                    if (*src == '"') { in_quotes = !in_quotes; src++; continue; }
                    *dst++ = *src++;
                }
                /* dst can still EQUAL src here (a token with no quotes in it),
                 * so the separator has to be read before the terminator is
                 * written over it. */
                int had_separator = (*src != 0);
                *dst++ = 0;
                if (had_separator) src++;
            }
            if (*src)
                dprintf(STDERR_FILENO, "[WineProc] WARNING: MADEIRA_ARGS has more than 64 tokens, "
                                       "the rest are dropped: %s\n", src);
        }

        char *argv[72];
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
        if (is_full_path_exe) {
            /* Convert "C:\Some Folder\It's Here\Binaries\app.exe" → unix path.
             *
             * Byte-for-byte: only '\\' becomes '/'. Spaces, apostrophes and
             * every other character are copied verbatim, and nothing here goes
             * through a shell — chdir()/setenv() take the bytes directly — so
             * no quoting or escaping is involved at any step.
             *
             * Guarded like the PE-machine probe above (stage C review F10): the
             * "C:\\" prefix is only skipped when there really is a drive letter,
             * so a relative "\\dir\\app.exe" no longer reads three bytes in from
             * an arbitrary offset. */
            char unix_dir[1024];
            char wine_cwd[1024];
            const char *drive_c = "drive_c";
            int has_drive = (madeira_exe[0] && madeira_exe[1] == ':' && madeira_exe[2] == '\\');
            const char *after_drive = has_drive ? madeira_exe + 3 : madeira_exe;
            char *last_sep = strrchr(madeira_exe, '\\');

            unix_dir[0] = 0;
            wine_cwd[0] = 0;
            if (last_sep && last_sep > after_drive) {
                /* Get "Some Folder\It's Here\Binaries" from the full path */
                size_t dir_len = (size_t)(last_sep - after_drive);
                char windir[1024];

                if (dir_len >= sizeof(windir)) dir_len = sizeof(windir) - 1;
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
                {
                    size_t win_len = (size_t)(last_sep - madeira_exe);
                    if (win_len < sizeof(wine_cwd) - 2) {
                        memcpy(wine_cwd, madeira_exe, win_len);
                        wine_cwd[win_len] = '\\';
                        wine_cwd[win_len + 1] = 0;
                        setenv("MADEIRA_INITIAL_CWD", wine_cwd, 1);
                    }
                }
                dprintf(STDERR_FILENO, "[WineProc] chdir(%s) = %d errno=%d, PWD + MADEIRA_INITIAL_CWD=%s\n",
                        unix_dir, rc, rc ? errno : 0, wine_cwd);
                if (rc)
                    dprintf(STDERR_FILENO, "[WineProc] WARNING: the exe's own directory is not the working "
                                           "directory; programs that open files relative to it will fail\n");
            } else {
                dprintf(STDERR_FILENO, "[WineProc] no directory component in '%s' — working directory left as is\n",
                        madeira_exe);
            }
        }

        // Record this thread so wine_ios_exit knows where to longjmp
        wine_ios_main_thread = pthread_self();
        wine_ios_exit_initialized = 1;

        LOG("Calling __wine_main...");

        /* WOW64_DESIGN.md §2 (device-run fix): publish the main image's arch so
         * the unix side reserves this pseudo-process's guest window BEFORE its
         * first TEB. A 32-bit MAIN image otherwise runs with no window (the
         * machine is unknown unix-side until after the TEB is placed), the
         * image lands outside [B,B+4G) and build_wow64_parameters' 2GB ceiling
         * is unmappable below 4GB. Mirrors the child path's ios_child_main_machine. */
        {
            extern int ios_main_image_i386;
            ios_main_image_i386 = is_i386_target ? 1 : 0;
        }

        if (setjmp(wine_ios_exit_jmpbuf) == 0) {
            __wine_main(argc, argv);
            dprintf(STDERR_FILENO, "[WineProc] __wine_main returned normally\n");
        } else {
            dprintf(STDERR_FILENO, "[WineProc] Wine exited with code %d (caught by longjmp)\n", wine_ios_exit_code);
        }

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
    pthread_cleanup_pop(1);
    return NULL;
}

int wine_process_start(const char *prefix_path) {
    if (__atomic_load_n(&g_wine_running, __ATOMIC_ACQUIRE)) {
        LOG("Wine process already running");
        return 0;
    }

    if (g_prefix_path) free(g_prefix_path);
    g_prefix_path = strdup(prefix_path);

    LOG("Starting Wine process with prefix: %{public}s", prefix_path);

    __atomic_store_n(&g_wine_running, 1, __ATOMIC_RELEASE);

    // Create socketpair to bypass broken iOS UDS accept()
    // pair[0] = wineserver side (injected as client fd)
    // pair[1] = ntdll side (used as fd_socket)
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == -1) {
        LOG("socketpair failed: %{public}s", strerror(errno));
        __atomic_store_n(&g_wine_running, 0, __ATOMIC_RELEASE);
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
        __atomic_store_n(&g_wine_running, 0, __ATOMIC_RELEASE);
        return -1;
    }

    pthread_detach(g_wine_thread);
    LOG("Wine process thread created");
    return 0;
}

int wine_process_is_running(void) {
    return __atomic_load_n(&g_wine_running, __ATOMIC_ACQUIRE);
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


/* ---- ml1076: in-app memory-backing canary --------------------------------- */
#include <sys/mman.h>
#include <os/proc.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
static void mc_sample(const char *mode, const char *phase, uint64_t *fp_out) {
    task_vm_info_data_t v; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    memset(&v, 0, sizeof v);
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n) != KERN_SUCCESS) return;
    if (fp_out) *fp_out = v.phys_footprint;
    fprintf(stderr, "[mem-canary] ml1076 %s %s: footprint=%llu MB resident=%llu MB internal=%llu MB external=%llu MB compressed=%llu MB available=%lld MB\n",
            mode, phase, (unsigned long long)v.phys_footprint >> 20, (unsigned long long)v.resident_size >> 20,
            (unsigned long long)v.internal >> 20, (unsigned long long)v.external >> 20,
            (unsigned long long)v.compressed >> 20, (long long)os_proc_available_memory() >> 20);
}
static uint64_t mc_next(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }
static void mc_run(const char *mode, size_t bytes, int flags, const char *tmpdir, int punch) {
    char path[1024]; int fd = -1; uint64_t before = 0, after = 0, seed = 0x192834756abcdefULL;
    snprintf(path, sizeof path, "%s/madeira-memory-probe-XXXXXX", tmpdir);
    if (!(flags & MAP_ANON)) {
        fd = mkstemp(path);
        if (fd < 0) { fprintf(stderr, "[mem-canary] %s: mkstemp failed errno=%d\n", mode, errno); return; }
        /* the mapping must survive the device locking: no file protection */
        [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:[NSString stringWithUTF8String:path] error:nil];
        unlink(path);
        if (ftruncate(fd, (off_t)bytes)) { fprintf(stderr, "[mem-canary] %s: ftruncate failed errno=%d\n", mode, errno); close(fd); return; }
    }
    mc_sample(mode, "before", &before);
    uint64_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, flags, fd, 0);
    if (p == MAP_FAILED) { fprintf(stderr, "[mem-canary] %s: mmap failed errno=%d\n", mode, errno); if (fd >= 0) close(fd); return; }
    for (size_t i = 0; i < bytes / 8; i++) p[i] = mc_next(&seed);
    mc_sample(mode, "written", &after);
    fprintf(stderr, "[mem-canary] ml1076 %s: %zu MB written -> footprint +%lld MB\n", mode, bytes >> 20, (long long)(after - before) >> 20);
    if (fd >= 0) {
        if (msync(p, bytes, MS_SYNC)) fprintf(stderr, "[mem-canary] %s: msync errno=%d\n", mode, errno);
        mc_sample(mode, "synced", NULL);
        if (flags & MAP_SHARED) {
            /* ask the kernel to drop the pages; a re-read must come back from the file */
            if (madvise(p, bytes, MADV_DONTNEED)) fprintf(stderr, "[mem-canary] %s: madvise errno=%d\n", mode, errno);
            mc_sample(mode, "advised", NULL);
        }
    }
    seed = 0x192834756abcdefULL;
    { size_t bad = 0; for (size_t i = 0; i < bytes / 8; i++) if (p[i] != mc_next(&seed)) { bad++; if (bad == 1) fprintf(stderr, "[mem-canary] %s: DATA MISMATCH at byte %zu\n", mode, i * 8); }
      fprintf(stderr, "[mem-canary] ml1076 %s: verify %s (%zu bad words)\n", mode, bad ? "FAILED" : "ok", bad); }
    mc_sample(mode, "verified", NULL);
    if (punch && fd >= 0) {
        /* decommit semantics: punch a hole under the first half; it must read as zero and cost nothing */
        struct fpunchhole ph; memset(&ph, 0, sizeof ph); ph.fp_offset = 0; ph.fp_length = (off_t)(bytes / 2);
        int r = fcntl(fd, F_PUNCHHOLE, &ph);
        fprintf(stderr, "[mem-canary] ml1076 %s: F_PUNCHHOLE first half -> %d (errno %d); word0 now %llx, word at half %llx\n",
                mode, r, r ? errno : 0, (unsigned long long)p[0], (unsigned long long)p[bytes / 16]);
        mc_sample(mode, "punched", NULL);
    }
    munmap(p, bytes);
    if (fd >= 0) close(fd);
    mc_sample(mode, "released", NULL);
}
void madeira_memory_canary(const char *tmpdir) {
    fprintf(stderr, "[mem-canary] ml1076 start (page %ld, tmp %s)\n", sysconf(_SC_PAGESIZE), tmpdir);
    mc_run("anonymous", 64u << 20, MAP_PRIVATE | MAP_ANON, tmpdir, 0);
    mc_run("file-private-COW", 64u << 20, MAP_PRIVATE, tmpdir, 0);
    mc_run("file-shared-64MB", 64u << 20, MAP_SHARED, tmpdir, 1);
    mc_run("file-shared-512MB", 512u << 20, MAP_SHARED, tmpdir, 0);
    /* ml1079: CONTENTION. ph-rdr46 stalled with a thread blocked in a first-touch
     * page fault on a fresh 32 MB extent while ~886 MB of earlier extents in the
     * SAME file were dirty (presumably being written back). Does a fault on a
     * sparse region block behind writeback of the same vnode? And does a separate
     * file avoid it? Dirty 512 MB, kick writeback, then time 64 first touches on
     * a fresh region of the same file and of a second file, several times. */
    {
        char pa[1024], pb[1024]; int fa, fb; size_t big = 512u << 20, probe = 64u << 20; unsigned round;
        snprintf(pa, sizeof pa, "%s/madeira-memory-probe-A-XXXXXX", tmpdir); snprintf(pb, sizeof pb, "%s/madeira-memory-probe-B-XXXXXX", tmpdir);
        fa = mkstemp(pa); fb = mkstemp(pb);
        if (fa >= 0 && fb >= 0) {
            [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:[NSString stringWithUTF8String:pa] error:nil];
            [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:[NSString stringWithUTF8String:pb] error:nil];
            unlink(pa); unlink(pb);
            ftruncate(fa, (off_t)(big + 8 * probe)); ftruncate(fb, (off_t)(8 * probe));
            uint64_t *dirty = mmap(NULL, big, PROT_READ | PROT_WRITE, MAP_SHARED, fa, 0);
            if (dirty != MAP_FAILED) {
                uint64_t seed = 1;
                for (size_t i = 0; i < big / 8; i++) dirty[i] = mc_next(&seed);
                msync(dirty, big, MS_ASYNC);
                for (round = 0; round < 6; round++) {
                    struct timeval t0, t1, t2; unsigned k; volatile char sink = 0;
                    char *ra = mmap(NULL, probe, PROT_READ | PROT_WRITE, MAP_SHARED, fa, (off_t)(big + round * probe));
                    char *rb = mmap(NULL, probe, PROT_READ | PROT_WRITE, MAP_SHARED, fb, (off_t)(round * probe));
                    if (ra == MAP_FAILED || rb == MAP_FAILED) break;
                    gettimeofday(&t0, NULL);
                    for (k = 0; k < 64; k++) sink += ra[(probe / 64) * k];
                    gettimeofday(&t1, NULL);
                    for (k = 0; k < 64; k++) sink += rb[(probe / 64) * k];
                    gettimeofday(&t2, NULL);
                    fprintf(stderr, "[mem-canary] ml1079 round %u (%s): same-file first-touch %ld us/64 pages, other-file %ld us/64 pages\n", round,
                            round == 0 ? "right after dirtying 512 MB" : "later",
                            (long)((t1.tv_sec - t0.tv_sec) * 1000000 + (t1.tv_usec - t0.tv_usec)),
                            (long)((t2.tv_sec - t1.tv_sec) * 1000000 + (t2.tv_usec - t1.tv_usec)));
                    (void)sink;
                    munmap(ra, probe); munmap(rb, probe);
                    usleep(500000);
                }
                mc_sample("contention", "after", NULL);
                munmap(dirty, big);
            }
        }
        if (fa >= 0) close(fa); if (fb >= 0) close(fb);
    }
    /* ml1080: SUSTAINED DIRTYING THROUGHPUT. Hypothesis for the ph-rdr46 stall:
     * xnu throttles producers of dirty file-backed pages once the dirty backlog
     * passes a threshold, pacing them to the (wear-limited) writeback rate. Write
     * 1.5 GB through one shared mapping in 128 MB chunks and time each chunk; a
     * cliff after N chunks is the threshold, and the slow rate is the ceiling any
     * file-backed tier would impose on the game's loading writes. */
    {
        char pc[1024]; int fc; size_t total = 1536u << 20, chunk = 128u << 20;
        snprintf(pc, sizeof pc, "%s/madeira-memory-probe-C-XXXXXX", tmpdir);
        fc = mkstemp(pc);
        if (fc >= 0) {
            [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:[NSString stringWithUTF8String:pc] error:nil];
            unlink(pc); ftruncate(fc, (off_t)total);
            uint64_t *m = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fc, 0);
            if (m != MAP_FAILED) {
                size_t c; struct timeval t0, t1;
                for (c = 0; c < total / chunk; c++) {
                    uint64_t *q = m + (c * chunk) / 8; size_t i;
                    gettimeofday(&t0, NULL);
                    for (i = 0; i < chunk / 8; i += 2048) q[i] = (uint64_t)i ^ c;   /* one word per 16 KB page: dirty every page, minimal CPU */
                    gettimeofday(&t1, NULL);
                    long us = (t1.tv_sec - t0.tv_sec) * 1000000 + (t1.tv_usec - t0.tv_usec);
                    task_vm_info_data_t v; mach_msg_type_number_t n = TASK_VM_INFO_COUNT; memset(&v, 0, sizeof v);
                    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n);
                    fprintf(stderr, "[mem-canary] ml1080 chunk %zu: dirtied 128 MB in %ld us (%ld MB/s); footprint=%llu MB external=%llu MB\n",
                            c, us, us > 0 ? (long)(128000000L / us) : -1L, (unsigned long long)v.phys_footprint >> 20, (unsigned long long)v.external >> 20);
                }
                {   /* and a re-read of the first chunk after the rest was written: still cheap? */
                    volatile uint64_t sink = 0; size_t i; gettimeofday(&t0, NULL);
                    for (i = 0; i < chunk / 8; i += 2048) sink += m[i];
                    gettimeofday(&t1, NULL);
                    fprintf(stderr, "[mem-canary] ml1080 re-read of chunk 0: %ld us\n", (long)((t1.tv_sec - t0.tv_sec) * 1000000 + (t1.tv_usec - t0.tv_usec)));
                    (void)sink;
                }
                munmap(m, total);
            }
            close(fc);
        }
        mc_sample("throughput", "after", NULL);
    }
    fprintf(stderr, "[mem-canary] ml1076 done\n");
}
