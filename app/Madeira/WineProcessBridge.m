// WineProcessBridge.m - Initialize Wine's ntdll Unix-side on iOS
// This calls __wine_main() to bootstrap the Wine process, connecting
// to the already-running wineserver thread.

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <pthread.h>
#import "WineProcessBridge.h"
/* AVFoundation: AVAudioSession activation for the Tier-2 audio driver
 * (audio_null_ios.c RemoteIO backend). AudioToolbox: pulls the framework
 * in via autolink — the static-lib driver code can't autolink itself. */
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <unistd.h>
#include <pwd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <setjmp.h>
#include <stdlib.h>
#include <errno.h>
#include <dirent.h>
#include "../../build/madeira_cfg.h"   /* ml1095: one config file */
#include "../../build/madeira_redact.h"   /* the arguments are logged with credential-like values redacted */
#include <sys/stat.h>
#include <pwd.h>
#include <limits.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <mach-o/loader.h>

#include "WineProcessBridge.h"
#include "WineServerBridge.h"
#include "PrefixExtractor.h"
#include "FEXBridge.h"  // fex_get_jit_write_offset()

/* Write end of the pipe on fd 0, or -1 when stdin was left alone. The app's
 * host writes the guest's keystrokes here. */
int madeira_stdin_master = -1;
/* madeira-stdout-pipe: read end of the guest's stdout, or -1 when the pipe is
 * not enabled and stdout still goes to the shared log. */
int madeira_stdout_master = -1;

int madeira_stdout_is_open(void) { return madeira_stdout_master >= 0; }

long madeira_stdout_read(void *buf, unsigned long len) {
    if (madeira_stdout_master < 0 || !buf || !len) return -1;
    return read(madeira_stdout_master, buf, (size_t)len);
}

long madeira_stdin_write(const void *buf, unsigned long len) {
    if (madeira_stdin_master < 0) return -1;
    return (long)write(madeira_stdin_master, buf, (size_t)len);
}

/* Whether the pipe exists. An accessor rather than letting callers read the
 * global: it is written on the Wine thread and read from the UI thread, and
 * Swift 6 refuses to import a mutable C global as concurrency-safe. */
int madeira_stdin_is_open(void) {
    return madeira_stdin_master >= 0;
}

/* Close the write end so the guest's stdin reaches EOF.
 *
 * Without this, anything that reads to EOF -- an interpreter fed a script,
 * sort, the type/more family -- blocks forever after consuming what it was
 * given. Combined with one-program-per-launch that costs the whole app launch,
 * so the terminal must be able to signal "no more input". */
void madeira_stdin_close(void) {
    if (madeira_stdin_master < 0) return;
    close(madeira_stdin_master);
    madeira_stdin_master = -1;
    dprintf(STDERR_FILENO, "[stdin-pipe] write end closed; guest stdin is at EOF\n");
}

// Thread-local globals for wine_ios_exit longjmp (used by wine_ios_exit.h shim in ntdll)
// Each Wine "process" thread has its own jmpbuf so child processes can exit independently.
_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;

/* Non-thread-local copy of the above, published when the Wine thread unwinds.
 * Valid once wine_process_is_running() returns 0. */
/* Not volatile: the atomics below provide the ordering, and volatile would
 * only obscure that they are doing so. */
static int g_wine_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;


static os_log_t wine_proc_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.madeira.emulator", "wine-proc"); });
    return log;
}

#define LOG(fmt, ...) os_log(wine_proc_log(), "[WineProc] " fmt, ##__VA_ARGS__)

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

/* madeira-bcd: env.MADEIRA_SRV_FGETPATH of the launch in progress, read by the in-app
 * wineserver (build/wineserver/fd_ios.c), which is running before a game's env lines
 * are set. Set after they are applied, cleared when the session ends. */
volatile int g_madeira_srv_fgetpath = 0;
static pthread_t g_wine_thread;
static volatile int g_wine_running = 0;
/* madeira-bcd: the server's per-launch switches (fd_ios.c, request_ios.c; ntdll's
 * server_ios.c reads g_madeira_srv_direct too), for the in-app wineserver, which is
 * running before a game's env lines are set. Set after they are applied, cleared when
 * the session ends. All off by default. */
volatile int g_madeira_srv_eco_follow = 0;   /* env.MADEIRA_SRV_ECO_FOLLOW = 1 */
volatile int g_madeira_srv_direct = 0;       /* env.MADEIRA_SRV_DIRECT = 1 or 2 */
volatile int g_madeira_srv_idle_us = 0;      /* env.MADEIRA_SRV_IDLE_US = 100..50000, 0 = 1000 */
volatile int g_madeira_srv_log_all = 0;      /* env.MADEIRA_SRV_LOG_ALL = 1 */

/* Session exit report for the library front end. The app marks one process as
 * its own: the program it hands to __wine_main below, which is the session's
 * initial process. ntdll's common exit wrapper (build/ntdll-unix/server_ios.c)
 * calls wine_launched_process_did_exit() for that process only, on whichever
 * thread ends it. Only the status is kept: no names, no allocation, no
 * logging. g_launch_exit holds (1 << 32) | status when the program ended with
 * an NTSTATUS error (0xC...), else 0. */
static uint64_t g_launch_exit = 0;
/* A game in a Madeira Dock session asked Steam to start another game
 * (steam://run/<App ID>); ntdll's process gate (build/ntdll-unix/process_ios.c)
 * refuses steam.exe and reports the App ID here. 0: none since the last reset. */
static uint32_t g_steam_run_app = 0;
void wine_steam_run_requested(unsigned int appid) {
    __atomic_store_n(&g_steam_run_app, appid, __ATOMIC_RELEASE);
}
int wine_steam_run_request(uint32_t *appid) {
    uint32_t value = __atomic_load_n(&g_steam_run_app, __ATOMIC_ACQUIRE);
    if (!value) return 0;
    if (appid) *appid = value;
    return 1;
}
void wine_launched_process_did_exit(int status) {
    if ((uint32_t)status >= 0xC0000000u)
        __atomic_store_n(&g_launch_exit, (UINT64_C(1) << 32) | (uint32_t)status, __ATOMIC_RELEASE);
}
void wine_exit_status_reset(void) {
    __atomic_store_n(&g_launch_exit, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&g_steam_run_app, 0, __ATOMIC_RELEASE);
}
int wine_crash_exit_status(uint32_t *status) {
    uint64_t value = __atomic_load_n(&g_launch_exit, __ATOMIC_ACQUIRE);
    if (!(value >> 32)) return 0;
    if (status) *status = (uint32_t)value;
    return 1;
}
static char *g_prefix_path = NULL;

/* Export MADEIRA_DOCS_DIR before main(), while HOME is still the app container.
 * The in-app wineserver thread sets HOME to the Wine prefix before it creates its
 * first object, and madsync reads madeira.cfg inproc-sync right there (then keeps
 * the answer for the whole app run); with MADEIRA_DOCS_DIR exported only when the
 * guest starts (wine_process_thread below), that read looked in
 * Documents/wine/Documents and missed the user's madeira.cfg. Kill switch:
 * MADEIRA_CFG_EARLY_DOCS=0 in the process environment or
 * env.MADEIRA_CFG_EARLY_DOCS = 0 in madeira.cfg. Pure C, host-tested
 * (tests/host/check-cfg-early-docs.py). */
static const char *g_madeira_docs_early = "not-run";
/* madeira-env-locked: MADEIRA_ENV_LOCKED is a comma-separated list of names
 * the host set on purpose. Without it a madeira.cfg line -- or a library
 * game's own config -- could replace the program the front end was asked to
 * launch, and the user taps one thing while another starts, with nothing on
 * screen to say so. The match is on the whole name between commas, so a lock
 * on MADEIRA_EXE does not also catch MADEIRA_EXEC_FOO. Nothing is locked
 * unless a host asks for it. */
static int madeira_env_is_locked(const char *name)
{
    const char *locked = getenv("MADEIRA_ENV_LOCKED");
    if (!locked || !*locked || !name || !*name) return 0;
    size_t n = strlen(name);
    for (const char *p = locked; *p; ) {
        while (*p == ' ' || *p == ',') p++;
        const char *start = p;
        while (*p && *p != ',') p++;
        const char *end = p;
        while (end > start && end[-1] == ' ') end--;
        if ((size_t)(end - start) == n && !strncmp(start, name, n)) return 1;
    }
    return 0;
}

static int madeira_cfg_off_word(const char *v)
{
    return v && (!strcmp(v, "0") || !strcmp(v, "off") || !strcmp(v, "no"));
}
static const char *madeira_docs_dir_early(void)
{
    char docs[1024], v[16];
    const char *home = getenv("HOME"), *have = getenv("MADEIRA_DOCS_DIR");
    if (madeira_cfg_off_word(getenv("MADEIRA_CFG_EARLY_DOCS"))) return "off-env";
    if (have && *have) return "already-set";
    if (!home || !*home || strlen(home) + 11 >= sizeof(docs)) return "no-home";
    snprintf(docs, sizeof(docs), "%s/Documents", home);
    setenv("MADEIRA_DOCS_DIR", docs, 0);
    if (madeira_cfg_get("env.MADEIRA_CFG_EARLY_DOCS", v, sizeof(v)) && madeira_cfg_off_word(v)) {
        unsetenv("MADEIRA_DOCS_DIR");
        setenv("MADEIRA_CFG_EARLY_DOCS", "0", 1);   /* also turns off madeira_cfg.h's container fallback */
        return "off-cfg";
    }
    return "set";
}
__attribute__((constructor)) static void madeira_docs_dir_ctor(void)
{
    g_madeira_docs_early = madeira_docs_dir_early();
}

/* The profile's AppData\LocalLow folder.
 *
 * The shell-folder registry maps FOLDERID_LocalAppDataLow to
 * %USERPROFILE%\AppData\LocalLow, and the profile is named after the unix user
 * (ntdll's set_home_dir: "mobile" on a device). The template ships the folders
 * of the user it was built as, so the running user's LocalLow does not exist,
 * and nothing creates it: SHGetKnownFolderPath without KF_FLAG_CREATE fails
 * with ERROR_PATH_NOT_FOUND ("Failed to get LocalAppDataLow path, hr
 * 0x80070003"). A program that keeps its log there then opens a relative path
 * that does not exist either, is left with a closed stdout, and its C runtime
 * fast-fails (0xc0000409) before the first frame.
 *
 * Only LocalLow is created. Roaming is left alone: Wine populates it itself and
 * decides by existence (see madeira_undo_appdata_skeleton). Local already
 * exists on every start (the TEMP directory is in it). */
/* The PE shader cache's build identity (madeira_d3d12.c, mad_sc_init) includes the
 * LC_UUID of the image this bridge is in: the converter's unix half is linked into it
 * too, so the UUID changes whenever the converter could have, and a cache keyed on
 * the DLL's own build would otherwise keep serving an older converter's output. */
static void madeira_export_image_uuid(void)
{
    Dl_info di;
    const struct mach_header_64 *mh;
    const struct load_command *lc;
    uint32_t i;

    if (!dladdr((const void *)&madeira_export_image_uuid, &di) || !(mh = di.dli_fbase)) return;
    lc = (const struct load_command *)(mh + 1);
    for (i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize))
    {
        if (lc->cmd != LC_UUID) continue;
        const uint8_t *u = ((const struct uuid_command *)lc)->uuid;
        char hex[33];
        for (int k = 0; k < 16; k++) snprintf(hex + 2 * k, 3, "%02x", u[k]);
        setenv("MADEIRA_APP_IMAGE_UUID", hex, 1);
        return;
    }
}

static void madeira_ensure_locallow(NSString *prefix)
{
    /* 0 leaves the profile's AppData\LocalLow folder missing, as before. */
    const char *off = getenv( "MADEIRA_PROFILE_LOCALLOW" );
    /* ml1236: this runs from wineserver_start, before wine_process_thread exports
     * madeira.cfg's env.* lines, so the cfg line is read here directly. */
    char cfg_off[16];
    if (!off && madeira_cfg_get( "env.MADEIRA_PROFILE_LOCALLOW", cfg_off, sizeof(cfg_off) )) off = cfg_off;
    if (off && off[0] == '0') return;

    const char *name = getenv( "USER" );
    if (!name)
    {
        struct passwd *pwd = getpwuid( getuid() );
        name = pwd && pwd->pw_name ? pwd->pw_name : "wine";
    }
    const char *slash = strrchr( name, '/' );
    if (slash) name = slash + 1;
    if ((slash = strrchr( name, '\\' ))) name = slash + 1;   /* ml1236: as ntdll's set_home_dir */
    if (!name[0]) return;

    NSString *path = [prefix stringByAppendingPathComponent:
        [NSString stringWithFormat:@"drive_c/users/%s/AppData/LocalLow", name]];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) return;
    BOOL made = [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    extern void ws_log(const char *fmt, ...);
    ws_log( "[profile] users/%s/AppData/LocalLow %s", name, made ? "created" : "could NOT be created" );
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
        madeira_ensure_locallow( prefix );
    }
}

/* ===========================================================================
 * WoW64: 32-bit (i386) targets. See docs/WOW64.md.
 *
 * Everything below is used only when the bundle carries the i386 Wine set
 * (app/Madeira/i386-windows, built by build/wine-i386/build.sh) or when the
 * target exe is an i386 PE. A bundle without i386-windows and a 64-bit
 * target take exactly the code path they took before.
 * ========================================================================= */
#define MADEIRA_IMAGE_FILE_MACHINE_I386 0x014c
#define MADEIRA_IMAGE_FILE_MACHINE_AMD64 0x8664
#define MADEIRA_IMAGE_FILE_MACHINE_ARM64 0xaa64
#define MADEIRA_IMAGE_FILE_MACHINE_ARM64EC 0xa641

/* build/ntdll-unix/virtual_ios.c: nonzero when this session's MAIN image is
 * 32-bit. The unix side reserves the process's guest window before its first
 * TEB when it is set; the image's machine is not known there until later. */
extern int ios_main_image_i386;

/* IMAGE_FILE_HEADER.Machine, read off disk (MZ -> e_lfanew -> "PE\0\0").
 * 0 on any read or format failure. */
static uint16_t madeira_pe_machine(const char *unix_path)
{
    unsigned char dos[64], pe[6];
    uint16_t machine = 0;
    FILE *f;

    if (!unix_path || !*unix_path || !(f = fopen(unix_path, "rb"))) return 0;
    if (fread(dos, 1, sizeof(dos), f) == sizeof(dos) && dos[0] == 'M' && dos[1] == 'Z')
    {
        uint32_t lfanew = (uint32_t)dos[0x3c] | ((uint32_t)dos[0x3d] << 8) |
                          ((uint32_t)dos[0x3e] << 16) | ((uint32_t)dos[0x3f] << 24);
        if (lfanew <= (16u << 20) && fseek(f, (long)lfanew, SEEK_SET) == 0 &&
            fread(pe, 1, sizeof(pe), f) == sizeof(pe) &&
            pe[0] == 'P' && pe[1] == 'E' && !pe[2] && !pe[3])
            machine = (uint16_t)(pe[4] | (pe[5] << 8));
    }
    fclose(f);
    return machine;
}

/* The machine of the file the launch below will run, or 0 when it is not
 * known (the caller then treats the target as 64-bit, as before).
 *  - "C:\...\app.exe": the file under the prefix's drive_c.
 *  - a bare name: the launch resolves it as C:\windows\system32\<name>, which
 *    links the 64-bit farms; the first farm copy's PE header is probed. Otherwise it is looked up in the bundle's i386-windows. To
 *    launch the 32-bit build of a name both sets carry (explorer.exe, cmd.exe),
 *    give its full path, C:\windows\syswow64\<name>.
 *  - any other form (another drive, a relative Win32 path) is not probed. */
static uint16_t madeira_target_machine(const char *exe, const char *prefix, NSString *bundle)
{
    static const char * const farms64[] = { "aarch64-windows", "arm64ec-windows" };
    char probe[PATH_MAX];
    size_t skip;

    if ((exe[0] == 'C' || exe[0] == 'c') && exe[1] == ':' && exe[2] == '\\')
    {
        skip = strlen(prefix) + strlen("/drive_c/");
        if (snprintf(probe, sizeof(probe), "%s/drive_c/%s", prefix, exe + 3) >= (int)sizeof(probe))
            return 0;
        for (char *p = probe + skip; *p; p++) if (*p == '\\') *p = '/';
    }
    else if (strchr(exe, '\\') || (exe[0] && exe[1] == ':'))
        return 0;
    else
    {
        for (size_t i = 0; i < sizeof(farms64) / sizeof(farms64[0]); i++)
        {
            if (snprintf(probe, sizeof(probe), "%s/%s/%s", bundle.fileSystemRepresentation, farms64[i], exe)
                    >= (int)sizeof(probe))
                return 0;
            if (access(probe, R_OK) == 0) return madeira_pe_machine(probe);
        }
        if (snprintf(probe, sizeof(probe), "%s/i386-windows/%s", bundle.fileSystemRepresentation, exe)
                >= (int)sizeof(probe))
            return 0;
    }
    return madeira_pe_machine(probe);
}

/* Select the core by the executable's machine, not its spelling. The explicit
 * force switch stays available; the i386 (WoW64) rule still takes precedence.
 * Unknown or unreadable targets keep the original name/path heuristic. */
static BOOL madeira_use_arm64ec_for_target(const char *exe, const char *force_ec,
                                           uint16_t machine, BOOL has_i386_set)
{
    if (has_i386_set && machine == MADEIRA_IMAGE_FILE_MACHINE_I386) return NO;
    if (force_ec && *force_ec == '1') return YES;
    if (machine == MADEIRA_IMAGE_FILE_MACHINE_AMD64 || machine == MADEIRA_IMAGE_FILE_MACHINE_ARM64EC)
        return YES;
    if (machine == MADEIRA_IMAGE_FILE_MACHINE_ARM64) return NO;
    return strstr(exe, "x64") != NULL || strchr(exe, '\\') != NULL;
}

/* The bundle carries the i386 Wine set. */
static BOOL madeira_bundle_has_i386(NSString *bundle)
{
    NSString *ntdll = [bundle stringByAppendingPathComponent:@"i386-windows/ntdll.dll"];
    return access(ntdll.fileSystemRepresentation, R_OK) == 0;
}

/* Microsoft's x86 Visual C++ runtime, taken out of Microsoft's installer by the app
 * (VCRedist.swift) into Documents/vcruntime32: linked over Wine's i386 builtins in
 * syswow64 for 32-bit programs, as the x86_64-vcruntime overlay below does for 64-bit
 * ones (that one reads Documents/vcruntime). Runs after the syswow64 farm links, so
 * removing the folder brings the builtins back at the next session. 32-bit code runs
 * whole under the emulator, so there is no ARM64EC exemption to keep here.
 * env.MADEIRA_VCREDIST_X86 = 0 leaves them out. */
static void madeira_overlay_vcruntime32(NSFileManager *fm, NSString *prefix)
{
    const char *e = getenv("MADEIRA_VCREDIST_X86");   /* 0: 32-bit programs keep Wine's own C++ runtime instead of the Microsoft x86 runtime the app downloaded (Documents/vcruntime32) */
    if (e && e[0] == '0') { dprintf(STDERR_FILENO, "[WineProc] MADEIRA_VCREDIST_X86=0: Microsoft x86 runtime overlay skipped\n"); return; }
    NSString *source = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                        stringByAppendingPathComponent:@"vcruntime32"];
    NSArray *files = [fm contentsOfDirectoryAtPath:source error:nil];
    if (!files.count) return;
    NSString *farmDir = [prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"];
    int linked = 0;
    for (NSString *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"dll"]) continue;
        NSString *dst = [farmDir stringByAppendingPathComponent:f];
        [fm removeItemAtPath:dst error:nil];
        if ([fm createSymbolicLinkAtPath:dst withDestinationPath:[source stringByAppendingPathComponent:f] error:nil]) linked++;
    }
    dprintf(STDERR_FILENO, "[WineProc] Symlinked %d MS VC++ x86 runtime DLLs over i386 builtins (Documents/vcruntime32; MADEIRA_VCREDIST_X86=0 leaves them out)\n", linked);
}

/* C:\windows\syswow64: the i386 farm, the Windows name for this pattern. A
 * 32-bit process's system32 is redirected here, and the unix loader's
 * machine -> directory mapping looks here for the 32-bit ntdll, kernel32 and
 * the rest. Linked for every session once the bundle has the i386 set, so a
 * 64-bit launcher can start a 32-bit child. */
static void madeira_link_syswow64(NSFileManager *fm, NSString *prefix, NSString *bundle)
{
    NSString *farmDir = [prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"];
    NSString *source = [bundle stringByAppendingPathComponent:@"i386-windows"];
    int linked = 0;

    [fm createDirectoryAtPath:farmDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *f in [fm contentsOfDirectoryAtPath:source error:nil])
    {
        if ([f hasPrefix:@"."]) continue;
        NSString *dst = [farmDir stringByAppendingPathComponent:f];
        [fm removeItemAtPath:dst error:nil];  /* self-heal stale links on reinstall */
        if ([fm createSymbolicLinkAtPath:dst
                     withDestinationPath:[source stringByAppendingPathComponent:f] error:nil])
            linked++;
    }
    dprintf(STDERR_FILENO, "[WineProc] Farm syswow64: %d links -> i386-windows\n", linked);
}

/* <system_dir>\wbem: syswow64\wbem from the i386 farm for 32-bit targets,
 * system32\wbem from the session's farm for 64-bit ones. The farms are flat,
 * but WMI's registered InprocServer32 paths are C:\windows\system32\wbem\<name>
 * (wine.inf installs these modules there), so CoCreateInstance(CLSID_WbemLocator)
 * -- for example dxdiagn asking WMI about the display adapter, or a game's
 * GPU requirement check -- fails with c0000135 when the subdirectory is
 * empty. The list is wine.inf's. */
static void madeira_link_wbem(NSFileManager *fm, NSString *prefix, NSString *system_dir, NSString *source)
{
    static const char * const wbem[] = { "wbemprox.dll", "wbemdisp.dll", "wmiutils.dll",
                                         "wmic.exe", "mofcomp.exe" };
    NSString *dir = [[prefix stringByAppendingPathComponent:@"drive_c/windows"]
                        stringByAppendingPathComponent:[system_dir stringByAppendingPathComponent:@"wbem"]];
    int linked = 0;

    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (size_t i = 0; i < sizeof(wbem) / sizeof(wbem[0]); i++)
    {
        NSString *n = [NSString stringWithUTF8String:wbem[i]];
        NSString *src = [source stringByAppendingPathComponent:n];
        NSString *dst = [dir stringByAppendingPathComponent:n];
        [fm removeItemAtPath:dst error:nil];
        if (![fm fileExistsAtPath:src]) continue;
        if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil]) linked++;
    }
    dprintf(STDERR_FILENO, "[WineProc] %s\\wbem: %d/%zu links\n", system_dir.UTF8String,
            linked, sizeof(wbem) / sizeof(wbem[0]));
}

static void madeira_link_syswow64_wbem(NSFileManager *fm, NSString *prefix, NSString *bundle)
{
    madeira_link_wbem(fm, prefix, @"syswow64", [bundle stringByAppendingPathComponent:@"i386-windows"]);
}

/* d3d9 = wined3d (madeira.cfg or the game's own lines; MADEIRA_D3D9=wined3d in
 * the environment otherwise): this session's d3d9.dll is Wine's own frontend on
 * wined3d's OpenGL renderer (opengl32 -> the winios WGL driver -> Zink on
 * MoltenVK), not DXMT's. Unset, "emulated" and "native" keep DXMT's.
 *
 * The farms ship Wine's d3d9 as d3d9-wined3d.dll beside DXMT's d3d9.dll (ARM64EC
 * for x64 programs, i386 for 32-bit ones). The links made for this session are
 * re-pointed: system32\d3d9.dll when it names the ARM64EC DXMT file, sysx64\ and
 * syswow64\d3d9.dll. Every session relinks the farms first, so the next session
 * without the setting gets DXMT's again. No load-order override is needed: the
 * iOS unix loader maps the PE file the link names (load_builtin in
 * build/ntdll-unix/loader_ios.c returns STATUS_IMAGE_ALREADY_LOADED).
 * wined3d.dll, d3d8.dll and ddraw.dll are Wine's in both farms already; d3d8 and
 * ddraw always draw through wined3d. */
static BOOL madeira_d3d9_wined3d_wanted(void)
{
    char v[32] = "";
    const char *e;

    if (madeira_cfg_get("d3d9", v, sizeof v) && v[0]) return !strcasecmp(v, "wined3d");
    e = getenv("MADEIRA_D3D9");   /* the d3d9 key's value: emulated (default) or native = DXMT's i386 shim; wined3d = Wine's d3d9 on wined3d/OpenGL for 32- and 64-bit programs */
    return e && !strcasecmp(e, "wined3d");
}

/* <dir>\d3d9.dll -> <farm>/d3d9-wined3d.dll. 1 linked, 0 link failed, -1 the farm has no such file. */
static int madeira_link_d3d9_wined3d_in(NSFileManager *fm, NSString *dir, NSString *farm)
{
    NSString *src = [farm stringByAppendingPathComponent:@"d3d9-wined3d.dll"];
    NSString *dst = [dir stringByAppendingPathComponent:@"d3d9.dll"];

    if (access(src.fileSystemRepresentation, R_OK) != 0) return -1;
    [fm removeItemAtPath:dst error:nil];
    return [fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil] ? 1 : 0;
}

static void madeira_link_d3d9_wined3d(NSFileManager *fm, NSString *prefix, NSString *bundle, BOOL has_i386_set)
{
    NSString *win = [prefix stringByAppendingPathComponent:@"drive_c/windows"];
    NSString *ec = [bundle stringByAppendingPathComponent:@"arm64ec-windows"];
    NSString *sys32 = [win stringByAppendingPathComponent:@"system32"];
    NSString *cur = [fm destinationOfSymbolicLinkAtPath:[sys32 stringByAppendingPathComponent:@"d3d9.dll"] error:nil];
    const char *backend = getenv("MADEIRA_GL_BACKEND");
    const char *extmax;
    int s32 = -2, s64, s32wow = -2;

    /* system32 holds the ARM64EC farm in an x64 session and, through the
     * cross-link pass, in an ARM64 one whose farm has no d3d9.dll. */
    if ([cur isEqualToString:[ec stringByAppendingPathComponent:@"d3d9.dll"]])
        s32 = madeira_link_d3d9_wined3d_in(fm, sys32, ec);
    s64 = madeira_link_d3d9_wined3d_in(fm, [win stringByAppendingPathComponent:@"sysx64"], ec);
    if (has_i386_set)
        s32wow = madeira_link_d3d9_wined3d_in(fm, [win stringByAppendingPathComponent:@"syswow64"],
                                              [bundle stringByAppendingPathComponent:@"i386-windows"]);
    setenv("MADEIRA_D3D9", "wined3d", 1);
    /* wined3d asks for a context without a profile mask, gets a compatibility
     * one and reads glGetString(GL_EXTENSIONS); the 3072-byte cut that 32-bit
     * contexts get for engines that copy the string into a fixed buffer would
     * hide extensions from it. overwrite=0: madeira.cfg can still set a limit. */
    setenv("MADEIRA_GL_EXTENSIONS_MAX", "0", 0);
    extmax = getenv("MADEIRA_GL_EXTENSIONS_MAX");   /* byte limit of GL_EXTENSIONS in 32-bit OpenGL contexts (opengl32, patches/wine-opengl-winios.patch): unset = 3072, 0 = none; d3d9 = wined3d makes it 0 unless set */
    dprintf(STDERR_FILENO, "[WineProc] d3d9 = wined3d: Wine's d3d9 on wined3d/OpenGL (system32 %d, sysx64 %d, "
            "syswow64 %d; 1 = linked, -1 = farm has no d3d9-wined3d.dll, -2 = not this session's), "
            "MADEIRA_GL_BACKEND=%s, MADEIRA_GL_EXTENSIONS_MAX=%s\n", s32, s64, s32wow,
            backend ? backend : "(unset)", extmax ? extmax : "(unset)");
    if (!backend || strcmp(backend, "zink"))
        dprintf(STDERR_FILENO, "[WineProc] d3d9 = wined3d needs desktop OpenGL (gl-backend = zink, the bundle's gl/ "
                "folder); with OpenGL ES wined3d finds no usable context and Direct3DCreate9 returns NULL\n");
}

/* Vulkan, and vkd3d-proton as a second Direct3D 12 route (docs/BUILDING.md,
 * "winevulkan and vkd3d-proton"). madeira.cfg, or the game's own lines:
 *
 *   vulkan = moltenvk | kosmickrisp | off | <path>.dylib
 *            the Vulkan library winevulkan loads: gl/libMoltenVK.dylib (the one
 *            Zink uses), gl/libvulkan_kosmickrisp.dylib, or a file named by path
 *            (absolute, or relative to the app bundle). Unset: MoltenVK whenever
 *            Vulkan is on.
 *   d3d12  = vkd3d
 *            this session's d3d12.dll and d3d12core.dll are vkd3d-proton's
 *            (vulkan/arm64ec-windows in the bundle) instead of madeira-d3d12's.
 *   d3d11  = dxvk
 *            this session's d3d11.dll, d3d10core.dll and dxgi.dll are DXVK's
 *            (vulkan/arm64ec-windows/dxvk-*.dll, build/dxvk/build.sh) instead of
 *            DXMT's; docs/DXVK.md. DXVK's d3d11 needs its own dxgi, and DXMT's
 *            dxgi is then gone, so Direct3D 12 must be vkd3d-proton (the usual
 *            DXVK + vkd3d-proton pairing): with d3d12 unset this implies
 *            d3d12 = vkd3d for the session.
 *
 * Vulkan is on for a session when `vulkan` names a library, d3d12 = vkd3d or
 * d3d11 = dxvk.
 * Off (the default) changes nothing: the prefix gets no vulkan-1.dll or
 * winevulkan.dll (no farm holds them, so a program that probes for Vulkan
 * finds none, as before), MADEIRA_VULKAN_LIBRARY stays unset, and win32u lists
 * no Vulkan GPU (build/win32u-unix/vulkan_ios.c). On: MADEIRA_VULKAN_LIBRARY
 * names the library and system32 (in an x64 session) and sysx64 get links to
 * the ARM64EC vulkan-1.dll and winevulkan.dll; with d3d12 = vkd3d also to
 * vkd3d-proton's d3d12.dll and d3d12core.dll, replacing the farm's links. Every
 * session relinks the farms first, so the next session without the setting
 * gets madeira-d3d12 again; the two Vulkan DLLs, which no farm relinks, are
 * removed here when they name the bundle's vulkan folder. x64 programs only:
 * the unix side binds no 32-bit table yet (build/ntdll-unix/virtual_ios.c). */
static BOOL madeira_d3d11_dxvk_wanted(void)
{
    char v[32] = "";

    return madeira_cfg_get("d3d11", v, sizeof v) && !strcasecmp(v, "dxvk");
}

/* d3d12 = vkd3d, or d3d12 unset with d3d11 = dxvk (DXVK's dxgi has no
 * madeira-d3d12 swapchain; vkd3d-proton presents through it). */
static BOOL madeira_d3d12_vkd3d_wanted(void)
{
    char v[32] = "";

    if (madeira_cfg_get("d3d12", v, sizeof v) && v[0]) return !strcasecmp(v, "vkd3d");
    return madeira_d3d11_dxvk_wanted();
}

/* The Vulkan library for this session, or nil when Vulkan stays off. */
extern int madeira_vulkan_static_available(void);

static NSString *madeira_vulkan_library(NSString *bundle)
{
    char v[512] = "";
    BOOL set = madeira_cfg_get("vulkan", v, sizeof v) && v[0];

    if (set && (!strcasecmp(v, "off") || !strcmp(v, "0"))) return nil;
    if (!set && !madeira_d3d12_vkd3d_wanted() && !madeira_d3d11_dxvk_wanted()) return nil;
    if (set && (!strcasecmp(v, "static") || !strcmp(v, "1")))
        return madeira_vulkan_static_available() ? @"madeira-static-moltenvk" : nil;
    if (!set || !strcasecmp(v, "moltenvk"))
        return [bundle stringByAppendingPathComponent:@"gl/libMoltenVK.dylib"];
    if (!strcasecmp(v, "kosmickrisp"))
        return [bundle stringByAppendingPathComponent:@"gl/libvulkan_kosmickrisp.dylib"];
    if (strchr(v, '/'))
        return v[0] == '/' ? [NSString stringWithUTF8String:v]
                           : [bundle stringByAppendingPathComponent:[NSString stringWithUTF8String:v]];
    dprintf(STDERR_FILENO, "[vulkan] unknown madeira.cfg vulkan = %s (moltenvk, kosmickrisp, off or a .dylib path); "
            "using MoltenVK\n", v);
    return [bundle stringByAppendingPathComponent:@"gl/libMoltenVK.dylib"];
}

/* <dir>\<name> -> <src>. 1 linked, 0 failed. */
static int madeira_link_vulkan_file(NSFileManager *fm, NSString *dir, NSString *name, NSString *src)
{
    NSString *dst = [dir stringByAppendingPathComponent:name];

    [fm removeItemAtPath:dst error:nil];
    return [fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil] ? 1 : 0;
}

static void madeira_setup_vulkan(NSFileManager *fm, NSString *prefix, NSString *bundle, BOOL use_arm64ec)
{
    NSString *win = [prefix stringByAppendingPathComponent:@"drive_c/windows"];
    NSString *stack = [bundle stringByAppendingPathComponent:@"vulkan/arm64ec-windows"];
    NSArray<NSString *> *vulkan_dlls = @[@"winevulkan.dll", @"vulkan-1.dll"];
    NSArray<NSString *> *vkd3d_dlls = @[@"d3d12.dll", @"d3d12core.dll"];
    /* Link names in the prefix; DXVK's files are dxvk-<name> in the vulkan folder. */
    NSArray<NSString *> *dxvk_dlls = @[@"d3d11.dll", @"d3d10core.dll", @"dxgi.dll"];
    NSArray<NSString *> *dirs = use_arm64ec ? @[@"system32", @"sysx64"] : @[@"sysx64"];
    NSString *lib = madeira_vulkan_library(bundle);
    BOOL vkd3d = madeira_d3d12_vkd3d_wanted();
    BOOL dxvk = madeira_d3d11_dxvk_wanted();
    int linked = 0, vkd3d_linked = 0, dxvk_linked = 0;

    /* A previous session's Vulkan links (no farm pass replaces these two). */
    for (NSString *dir in @[@"system32", @"sysx64"])
        for (NSString *dll in vulkan_dlls) {
            NSString *path = [[win stringByAppendingPathComponent:dir] stringByAppendingPathComponent:dll];
            NSString *dest = [fm destinationOfSymbolicLinkAtPath:path error:nil];
            if (dest && [dest rangeOfString:@"/vulkan/arm64ec-windows/"].location != NSNotFound)
                [fm removeItemAtPath:path error:nil];
        }

    if (!lib) {
        unsetenv("MADEIRA_VULKAN_LIBRARY");
        if (vkd3d)
            dprintf(STDERR_FILENO, "[vulkan] d3d12 = vkd3d with vulkan = off: madeira-d3d12 stays this session's D3D12\n");
        if (dxvk)
            dprintf(STDERR_FILENO, "[vulkan] d3d11 = dxvk with vulkan = off: DXMT stays this session's D3D10/11 and DXGI\n");
        return;
    }
    if ((![lib isEqualToString:@"madeira-static-moltenvk"] && access(lib.fileSystemRepresentation, R_OK) != 0) ||
        access([stack stringByAppendingPathComponent:@"winevulkan.dll"].fileSystemRepresentation, R_OK) != 0 ||
        access([stack stringByAppendingPathComponent:@"vulkan-1.dll"].fileSystemRepresentation, R_OK) != 0) {
        unsetenv("MADEIRA_VULKAN_LIBRARY");
        dprintf(STDERR_FILENO, "[vulkan] Vulkan stays off: %s or the bundle's vulkan/arm64ec-windows/{winevulkan,vulkan-1}.dll "
                "is missing%s%s\n", lib.UTF8String, vkd3d ? " (d3d12 = vkd3d ignored: madeira-d3d12 stays)" : "",
                dxvk ? " (d3d11 = dxvk ignored: DXMT stays)" : "");
        return;
    }
    setenv("MADEIRA_VULKAN_LIBRARY", lib.UTF8String, 1);   /* read by build/win32u-unix/vulkan_ios.c */

    for (NSString *dir in dirs)
        for (NSString *dll in vulkan_dlls)
            linked += madeira_link_vulkan_file(fm, [win stringByAppendingPathComponent:dir], dll,
                                               [stack stringByAppendingPathComponent:dll]);
    if (vkd3d) {
        if (access([stack stringByAppendingPathComponent:@"d3d12.dll"].fileSystemRepresentation, R_OK) == 0 &&
            access([stack stringByAppendingPathComponent:@"d3d12core.dll"].fileSystemRepresentation, R_OK) == 0) {
            for (NSString *dir in dirs)
                for (NSString *dll in vkd3d_dlls)
                    vkd3d_linked += madeira_link_vulkan_file(fm, [win stringByAppendingPathComponent:dir], dll,
                                                             [stack stringByAppendingPathComponent:dll]);
        } else {
            dprintf(STDERR_FILENO, "[vulkan] d3d12 = vkd3d, but the bundle has no vulkan/arm64ec-windows/d3d12.dll and "
                    "d3d12core.dll (build/vkd3d-proton/build.sh): madeira-d3d12 stays\n");
        }
    }
    if (dxvk) {
        BOOL have = YES;

        for (NSString *dll in dxvk_dlls)
            if (access([stack stringByAppendingPathComponent:[@"dxvk-" stringByAppendingString:dll]].fileSystemRepresentation,
                       R_OK) != 0)
                have = NO;
        if (have) {
            const char *level;
            char d3d12v[32] = "";
            BOOL d3d12_set = madeira_cfg_get("d3d12", d3d12v, sizeof d3d12v) && d3d12v[0];

            for (NSString *dir in dirs)
                for (NSString *dll in dxvk_dlls)
                    dxvk_linked += madeira_link_vulkan_file(fm, [win stringByAppendingPathComponent:dir], dll,
                                                            [stack stringByAppendingPathComponent:
                                                                [@"dxvk-" stringByAppendingString:dll]]);
            /* Under Wine DXVK logs through __wine_dbg_output (the session log),
             * and writes no log file unless DXVK_LOG_PATH names a folder;
             * overwrite=0 keeps a madeira.cfg env.DXVK_LOG_LEVEL. */
            setenv("DXVK_LOG_LEVEL", "info", 0);
            level = getenv("DXVK_LOG_LEVEL");   /* DXVK's log level (none, error, warn, info, debug, trace); d3d11 = dxvk makes it info unless set */
            dprintf(STDERR_FILENO, "[vulkan] d3d11 = dxvk: DXVK's d3d11.dll, d3d10core.dll and dxgi.dll for this session "
                    "(links %d in %s); D3D12 = %s%s; DXVK_LOG_LEVEL=%s\n", dxvk_linked,
                    use_arm64ec ? "system32 + sysx64" : "sysx64", vkd3d_linked ? "vkd3d-proton" : "madeira-d3d12",
                    vkd3d_linked && !d3d12_set ? " (d3d12 unset: d3d11 = dxvk implies d3d12 = vkd3d)" : "",
                    level ? level : "(unset)");
            if (!vkd3d_linked)
                dprintf(STDERR_FILENO, "[vulkan] d3d11 = dxvk without vkd3d-proton (d3d12 = %s): madeira-d3d12 cannot "
                        "present through DXVK's dxgi, so Direct3D 12 programs get no swapchain this session\n",
                        d3d12_set ? d3d12v : "vkd3d, DLLs missing");
        } else {
            dprintf(STDERR_FILENO, "[vulkan] d3d11 = dxvk, but the bundle has no vulkan/arm64ec-windows/dxvk-d3d11.dll, "
                    "dxvk-d3d10core.dll and dxvk-dxgi.dll (build/dxvk/build.sh): DXMT stays\n");
        }
    }
    dprintf(STDERR_FILENO, "[vulkan] on: MADEIRA_VULKAN_LIBRARY=%s; %d Vulkan DLL links in %s; D3D12 = %s (%d links); "
            "D3D10/11 = %s (%d links)\n",
            lib.UTF8String, linked, use_arm64ec ? "system32 + sysx64" : "sysx64",
            vkd3d_linked ? "vkd3d-proton" : "madeira-d3d12", vkd3d_linked,
            dxvk_linked ? "DXVK" : "DXMT", dxvk_linked);
}

/* ml1275: C:\windows\mono\mono-2.0 -> the bundle's Wine Mono, when the build
 * carries one (the "Bundle Wine Mono" build phase); otherwise the copy Madeira
 * downloaded from WineHQ (WineMono.swift, Library/Application Support/WineMono/
 * wine-mono), as release builds carry none. mscoree looks there first
 * (wine/dlls/mscoree/metahost.c get_mono_path_local) for bin\libmono-2.0-x86.dll
 * in a 32-bit process and bin\libmono-2.0-x86_64.dll in a 64-bit one; without
 * it every .NET Framework program dies with "Wine Mono is not installed".
 * The link names the bundle path, which changes on every reinstall, so it is
 * renewed for every session. A real directory there (Mono installed by hand
 * or by its MSI) is the prefix's own and is left alone. */
static void madeira_link_wine_mono(NSFileManager *fm, NSString *prefix, NSString *bundle)
{
    NSString *source = [bundle stringByAppendingPathComponent:@"wine-mono"];
    NSString *monoDir = [prefix stringByAppendingPathComponent:@"drive_c/windows/mono"];
    if (access([source stringByAppendingPathComponent:@"bin/libmono-2.0-x86.dll"].fileSystemRepresentation, R_OK) != 0)
    {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *downloaded = [support stringByAppendingPathComponent:@"WineMono/wine-mono"];
        if (access([downloaded stringByAppendingPathComponent:@"bin/libmono-2.0-x86.dll"].fileSystemRepresentation, R_OK) == 0)
            source = downloaded;
    }
    NSString *dst = [monoDir stringByAppendingPathComponent:@"mono-2.0"];
    struct stat st;

    if (access([source stringByAppendingPathComponent:@"bin/libmono-2.0-x86.dll"].fileSystemRepresentation, R_OK) != 0)
    {
        /* A link an earlier build with Mono made points into a bundle that is gone. */
        if (lstat(dst.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
            [fm removeItemAtPath:dst error:nil];
        dprintf(STDERR_FILENO, "[wine-mono] ml1275 neither this build nor a download has Wine Mono\n");
        return;
    }
    if (lstat(dst.fileSystemRepresentation, &st) == 0 && !S_ISLNK(st.st_mode))
    {
        dprintf(STDERR_FILENO, "[wine-mono] ml1275 C:\\windows\\mono\\mono-2.0 is the prefix's own copy; the bundled one is not linked\n");
        return;
    }
    [fm createDirectoryAtPath:monoDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dst error:nil];  /* self-heal a stale link on reinstall */
    if ([fm createSymbolicLinkAtPath:dst withDestinationPath:source error:nil])
        dprintf(STDERR_FILENO, "[wine-mono] ml1275 C:\\windows\\mono\\mono-2.0 -> %s wine-mono\n",
                [source hasPrefix:bundle] ? "bundle" : "downloaded");
    else
        dprintf(STDERR_FILENO, "[wine-mono] ml1275 FAILED to link C:\\windows\\mono\\mono-2.0 errno=%d\n", errno);
}

/* Wine Gecko: the MSIs Madeira downloaded (WineGecko.swift, Library/Application
 * Support/WineGecko) go into this prefix's Wine download cache, $HOME/.cache/
 * wine (HOME is the prefix). The first program that needs mshtml then gets
 * Gecko from appwiz.cpl's install_from_cache, which checks the same SHA-256,
 * instead of its "Wine Gecko Installer" download window: the x86 MSI for a
 * 32-bit program, x86_64 for a 64-bit (ARM64EC) one. Renewed every session
 * (the path is per install); a real file there is the prefix's own. */
static void madeira_link_wine_gecko(NSFileManager *fm, NSString *prefix)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *cache = [prefix stringByAppendingPathComponent:@".cache/wine"];
    for (NSString *name in @[ @"wine-gecko-2.47.4-x86.msi", @"wine-gecko-2.47.4-x86_64.msi" ])
    {
        NSString *source = [[support stringByAppendingPathComponent:@"WineGecko"] stringByAppendingPathComponent:name];
        NSString *dst = [cache stringByAppendingPathComponent:name];
        struct stat st;

        if (lstat(dst.fileSystemRepresentation, &st) == 0 && !S_ISLNK(st.st_mode))
            continue;
        if (access(source.fileSystemRepresentation, R_OK) != 0)
        {
            if (lstat(dst.fileSystemRepresentation, &st) == 0)
                [fm removeItemAtPath:dst error:nil];
            dprintf(STDERR_FILENO, "[wine-gecko] %s not downloaded yet; Wine asks for it if a program needs it\n", name.UTF8String);
            continue;
        }
        [fm createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:dst error:nil];
        if ([fm createSymbolicLinkAtPath:dst withDestinationPath:source error:nil])
            dprintf(STDERR_FILENO, "[wine-gecko] Wine's download cache has %s\n", name.UTF8String);
        else
            dprintf(STDERR_FILENO, "[wine-gecko] FAILED to link %s errno=%d\n", name.UTF8String, errno);
    }
}

/* C:\windows\winsxs for 32-bit processes: the x86 side-by-side assemblies Wine
 * ships. Re-seeded every session, because the links name the bundle path.
 *
 * The prefix has no winsxs directory: the template does not carry one and
 * this port never runs wineboot's fake-DLL install, which is what builds it on
 * a normal Wine prefix. Without it no 32-bit program gets a Common-Controls
 * 6.0 activation context (comdlg32 gives up in DllMain with 14001), and a
 * program built with Visual Studio 2005/2008, which carries its CRT as a
 * side-by-side dependency ("Microsoft.VC80.CRT"), fails the activation
 * context for every DLL with the same dependency.
 *
 * This writes what dlls/setupapi/fakedll.c writes for each WINE_MANIFEST
 * assembly in the tree:
 *   windows\winsxs\manifests\<DIR>.manifest
 *   windows\winsxs\<DIR>\<file>          (linked from the i386 farm)
 *   <DIR> = x86_<lower-case name>_<publicKeyToken>_<version>_none_deadbeef
 * with the architecture filled into processorArchitecture, because actctx.c
 * checks the identity in the file against the one in its name. actctx.c pins
 * only major.minor, and accepts any build/revision >= the one requested, so
 * one assembly per major.minor serves every service pack of it.
 *
 * Only the x86 architecture is written: ntdll looks for "x86_" assemblies in
 * a 32-bit process and for "arm64_"/"amd64_" ones in 64-bit processes, so
 * 64-bit processes in the same prefix see no difference. An assembly whose
 * first file is missing from the i386 farm is skipped: a manifest without its
 * DLL would redirect that DLL's loads into an empty directory. */
static void madeira_seed_winsxs_x86(NSFileManager *fm, NSString *prefix, NSString *bundle)
{
    struct sxs_file { const char *in_assembly; const char *in_farm; };
    struct sxs_assembly { const char *name, *lname, *key, *version; struct sxs_file files[4]; };
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
    /* One entry per WINE_MANIFEST resource in the Wine tree (the file the
     * values come from is named on each entry). */
    static const struct sxs_assembly asms[] = {
        /* dlls/comctl32_v6/comctl32.manifest (index 0: gets comctl32_body) */
        { "Microsoft.Windows.Common-Controls", "microsoft.windows.common-controls",
          "6595b64144ccf1df", "6.0.2600.2982", { { "comctl32.dll", "comctl32_v6.dll" } } },
        /* dlls/msvcr80/msvcr80.manifest */
        { "Microsoft.VC80.CRT", "microsoft.vc80.crt", "1fc8b3b9a1e18e3b", "8.0.50727.9672",
          { { "msvcr80.dll", "msvcr80.dll" }, { "msvcp80.dll", "msvcp80.dll" },
            { "msvcm80.dll", "msvcm80.dll" } } },
        /* dlls/msvcr90/msvcr90.manifest */
        { "Microsoft.VC90.CRT", "microsoft.vc90.crt", "1fc8b3b9a1e18e3b", "9.0.30729.6161",
          { { "msvcr90.dll", "msvcr90.dll" }, { "msvcp90.dll", "msvcp90.dll" },
            { "msvcm90.dll", "msvcm90.dll" } } },
        /* dlls/atl80/atl80.manifest */
        { "Microsoft.VC80.ATL", "microsoft.vc80.atl", "1fc8b3b9a1e18e3b", "8.0.50727.4053",
          { { "atl80.dll", "atl80.dll" } } },
        /* dlls/atl90/atl90.manifest */
        { "Microsoft.VC90.ATL", "microsoft.vc90.atl", "1fc8b3b9a1e18e3b", "9.0.30729.6161",
          { { "atl90.dll", "atl90.dll" } } },
        /* dlls/gdiplus/gdiplus.manifest and gdiplus11.manifest: one DLL */
        { "Microsoft.Windows.GdiPlus", "microsoft.windows.gdiplus", "6595b64144ccf1df",
          "1.0.6000.16386", { { "gdiplus.dll", "gdiplus.dll" } } },
        { "Microsoft.Windows.GdiPlus", "microsoft.windows.gdiplus", "6595b64144ccf1df",
          "1.1.7601.23038", { { "gdiplus.dll", "gdiplus.dll" } } },
        /* dlls/msxml3, msxml4 and msxml6 manifests */
        { "Microsoft-Windows-MSXML30", "microsoft-windows-msxml30", "31bf3856ad364e35",
          "6.0.6000.16386", { { "msxml3.dll", "msxml3.dll" } } },
        { "Microsoft.MSXML2", "microsoft.msxml2", "6bd6b9abf345378f", "4.1.0.0",
          { { "msxml4.dll", "msxml4.dll" } } },
        { "Microsoft-Windows-MSXML60", "microsoft-windows-msxml60", "31bf3856ad364e35",
          "6.0.6000.16386", { { "msxml6.dll", "msxml6.dll" } } },
    };
    NSString *winsxs = [prefix stringByAppendingPathComponent:@"drive_c/windows/winsxs"];
    NSString *manifests = [winsxs stringByAppendingPathComponent:@"manifests"];
    NSString *source = [bundle stringByAppendingPathComponent:@"i386-windows"];
    const size_t count = sizeof(asms) / sizeof(asms[0]);
    int seeded = 0, skipped = 0;

    [fm createDirectoryAtPath:manifests withIntermediateDirectories:YES attributes:nil error:nil];
    for (size_t a = 0; a < count; a++)
    {
        const struct sxs_assembly *def = &asms[a];
        const char *body = a == 0 ? comctl32_body : NULL;
        NSString *first = [source stringByAppendingPathComponent:
                           [NSString stringWithUTF8String:def->files[0].in_farm]];
        if (![fm fileExistsAtPath:first])
        {
            dprintf(STDERR_FILENO, "[WineProc] winsxs: x86 %s skipped, i386-windows has no %s\n",
                    def->name, def->files[0].in_farm);
            skipped++;
            continue;
        }
        NSString *dirName = [NSString stringWithFormat:@"x86_%s_%s_%s_none_deadbeef",
                             def->lname, def->key, def->version];
        NSString *asmDir = [winsxs stringByAppendingPathComponent:dirName];
        NSString *manifest = [manifests stringByAppendingPathComponent:
                              [dirName stringByAppendingString:@".manifest"]];
        [fm createDirectoryAtPath:asmDir withIntermediateDirectories:YES attributes:nil error:nil];

        /* Build the manifest and the directory together so the <file> list
         * and the directory cannot disagree: a file missing from the farm is
         * left out of both. UTF-8, LF, no BOM. */
        NSMutableString *text = [NSMutableString stringWithString:
            @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            @"<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\n"];
        [text appendFormat:@"  <assemblyIdentity type=\"win32\" name=\"%s\" version=\"%s\" "
                           @"processorArchitecture=\"x86\" publicKeyToken=\"%s\"/>\n",
                           def->name, def->version, def->key];
        BOOL ok = YES;
        for (size_t f = 0; f < sizeof(def->files) / sizeof(def->files[0]) && def->files[f].in_assembly; f++)
        {
            NSString *src = [source stringByAppendingPathComponent:
                             [NSString stringWithUTF8String:def->files[f].in_farm]];
            NSString *link = [asmDir stringByAppendingPathComponent:
                              [NSString stringWithUTF8String:def->files[f].in_assembly]];
            [fm removeItemAtPath:link error:nil];  /* the bundle path changes on reinstall */
            if (![fm fileExistsAtPath:src]) continue;
            if (![fm createSymbolicLinkAtPath:link withDestinationPath:src error:nil]) { ok = NO; break; }
            if (body)
                [text appendFormat:@"  <file name=\"%s\">\n%s  </file>\n", def->files[f].in_assembly, body];
            else
                [text appendFormat:@"  <file name=\"%s\"/>\n", def->files[f].in_assembly];
        }
        [text appendString:@"</assembly>\n"];
        if (!ok || ![[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:manifest atomically:YES])
        {
            dprintf(STDERR_FILENO, "[WineProc] winsxs: x86 %s FAILED\n", def->name);
            skipped++;
            continue;
        }
        seeded++;
    }
    dprintf(STDERR_FILENO, "[WineProc] winsxs: %d/%zu x86 assemblies seeded, %d skipped\n",
            seeded, count, skipped);
}

/* FEX's WOW64 module cannot call sysctl, and without an answer it assumes the
 * newest cores' feature set. A wrong "present" is silent corruption, not a
 * crash (FEAT_AFP claimed on a core without it leaves FPCR.NEP RES0, so every
 * scalar SSE operation zeroes the upper lanes of its destination), so the app
 * asks and passes the answers in FEX_MADEIRA_HOSTPROBE, for every session.
 * Both FEX modules read it (FEX Source/Windows/Common/CPUFeatures.cpp): an
 * explicit 0 turns a feature off. The 64-bit module ignoring it made A12/A13
 * devices, which lack FlagM/FlagM2, stop 64-bit games with 0xC000001D. The
 * ARM64EC module also takes LRCPC2 and AFP from it (ml1231). "?" means the
 * sysctl does not exist and keeps FEX's assumption. */
static void madeira_publish_host_probe(void)
{
    static const struct { const char *key, *sysctl; } probes[] = {
        { "AFP",     "hw.optional.arm.FEAT_AFP" },
        { "FLAGM",   "hw.optional.arm.FEAT_FlagM" },
        { "FLAGM2",  "hw.optional.arm.FEAT_FlagM2" },
        { "FCMA",    "hw.optional.arm.FEAT_FCMA" },
        { "RCPC",    "hw.optional.arm.FEAT_LRCPC" },
        { "LRCPC2",  "hw.optional.arm.FEAT_LRCPC2" },   /* ml1231: the ARM64EC module needs an explicit 1 */
        { "AES",     "hw.optional.arm.FEAT_AES" },
        { "PMULL",   "hw.optional.arm.FEAT_PMULL" },
        { "SHA",     "hw.optional.arm.FEAT_SHA256" },
        { "CRC",     "hw.optional.armv8_crc32" },
        { "ATOMICS", "hw.optional.arm.FEAT_LSE" },
        /* madeira-bcd: reported, not yet used by either module: which of FEX's other
         * host features this device has (FRINTTS, CSSC, RPRES, MOPS, ECV, WFXT), and
         * LSE2/LRCPC3 for its TSO code (which unaligned atomics trap; vector imm9). */
        { "LSE2",    "hw.optional.arm.FEAT_LSE2" },
        { "LRCPC3",  "hw.optional.arm.FEAT_LRCPC3" },
        { "FRINTTS", "hw.optional.arm.FEAT_FRINTTS" },
        { "RPRES",   "hw.optional.arm.FEAT_RPRES" },
        { "CSSC",    "hw.optional.arm.FEAT_CSSC" },
        { "MOPS",    "hw.optional.arm.FEAT_MOPS" },
        { "ECV",     "hw.optional.arm.FEAT_ECV" },
        { "WFXT",    "hw.optional.arm.FEAT_WFxT" },
    };
    char buf[256];
    size_t len = 0;

    buf[0] = 0;
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++)
    {
        int32_t v = 0;
        size_t sz = sizeof(v);
        const char *val = sysctlbyname(probes[i].sysctl, &v, &sz, NULL, 0) == 0 ? (v ? "1" : "0") : "?";
        len += snprintf(buf + len, sizeof(buf) - len, "%s%s=%s", i ? "," : "", probes[i].key, val);
        if (len >= sizeof(buf)) return;
    }
    setenv("FEX_MADEIRA_HOSTPROBE", buf, 1);
    dprintf(STDERR_FILENO, "[WineProc] FEX host feature probe: %s\n", buf);
}

/* Decode Windows argument quoting before Wine rebuilds its command line from
 * argv. Based on Wine's CommandLineToArgvW non-executable argument rules:
 * backslashes escape quotes only when immediately followed by a quote.
 * Never silently discard arguments or truncate the caller's command. */
static int madeira_split_launch_args(const char *input, char *storage, size_t storage_capacity,
                                     char **argv_out, size_t argv_capacity) {
    const char *s = input ? input : "";
    char *d = storage;
    size_t length, argc = 0;
    if (!storage || !storage_capacity || (!argv_out && argv_capacity)) return -1;
    length = strnlen(s, storage_capacity);
    if (length >= storage_capacity) return -1;
    for (size_t i = 0; i < length; i++)
        if (((unsigned char)s[i] < 32 && s[i] != '\t') || (unsigned char)s[i] == 127) return -1;
    while (*s) {
        unsigned int quotes = 0, backslashes = 0;
        while (*s == ' ' || *s == '\t') s++;
        if (!*s) break;
        if (argc == argv_capacity) return -2;
        argv_out[argc++] = d;
        while (*s && !((*s == ' ' || *s == '\t') && !quotes)) {
            if (*s == '\\') {
                *d++ = *s++;
                backslashes++;
            } else if (*s == '"') {
                if (!(backslashes & 1)) {
                    d -= backslashes / 2;
                    if (quotes && s[1] == '"') { *d++ = '"'; s++; }
                    else quotes = !quotes;
                } else {
                    d -= backslashes / 2 + 1;
                    *d++ = '"';
                }
                s++;
                backslashes = 0;
            } else {
                *d++ = *s++;
                backslashes = 0;
            }
        }
        if (quotes) return -1;
        *d++ = 0;
    }
    return (int)argc;
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
                /* fixme-d3dcompiler: Wine's shader reflection prints one
                 * skip_u32_unknown line per unknown RDEF dword. Metro 2033
                 * Redux reflects every shader at load: ~90,000 of a
                 * 105,000-line log in six seconds, all of it parsed by LogStore. */
                setenv("WINEDEBUG", "err+all,err-virtual,fixme-d3dcompiler", 1);
                LOG("WINEDEBUG = err+all,err-virtual,fixme-d3dcompiler (perf default — set MADEIRA_DEBUG_VERBOSE=1 for full trace)");
            }
        }

        // Phase 3D investigation: re-enabled. Investigation C concluded
        // wineserver dispatch is fine; the `ws_log drops at high rate`
        // artifact was the prior false signal. Now chasing a real bug:
        // get_desktop_window's returned HWND fails get_user_object lookup
        // when create_window receives it as req->parent.
        setenv("MADEIRA_WIN32U", "1", 1);
        madeira_export_image_uuid();

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

        /* OpenGL backend for the winios GL driver (build/win32u-unix/opengl_ios.c):
         *   zink - desktop OpenGL 3.3-4.x: Mesa OSMesa + Zink on MoltenVK, from the
         *          bundle's gl/ folder (build/mesa-ios, build/moltenvk-ios)
         *   gles - Apple's OpenGL ES 3.0 (EAGL); desktop-GL-only apps fail
         * madeira.cfg `gl-backend = zink|gles` chooses; otherwise zink when its
         * dylibs are bundled. MADEIRA_GL_BACKEND in the environment wins over both.
         * The driver falls back to gles by itself if Zink cannot start. */
        {
            NSString *glDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"gl"];
            BOOL haveZink = [[NSFileManager defaultManager] fileExistsAtPath:
                                [glDir stringByAppendingPathComponent:@"libOSMesa.dylib"]];
            char glb[16] = "";
            if (!madeira_cfg_get("gl-backend", glb, sizeof glb) || !glb[0])
                strlcpy(glb, haveZink ? "zink" : "gles", sizeof glb);
            setenv("MADEIRA_GL_BACKEND", glb, 0);
            setenv("MADEIRA_GL_DIR", glDir.UTF8String, 1);
            LOG("OpenGL backend: %{public}s (zink bundled: %d)", getenv("MADEIRA_GL_BACKEND"), haveZink);

            /* With the GLES backend there is no desktop GL context, so make LOVE ask
             * for OpenGL ES first. LOVE 11 checks this SDL hint (read from the
             * environment) before trying desktop GL; SDL then creates the context
             * through WGL_EXT_create_context_es2_profile, which that backend
             * advertises. overwrite=0: an explicit setting still wins. */
            if (!strcmp(getenv("MADEIRA_GL_BACKEND"), "gles"))
                setenv("LOVE_GRAPHICS_USE_OPENGLES", "1", 0);
        }

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
            /* A shared-mode client that keeps only one 10 ms engine period queued
             * (IAudioClient3 low latency) loses audio when RemoteIO pulls a larger
             * slice per callback (iOS's default is ~1024 frames, 21 ms): every
             * callback empties the queue and plays silence for the rest. Ask for a
             * 5 ms slice; the driver reports an engine period of at least two
             * slices (MADEIRA_AUDIO_IO_US, audio_null_ios.c). MADEIRA_AUDIO_IO_MS
             * sets the slice; 0 keeps the system's. */
            {
                const char *io = getenv("MADEIRA_AUDIO_IO_MS");
                double ms = io && *io ? atof(io) : 5.0;
                if (ms > 0 && ![session setPreferredIOBufferDuration:ms / 1000.0 error:&aerr])
                    LOG("AVAudioSession setPreferredIOBufferDuration(%.1fms) failed: %{public}s",
                        ms, aerr.localizedDescription.UTF8String);
                aerr = nil;
            }
            [session setActive:YES error:&aerr];
            if (aerr) LOG("AVAudioSession setActive failed: %{public}s",
                          aerr.localizedDescription.UTF8String);
            else LOG("AVAudioSession active: rate=%.0f latency=%.1fms io-buffer=%.2fms",
                     session.sampleRate, session.outputLatency * 1000.0, session.IOBufferDuration * 1000.0);
            char io_us[32];
            snprintf(io_us, sizeof io_us, "%lld", (long long)(session.IOBufferDuration * 1e6));
            setenv("MADEIRA_AUDIO_IO_US", io_us, 1);
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
         * title the desktop will start later, so a conditional here cannot work.
         *
         * A Madeira Dock session is the one launch that can know: it runs Valve's
         * client inside the host process, and the client gives every game it
         * starts that game's own identity. The fixed identity above reached the
         * client and the game (both inherit this environment), so a Dock launch
         * publishes none of the three. ContentView sets MADEIRA_DOCK_SESSION=1 for
         * a Dock launch only and clears it for every other launch, which keeps
         * the fixed identity exactly as before.
         *
         * A Steam game the library starts as its own program ("Start with: The
         * game", LibraryEntry.configureLaunch) knows its title too. It passes that
         * game's App ID and install folder in MADEIRA_STEAM_APPID / MADEIRA_STEAM_APPPATH,
         * and this launch publishes the game's own identity instead of the fixed one. Both
         * are cleared here, so no later launch inherits them.
         *
         * ml2310: a game from another store (an Epic library entry) is not a Steam game
         * either. The library sets MADEIRA_NO_STEAM_IDENTITY=1 for its launch: with the
         * fixed identity its launcher took its Steam path, the Steam API start failed and
         * it showed only an error. */
        const char *dock_session = getenv("MADEIRA_DOCK_SESSION");
        const char *direct_app = getenv("MADEIRA_STEAM_APPID");    /* set by the library for one direct Steam start (Start with: The game); not a setting */
        const char *direct_path = getenv("MADEIRA_STEAM_APPPATH"); /* that game's install folder, with MADEIRA_STEAM_APPID; not a setting */
        const char *no_steam_id = getenv("MADEIRA_NO_STEAM_IDENTITY"); /* set by the library for one launch of a game from another store; not a setting */
        if (dock_session && dock_session[0] == '1') {
            unsetenv("SteamAppPath");
            unsetenv("SteamGameId");
            unsetenv("SteamAppId");
            dprintf(STDERR_FILENO, "[steam-env] Madeira Dock session: no fixed Steam game identity published\n");
        } else if (no_steam_id && no_steam_id[0] == '1') {
            unsetenv("SteamAppPath");
            unsetenv("SteamGameId");
            unsetenv("SteamAppId");
            dprintf(STDERR_FILENO, "[steam-env] a game from another store: no Steam game identity published\n");
        } else if (direct_app && direct_app[0] && strlen(direct_app) <= 10 &&
            strspn(direct_app, "0123456789") == strlen(direct_app) &&
            direct_path && (direct_path[0] == 'C' || direct_path[0] == 'c') && direct_path[1] == ':' &&
            direct_path[2] == '\\' && strlen(direct_path) < 1024 && !strstr(direct_path, "..")) {
            setenv("SteamAppPath", direct_path, 1);
            setenv("SteamGameId", direct_app, 1);
            setenv("SteamAppId",  direct_app, 1);
            dprintf(STDERR_FILENO, "[steam-start] direct start: the game's own Steam identity (app %s) published\n", direct_app);
        } else {
            setenv("SteamAppPath", "C:\\Program Files\\Thumper", 1);
            setenv("SteamGameId", "356400", 1);
            setenv("SteamAppId",  "356400", 1);
        }
        unsetenv("MADEIRA_STEAM_APPID");
        unsetenv("MADEIRA_STEAM_APPPATH");
        unsetenv("MADEIRA_NO_STEAM_IDENTITY");

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
            /* a game session starts with no game-mode overlay windows and
             * no known Metal windows (Winios.m) */
            { extern void winios_session_reset(void); winios_session_reset(); }
            LOG("Wine log file: %{public}s", logPath.UTF8String);
            /* Expose the app Documents dir to Wine code (e.g. for fex-jit-dump.bin) */
            setenv("MADEIRA_DOCS_DIR", docs.UTF8String, 1);
            dprintf(STDERR_FILENO, "[config-dir] early MADEIRA_DOCS_DIR=%s; native madeira.cfg readers that run "
                    "before this point (wineserver start: madsync inproc-sync) use it (MADEIRA_CFG_EARLY_DOCS=0 disables)\n",
                    g_madeira_docs_early);

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
                long onlyPoolMB = capMB >= 64 ? 0 : (long)madeira_cfg_int("donor-pool-mb", 0);
                unsetenv("MADEIRA_SWAP_DONOR_ONLY");
                if (onlyPoolMB >= 512 && madeira_cfg_int("donor-only", 1)) {   /* madeira.cfg donor-only = 0: donor-pool-mb without swap-mb does nothing, as before ml2200 */
                    /* ml2200: donor RAM without the swap file. The tier maps only the pool
                     * (virtual_ios.c ios_swap_init); no file is created. */
                    unsetenv("MADEIRA_SWAP_FILE");
                    unsetenv("MADEIRA_SWAP_MB");
                    setenv("MADEIRA_SWAP_DONOR_ONLY", "1", 1);
                    char poolKind[32] = "";
                    madeira_cfg_get("donor-pool-kind", poolKind, sizeof poolKind);
                    extern long MadeiraDonorPoolStart(long megabytes, int purgeable);
                    long got = MadeiraDonorPoolStart(onlyPoolMB, strcmp(poolKind, "purgeable") == 0);
                    LOG("ml2200 donor-only tier: %ld of %ld MB (%s), no swap file", got, onlyPoolMB, poolKind[0] ? poolKind : "ledger");
                    fprintf(stderr, "[swap] ml2200 app: donor pool %ld of %ld MB without a swap file (swap-mb unset)\n", got, onlyPoolMB);
                }
                if (capMB >= 64) {
                    NSString *swapPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"madeira-swap.bin"];
                    [[NSFileManager defaultManager] removeItemAtPath:swapPath error:nil];
                    if ([[NSFileManager defaultManager] createFileAtPath:swapPath contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionNone}]) {
                        setenv("MADEIRA_SWAP_FILE", swapPath.UTF8String, 1);
                        setenv("MADEIRA_SWAP_MB", [NSString stringWithFormat:@"%ld", capMB].UTF8String, 1);
                        /* madeira-bcd: swap-min-kb (madeira.cfg or the game's config) lowers
                         * the tier's 8 MB eligibility floor. Upstream's virtual_ios.c reads
                         * MADEIRA_SWAP_MIN_KB only in its "blocks" coverage, so swap-min-kb
                         * selects that; an env.MADEIRA_SWAP_COVERAGE line, exported below,
                         * still wins. */
                        long minKB = (long)madeira_cfg_int("swap-min-kb", 0);
                        if (minKB > 0) {
                            setenv("MADEIRA_SWAP_MIN_KB", [NSString stringWithFormat:@"%ld", minKB].UTF8String, 1);
                            setenv("MADEIRA_SWAP_COVERAGE", "blocks", 1);
                            fprintf(stderr, "[swap] app: commits from %ld KB are eligible (swap-min-kb, coverage=blocks)\n", minKB);
                        } else {
                            unsetenv("MADEIRA_SWAP_MIN_KB");
                            unsetenv("MADEIRA_SWAP_COVERAGE");
                        }
                        LOG("ml1077 swap tier armed: %{public}s, %ld MB", swapPath.UTF8String, capMB);
                        fprintf(stderr, "[swap] ml1077 app: backing file %s, cap %ld MB\n", swapPath.UTF8String, capMB);
                        /* ml1150: donor pool, the tier's first stage (DonorPool.m). donor-pool-kind = ledger (default) |
                         * purgeable chooses how the extension creates the memory (the A/B of ml1152). */
                        long poolMB = (long)madeira_cfg_int("donor-pool-mb", 0);   /* madeira.cfg donor-pool-mb = N */
                        if (poolMB >= 512) {
                            char poolKind[32] = "";
                            madeira_cfg_get("donor-pool-kind", poolKind, sizeof poolKind);   /* madeira.cfg donor-pool-kind = ledger | purgeable */
                            extern long MadeiraDonorPoolStart(long megabytes, int purgeable);
                            long got = MadeiraDonorPoolStart(poolMB, strcmp(poolKind, "purgeable") == 0);
                            LOG("ml1150 donor pool: %ld of %ld MB (%s)", got, poolMB, poolKind[0] ? poolKind : "ledger");
                        }
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
                /* iOS-Madeira ml1184: a library game's own settings (LibraryEntry.applyEnvironment,
                 * which ran before this on the launch worker) win over the same key in
                 * madeira.cfg, as its details page says; the cfg line used to replace them
                 * (env.MADEIRA_FASTSYNC = auto undid "Fast synchronization: off"). Which of
                 * them the game set is noted before the first cfg line is exported: madeira.cfg
                 * is last-line-wins, and a later line for the same key must still replace an
                 * earlier one instead of being taken for the game's own setting. Every key
                 * applyEnvironment exports belongs here (check-frontend). The game's own
                 * config lines ($MADEIRA_CFG_GAME, below) come after and win over both. */
                static const char *const per_launch[] = {
                    "MADEIRA_DESKTOP",          /* the game's Directly / In the Wine desktop choice */
                    "MADEIRA_FASTSYNC", "MADEIRA_FASTSYNC_SEM", "MADEIRA_CPU_COUNT", "DXMT_D9_ANISO_LIMIT",
                    "FEX_X87REDUCEDPRECISION",   /* ml1184: the game's "Reduced-precision x87" */
                    "MADEIRA_DINPUT_PAD",        /* ml1240: the game's "XInput and DirectInput" */
                    "MADEIRA_FEX_AVX",           /* ml1184: the game's "AVX and AVX2" */
                    "MADEIRA_FRAMEGEN",          /* ml1184: the game's "Frame generation" */
                    "DXMT_ENABLE_NVEXT", "DXMT_WSI_MONITOR_IDENTITY", "DXMT_WSI_MODE_TABLE",   /* the game's "Report an NVIDIA GPU" */
                };
                enum { per_launch_count = sizeof(per_launch) / sizeof(per_launch[0]) };
                BOOL game_set[per_launch_count];
                for (size_t i = 0; i < per_launch_count; i++) game_set[i] = getenv(per_launch[i]) != NULL;
                for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSRange eq = [line rangeOfString:@"="];
                    if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound || eq.location == 0) continue;
                    NSString *k = [line substringToIndex:eq.location], *v = [line substringFromIndex:eq.location + 1];
                    BOOL kept = NO;
                    for (size_t i = 0; i < per_launch_count; i++)
                        if (game_set[i] && !strcmp(k.UTF8String, per_launch[i])) kept = YES;
                    if (kept) {
                        fprintf(stderr, "[madeira-env] ml1184 %s=%s kept (the game's own setting); madeira.cfg's %s ignored\n",
                                k.UTF8String, getenv(k.UTF8String), v.UTF8String);
                        continue;
                    }
                    if (madeira_env_is_locked(k.UTF8String)) {
                        fprintf(stderr, "[madeira-env] %s is set by the app; "
                                "the config value is ignored\n", k.UTF8String);
                        continue;
                    }
                    setenv(k.UTF8String, v.UTF8String, 1);
                    LOG("madeira.cfg env: %{public}s=%{public}s", k.UTF8String, v.UTF8String);
                    fprintf(stderr, "[madeira-env] ml1062 %s=%s\n", k.UTF8String, v.UTF8String);
                }
                /* The game's own lines ($MADEIRA_CFG_GAME): madeira-bcd's per-game file
                 * (GameProfiles.swift, Application Support/GameConfigs), or the
                 * library entry's lines LibraryEntry.applyEnvironment writes
                 * (MadeiraConfig.applyGame merges the two). Its env.NAME lines come
                 * after madeira.cfg's and win, the rule madeira_cfg_get applies to keys. */
                const char *gameCfg = getenv("MADEIRA_CFG_GAME");
                NSString *gameText = (gameCfg && *gameCfg)
                    ? [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:gameCfg] encoding:NSUTF8StringEncoding error:nil]
                    : nil;
                for (NSString *raw in [gameText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                    NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSRange eq = [line rangeOfString:@"="];
                    if (![line hasPrefix:@"env."] || eq.location == NSNotFound) continue;
                    NSString *k = [[line substringWithRange:NSMakeRange(4, eq.location - 4)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!k.length) continue;
                    if (madeira_env_is_locked(k.UTF8String)) {
                        fprintf(stderr, "[madeira-env] %s is set by the app; "
                                "the config value is ignored\n", k.UTF8String);
                        continue;
                    }
                    setenv(k.UTF8String, v.UTF8String, 1);
                    LOG("game config env: %{public}s=%{public}s", k.UTF8String, v.UTF8String);
                    fprintf(stderr, "[madeira-env] game %s=%s\n", k.UTF8String, v.UTF8String);
                }
                {   /* madeira-bcd: the server's per-launch switches (fd_ios.c, request_ios.c) */
                    const char *ef = getenv("MADEIRA_SRV_ECO_FOLLOW");   /* 1: the server thread runs at utility QoS while ECO is on */
                    const char *dr = getenv("MADEIRA_SRV_DIRECT");       /* 1 or 2: listed requests run on the calling thread */
                    const char *iu = getenv("MADEIRA_SRV_IDLE_US");      /* the server loop's longest sleep, us (default 1000) */
                    const char *la = getenv("MADEIRA_SRV_LOG_ALL");      /* 1: every per-descriptor server log line, as before */
                    int idle = iu && *iu ? atoi(iu) : 0;
                    g_madeira_srv_idle_us = idle > 0 ? idle : 0;
                    g_madeira_srv_log_all = (la && la[0] == '1') ? 1 : 0;
                    g_madeira_srv_eco_follow = (ef && ef[0] == '1') ? 1 : 0;
                    g_madeira_srv_direct = (dr && (dr[0] == '1' || dr[0] == '2') && !dr[1]) ? dr[0] - '0' : 0;
                    if (g_madeira_srv_eco_follow || g_madeira_srv_direct || g_madeira_srv_idle_us || g_madeira_srv_log_all)
                        fprintf(stderr, "[madeira-env] server switches: MADEIRA_SRV_ECO_FOLLOW=%d MADEIRA_SRV_DIRECT=%d "
                                "MADEIRA_SRV_IDLE_US=%d MADEIRA_SRV_LOG_ALL=%d\n", g_madeira_srv_eco_follow,
                                g_madeira_srv_direct, g_madeira_srv_idle_us, g_madeira_srv_log_all);
                }
                /* Fastsync is the default sync engine: with neither inproc-sync nor
                 * env.MADEIRA_FASTSYNC in madeira.cfg, Wine gets MADEIRA_FASTSYNC=auto,
                 * the value Settings > Sync engine > Fastsync writes. Never overrides a
                 * value already set (a game's own fastsync switch sets 0). */
                if (madeira_cfg_sync_engine() == MADEIRA_SYNC_FASTSYNC && !getenv("MADEIRA_FASTSYNC")) {
                    setenv("MADEIRA_FASTSYNC", "auto", 0);
                    fprintf(stderr, "[madeira-env] sync engine: fastsync (default), MADEIRA_FASTSYNC=auto\n");
                }
                {   /* madeira-bcd: for the wineserver (g_madeira_srv_fgetpath) */
                    const char *fp = getenv("MADEIRA_SRV_FGETPATH");
                    g_madeira_srv_fgetpath = (fp && fp[0] == '1') ? 1 : 0;
                    if (g_madeira_srv_fgetpath)
                        fprintf(stderr, "[madeira-env] MADEIRA_SRV_FGETPATH=1: the server names the files it opens with F_GETPATH\n");
                }
                /* DXMT's shader caches persist for 64-bit games too: winemetal's
                 * DXMT_IOS_CACHE_DIR defaults on only for a WoW64 caller, and the
                 * upstream lookup a 64-bit caller keeps finds no cache directory in
                 * the iOS sandbox, so every converted shader and Metal pipeline was
                 * built again in each session (Rocket League stalled up to 327 ms on
                 * goal explosions and replays). Never overrides a value already set
                 * (env.DXMT_IOS_CACHE_DIR = 0 in madeira.cfg turns it off). */
                if (!getenv("DXMT_IOS_CACHE_DIR")) {
                    setenv("DXMT_IOS_CACHE_DIR", "1", 0);
                    fprintf(stderr, "[madeira-env] DXMT_IOS_CACHE_DIR=1 (default: shader caches under Library/Caches)\n");
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

        /* madeira-stdout-pipe: hand the guest's stdout to a pipe, and leave
         * stderr on the log.
         *
         * The split is the one the code already has: Wine's err:/warn: channels
         * and every dprintf(STDERR_FILENO, ...) go to stderr, the guest's printf
         * goes to stdout. Separating the file descriptors separates program
         * output from runtime narration by the kernel rather than by matching
         * line prefixes after the fact -- which is the only way a terminal can
         * interpret an escape sequence that a telemetry line would otherwise
         * land in the middle of.
         *
         * Opt-in, because an unread pipe fills at 64 KB and blocks the guest
         * forever on its next write. The reader creates the flag file. */
        {
            NSString *docs3 = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            /* env.MADEIRA_STDOUT_PIPE = 1 moves the guest's stdout onto its
             * own pipe, leaving fd 2 on madeira-log.txt. That is the seam the
             * code already had: Wine's err:/warn: channels and every
             * dprintf(STDERR_FILENO, ...) are stderr, the guest's printf is
             * stdout. Off by default for the same reason as the stdin half --
             * an unread pipe fills at 64 KB and blocks the guest -- so only a
             * front end that drains it should ask. Documents/madeira-stdout.txt
             * still works. */
            NSString *flag = [docs3 stringByAppendingPathComponent:@"madeira-stdout.txt"];
            const char *stdout_opt = getenv( "MADEIRA_STDOUT_PIPE" );
            if ([[NSFileManager defaultManager] fileExistsAtPath:flag] ||
                (stdout_opt && stdout_opt[0] == '1')) {
                int fds[2];
                if (pipe(fds) != 0) {
                    dprintf(STDERR_FILENO, "[stdout-pipe] pipe() failed errno=%d\n", errno);
                } else {
                    dup2(fds[1], STDOUT_FILENO);
                    if (fds[1] != STDOUT_FILENO) close(fds[1]);
                    /* Non-blocking: the reader polls and must not stall while
                     * the guest is quiet. */
                    fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK);
                    madeira_stdout_master = fds[0];
                    dprintf(STDERR_FILENO,
                            "[stdout-pipe] guest stdout is a pipe, read end=%d\n", fds[0]);
                }
            }
        }

        // ---- Optional pipe on fd 0, and optional forced console ----
        // Both opt-in via Documents files; absent, nothing here runs
        // and fd 0 stays whatever iOS gave us (which the 2026-09-16 probe
        // showed reads as immediate EOF).
        //
        // A pipe, not a pty: posix_openpt is EPERM under the iOS sandbox. It
        // turns out not to matter -- Wine's is_tty_handle() is a pointer-tag
        // test, not a tty test, so a tagged pipe reaches conhost the same way.
        {
            /* env.MADEIRA_STDIN_PIPE = 1 puts a pipe on fd 0 so a guest can
             * read stdin at all; without it fd 0 is whatever iOS gave us,
             * which reads as immediate EOF. Off by default: an unread pipe
             * fills at 64 KB and blocks the guest on its next write, so only a
             * front end that drains it should ask for one.
             * Documents/madeira-stdin.txt still works and additionally seeds
             * the pipe with its contents, which is how a probe supplies canned
             * input with no front end at all. */
            NSString *docs2 = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSData *seed = [NSData dataWithContentsOfFile:
                            [docs2 stringByAppendingPathComponent:@"madeira-stdin.txt"]];
            const char *stdin_opt = getenv( "MADEIRA_STDIN_PIPE" );
            if (seed || (stdin_opt && stdin_opt[0] == '1')) {
                int fds[2];
                if (pipe(fds) != 0) {
                    dprintf(STDERR_FILENO, "[stdin-pipe] pipe() failed errno=%d\n", errno);
                } else {
                    dup2(fds[0], STDIN_FILENO);
                    if (fds[0] != STDIN_FILENO) close(fds[0]);
                    madeira_stdin_master = fds[1];
                    dprintf(STDERR_FILENO,
                            "[stdin-pipe] fd 0 is a pipe, isatty=%d, write end=%d\n",
                            isatty(STDIN_FILENO), fds[1]);
                    // Non-blocking write end. XNU pipes start at 16KB and only
                    // grow toward 64KB opportunistically, and nothing bounds the
                    // size of madeira-stdin.txt -- a blocking write with no
                    // reader yet would hang the Wine thread before __wine_main,
                    // with the last log line being the one above.
                    int fl = fcntl(fds[1], F_GETFL, 0);
                    if (fl != -1) fcntl(fds[1], F_SETFL, fl | O_NONBLOCK);
                    if (seed && seed.length) {
                        ssize_t w = write(fds[1], seed.bytes, seed.length);
                        if (w < 0) {
                            dprintf(STDERR_FILENO, "[stdin-pipe] seed write failed errno=%d\n", errno);
                        } else if ((unsigned long)w < seed.length) {
                            dprintf(STDERR_FILENO,
                                    "[stdin-pipe] WARNING seed TRUNCATED: %zd of %lu bytes -- "
                                    "the pipe buffer is full and nothing has read yet\n",
                                    w, (unsigned long)seed.length);
                        } else {
                            dprintf(STDERR_FILENO, "[stdin-pipe] seeded %zd bytes\n", w);
                        }
                    }
                }
            }

            // Separate knob: ask the guest to build a console anyway. Read here
            // rather than in ContentView because this runs in the same process
            // before __wine_main, so setenv is visible to env_ios.c.
            if ([[NSFileManager defaultManager] fileExistsAtPath:
                 [docs2 stringByAppendingPathComponent:@"madeira-console.txt"]]) {
                setenv("MADEIRA_FORCE_CONSOLE", "1", 1);
                dprintf(STDERR_FILENO,
                        "[force-console] MADEIRA_FORCE_CONSOLE=1 via madeira-console.txt\n");
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

        /* WoW64: a 32-bit (i386) target, from the PE header on disk rather
         * than the name. Its 64-bit half runs on the plain aarch64 core (the
         * unix loader resolves aarch64-windows for a process whose main image
         * is i386), whatever the heuristic above chose. Any other target
         * keeps the heuristic's answer unchanged. */
        NSString *bundleForProbe = [[NSBundle mainBundle] bundlePath];
        const BOOL has_i386_set = madeira_bundle_has_i386(bundleForProbe);
        const uint16_t target_machine = madeira_target_machine(madeira_exe, g_prefix_path, bundleForProbe);
        const BOOL is_i386_target = has_i386_set && target_machine == MADEIRA_IMAGE_FILE_MACHINE_I386;
        dprintf(STDERR_FILENO, "[WineProc] PE probe: machine=0x%x%s\n", target_machine,
                is_i386_target ? " (i386: WoW64)" :
                target_machine == MADEIRA_IMAGE_FILE_MACHINE_I386 ? " (i386, but the bundle has no i386-windows)" : "");
        const BOOL use_arm64ec = madeira_use_arm64ec_for_target(madeira_exe, force_ec,
                                                               target_machine, has_i386_set);
        dprintf(STDERR_FILENO, "[WineProc] PE routing: machine=0x%04x bundle=%s i386-set=%d force-ec=%d\n",
                target_machine, use_arm64ec ? "arm64ec-windows" : "aarch64-windows",
                has_i386_set, force_ec && *force_ec == '1');
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
            madeira_link_wbem(fm, prefix, @"system32", dllSource);

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

            /* WoW64: the i386 farm, syswow64\wbem and the x86 side-by-side
             * store for every session once the bundle has it (docs/WOW64.md).
             * The store was seeded for a 32-bit target only, but a 64-bit
             * target (a launcher, the Dock host) starts 32-bit children too,
             * and their activation contexts redirect comctl32 and the VC80/
             * VC90 CRT into the store. Its links name the bundle path, which
             * changes on every reinstall: a session with a 64-bit target after
             * a reinstall left them dangling, and such a child died in the
             * loader with c0000135 for DLLs syswow64 still had. */
            if (has_i386_set) {
                madeira_link_syswow64(fm, prefix, bundlePath);
                madeira_link_syswow64_wbem(fm, prefix, bundlePath);
                madeira_seed_winsxs_x86(fm, prefix, bundlePath);
                madeira_overlay_vcruntime32(fm, prefix);   /* VCRedist.swift's Microsoft x86 runtime */
            }
            madeira_link_wine_mono(fm, prefix, bundlePath);
            madeira_link_wine_gecko(fm, prefix);
            if (madeira_d3d9_wined3d_wanted())
                madeira_link_d3d9_wined3d(fm, prefix, bundlePath, has_i386_set);
            madeira_setup_vulkan(fm, prefix, bundlePath, use_arm64ec);

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

            /* madeira-bcd: the same folders for the user Wine actually runs as.
             * ml719 covers C:\users\madeira (the template's user), but Wine
             * names the profile after the unix user -- "mobile" on iOS -- so
             * %USERPROFILE% is C:\users\mobile, where Documents may be
             * missing or a dangling link. Ghost of Tsushima then stops with
             * "Unable to create the game's save folder" before touching the
             * filesystem. Make every folder games write to a real directory
             * (Saved Games and AppData too), for both names. */
            {
                NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSetWithObject:@"madeira"];
                struct passwd *pw = getpwuid(getuid());
                if (pw && pw->pw_name && pw->pw_name[0]) [names addObject:@(pw->pw_name)];
                const char *envUser = getenv("USER");
                if (envUser && envUser[0]) [names addObject:@(envUser)];
                NSArray *rels = @[ @"Documents", @"Desktop", @"Downloads", @"Music", @"Pictures",
                                   @"Videos", @"Saved Games", @"AppData/Local", @"AppData/LocalLow",
                                   @"AppData/Roaming" ];
                int made = 0;
                for (NSString *name in names) {
                    NSString *home = [prefix stringByAppendingPathComponent:
                        [@"drive_c/users" stringByAppendingPathComponent:name]];
                    for (NSString *rel in rels) {
                        NSString *path = [home stringByAppendingPathComponent:rel];
                        const char *cp = path.fileSystemRepresentation;
                        struct stat lst, tgt;
                        if (lstat(cp, &lst) == 0) {
                            if (!S_ISLNK(lst.st_mode) || stat(cp, &tgt) == 0) continue;
                            unlink(cp);                       /* dangling link */
                        }
                        if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES
                                           attributes:nil error:nil]) made++;
                    }
                }
                dprintf(STDERR_FILENO, "[shell-dir] user folders for %s: %d created\n",
                        [[names.array componentsJoinedByString:@", "] UTF8String], made);
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
            /* madeira-bcd: MADEIRA_WINE_VCRT=1 (a per-game switch) keeps
             * Wine's ARM64EC builtins for every VC++ runtime DLL. Ghost of
             * Tsushima dies right after loading the MS x86_64 concrt140,
             * in the x64<->EC transition the two exemptions below describe. */
            const char *wineVcrt = getenv("MADEIRA_WINE_VCRT");
            if (use_arm64ec && wineVcrt && wineVcrt[0] == '1') {
                for (NSString *dll in [fm contentsOfDirectoryAtPath:[bundlePath stringByAppendingPathComponent:@"x86_64-vcruntime"] error:nil]) {
                    NSString *dst = [sys32Dir stringByAppendingPathComponent:dll];
                    NSString *builtin = [[bundlePath stringByAppendingPathComponent:@"arm64ec-windows"] stringByAppendingPathComponent:dll];
                    if ([fm fileExistsAtPath:builtin]) {
                        [fm removeItemAtPath:dst error:nil];
                        [fm createSymbolicLinkAtPath:dst withDestinationPath:builtin error:nil];
                    }
                }
                LOG("MADEIRA_WINE_VCRT=1: Wine's ARM64EC VC++ runtime builtins kept, no MS overlay");
                dprintf(STDERR_FILENO, "[WineProc] MADEIRA_WINE_VCRT=1: MS VC++ runtime overlay skipped\n");
            } else
            if (use_arm64ec) {
                /* madeira-vcruntime-sources: two sources, not one.
                 *
                 * The bundle is read-only and signature-sealed, so DLLs placed
                 * there can only arrive by rebuilding the app -- which for a
                 * sideloaded build is the entire install cycle. Documents is
                 * user-writable (UIFileSharingEnabled), so it is searched
                 * first and a user-supplied file shadows a bundled one. */
                NSString *vcrtBundleSource = [bundlePath stringByAppendingPathComponent:@"x86_64-vcruntime"];
                NSString *vcrtDocsSource = [NSSearchPathForDirectoriesInDomains(
                    NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                    stringByAppendingPathComponent:@"vcruntime"];
                NSMutableArray *vcrtNames = [NSMutableArray array];
                NSMutableDictionary *vcrtHome = [NSMutableDictionary dictionary];
                for (NSString *dir in @[vcrtDocsSource, vcrtBundleSource]) {
                    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                        /* Skip anything that is not a DLL. Without this the
                         * placeholder README.txt that has to exist for Xcode's
                         * resource copy to succeed is symlinked into system32,
                         * and the "Symlinked N" count counts it. */
                        if (![[f pathExtension] isEqualToString:@"dll"]) continue;
                        if (vcrtHome[[f lowercaseString]]) continue;  /* Documents wins */
                        vcrtHome[[f lowercaseString]] = [dir stringByAppendingPathComponent:f];
                        [vcrtNames addObject:f];
                    }
                }
                NSArray *vcrtDlls = vcrtNames;
                int vcrtLinked = 0, vcrtSkipped = 0;
                /* madeira-bcd: MFC (mfc140.dll, mfc140u.dll) comes from the same
                 * VC_redist.x64.exe since 2026-10-09: Horizon Zero Dawn imports
                 * mfc140.dll and stopped at once with c0000135 without it (log
                 * 12:51:47, build 466). Wine has no MFC of its own, so nothing
                 * else changes. env.MADEIRA_MFC = 0 leaves it out of system32. */
                const char *mfcEnv = getenv("MADEIRA_MFC");
                BOOL mfcOff = mfcEnv && mfcEnv[0] == '0';
                for (NSString *dll in vcrtDlls) {
                    if ([[dll lowercaseString] hasPrefix:@"mfc"]) {
                        NSString *dst = [sys32Dir stringByAppendingPathComponent:dll];
                        if (mfcOff) {
                            [fm removeItemAtPath:dst error:nil];   /* a link from an earlier session */
                            vcrtSkipped++;
                            dprintf(STDERR_FILENO, "[WineProc] %s left out (MADEIRA_MFC=0)\n", dll.UTF8String);
                            continue;
                        }
                        dprintf(STDERR_FILENO, "[WineProc] MFC %s linked (MADEIRA_MFC=0 leaves it out)\n", dll.UTF8String);
                    }
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
                    NSString *src = vcrtHome[[dll lowercaseString]];
                    NSString *dst = [sys32Dir stringByAppendingPathComponent:dll];
                    [fm removeItemAtPath:dst error:nil];
                    if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil])
                        vcrtLinked++;
                }
                LOG("Symlinked %d MS VC++ Runtime DLLs (x86_64 native) over arm64ec builtins, skipped %d", vcrtLinked, vcrtSkipped);
                dprintf(STDERR_FILENO, "[WineProc] Symlinked %d MS VC++ Runtime DLLs over arm64ec builtins (skipped %d for native EC SEH)\n", vcrtLinked, vcrtSkipped);
            }

            /* Desktop OpenGL for x64 games: Mesa's opengl32.dll and its
             * libgallium_wgl.dll run OpenGL on D3D12 (madeira_d3d12, then
             * Metal), with Microsoft's dxil.dll validating the shaders.
             * build/mesa-d3d12/build.sh writes them to x86_64-opengl/; an
             * empty folder changes nothing. Wine's builtin opengl32 here is a
             * native WGL route on OpenGL ES or Zink. The alternative overlay
             * is selected with env.MADEIRA_OPENGL = 1. The loop above has
             * already restored the builtin opengl32 for this session, so off
             * only has to drop the overlay's other files. A game folder that
             * ships its own opengl32.dll still comes first. */
            if (use_arm64ec) {
                NSString *glSource = [bundlePath stringByAppendingPathComponent:@"x86_64-opengl"];
                const char *glSwitch = getenv("MADEIRA_OPENGL");
                const BOOL glOn = glSwitch && glSwitch[0] == '1';
                int glLinked = 0;
                for (NSString *dll in [fm contentsOfDirectoryAtPath:glSource error:nil]) {
                    if (![[[dll pathExtension] lowercaseString] isEqualToString:@"dll"]) continue;
                    NSString *src = [glSource stringByAppendingPathComponent:dll];
                    NSString *dst = [sys32Dir stringByAppendingPathComponent:dll];
                    if (glOn) {
                        [fm removeItemAtPath:dst error:nil];
                        if ([fm createSymbolicLinkAtPath:dst withDestinationPath:src error:nil]) glLinked++;
                    } else if ([[fm destinationOfSymbolicLinkAtPath:dst error:nil] isEqualToString:src] &&
                               ![fm fileExistsAtPath:[dllSource stringByAppendingPathComponent:dll]]) {
                        [fm removeItemAtPath:dst error:nil];
                    }
                }
                dprintf(STDERR_FILENO, "[WineProc] OpenGL: %s (%d Mesa DLLs linked over the builtin)\n",
                        glOn ? "Mesa on D3D12" : "Wine builtin (MADEIRA_OPENGL=0)", glLinked);
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
        } else if (is_i386_target) {
            /* WoW64: a bare i386 name lives in the syswow64 farm */
            snprintf(exe_path, sizeof(exe_path), "C:\\windows\\syswow64\\%s", madeira_exe);
        } else {
            snprintf(exe_path, sizeof(exe_path), "C:\\windows\\system32\\%s", madeira_exe);
        }

        // Optional MADEIRA_ARGS: Windows command-line quoting (CommandLineToArgvW
        // rules), at most 64 arguments in 4 KB. Malformed or oversized input
        // fails the launch instead of silently dropping or splitting arguments.
        static char args_buf[4096];
        char *extra_argv[64] = {0};
        const char *madeira_args = getenv("MADEIRA_ARGS");
        int extra_argc = madeira_split_launch_args(madeira_args, args_buf, sizeof(args_buf),
                                                   extra_argv, sizeof(extra_argv) / sizeof(extra_argv[0]));
        if (extra_argc < 0) {
            dprintf(STDERR_FILENO, "[WineProc] launch rejected: invalid or oversized arguments (parser=%d)\n", extra_argc);
            wine_launched_process_did_exit((int)0xc000000d); /* STATUS_INVALID_PARAMETER */
            g_wine_running = 0;
            wineserver_stop();
            return NULL;
        }

        char *argv[67]; /* wine + executable + 64 arguments + NULL */
        int argc = 0;
        argv[argc++] = "wine";
        argv[argc++] = exe_path;
        for (int i = 0; i < extra_argc; i++) argv[argc++] = extra_argv[i];
        argv[argc] = NULL;
        dprintf(STDERR_FILENO, "[WineProc] argv[1] = %s\n", exe_path);
        /* An argument may be a credential (a sign-in token, a password): each is
         * logged as a redacted copy; argv itself is passed on unchanged. */
        int credential_next = 0;
        for (int i = 0; i < extra_argc; i++) {
            char shown[sizeof(args_buf) + 64];
            madeira_redact_arg_a(extra_argv[i], &credential_next, shown, sizeof(shown));
            dprintf(STDERR_FILENO, "[WineProc] argv[%d] = %s\n", 2 + i, shown);
        }

        /* iOS-Madeira: chdir to the unix path that maps to the exe's Wine
         * directory BEFORE __wine_main. Wine inherits the iOS app sandbox
         * cwd, which becomes a `unix\private\var\mobile\...\Documents\wine\`
         * Wine path — and Thumper's relative cache opens (e.g.,
         * "cache/721e72f7.pc") then resolve to doubled paths that don't
         * exist. Per GPT diagnosis 2026-05-12. Only chdir for full-path EXE
         * launches; bare-name launches (cube, hello-x64) use C:\windows\system32.
         *
         * A launch may carry its working folder in MADEIRA_WORKDIR (a C:\ folder of
         * the prefix, for this launch only; cleared here), used instead of the exe's
         * own: Steam's launch configuration for "Start with: The game", and ml1163's
         * library working folder (LibraryEntry.launchDirectory: a chosen folder, or
         * the program's own when explorer (desktop mode) or cmd.exe (a .bat, the
         * services batch) is what starts). */
        const char *launch_workdir = getenv("MADEIRA_WORKDIR");   /* set by the library for one launch: the working folder (Steam's, or the entry's); not a setting */
        char workdir[512] = "";
        if (launch_workdir && (launch_workdir[0] == 'C' || launch_workdir[0] == 'c') && launch_workdir[1] == ':' &&
            launch_workdir[2] == '\\' && launch_workdir[3] && !strstr(launch_workdir, "..") &&
            strlen(launch_workdir) < sizeof(workdir) - 2)
            snprintf(workdir, sizeof(workdir), "%s", launch_workdir);
        unsetenv("MADEIRA_WORKDIR");
        /* ml1163: a typed folder may end in '\\'; MADEIRA_INITIAL_CWD gets exactly one. */
        for (size_t n = strlen(workdir); n > 3 && workdir[n - 1] == '\\'; n--) workdir[n - 1] = 0;
        if (workdir[0]) {
            char unix_dir[1024], windir[512], wine_cwd[520];
            snprintf(windir, sizeof(windir), "%s", workdir + 3);
            for (char *p = windir; *p; p++) if (*p == '\\') *p = '/';
            snprintf(unix_dir, sizeof(unix_dir), "%s/drive_c/%s", g_prefix_path, windir);
            int rc = chdir(unix_dir);
            setenv("PWD", unix_dir, 1);
            snprintf(wine_cwd, sizeof(wine_cwd), "%s\\", workdir);
            setenv("MADEIRA_INITIAL_CWD", wine_cwd, 1);
            dprintf(STDERR_FILENO, "[WineProc] working folder from the launch: chdir(%s) = %d errno=%d, MADEIRA_INITIAL_CWD=%s\n",
                    unix_dir, rc, rc ? errno : 0, wine_cwd);
        } else if (strchr(madeira_exe, '\\') || (madeira_exe[0] && madeira_exe[1] == ':')) {
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

        /* WoW64: publish the main image's machine so the unix side reserves
         * this process's guest window before its first TEB, and hand FEX's
         * WOW64 module the host features it cannot query itself. */
        ios_main_image_i386 = is_i386_target ? 1 : 0;
        madeira_publish_host_probe();   /* both FEX modules read it (A12/A13: FlagM, FlagM2) */

        if (setjmp(wine_ios_exit_jmpbuf) == 0) {
            __wine_main(argc, argv);
            dprintf(STDERR_FILENO, "[WineProc] __wine_main returned normally\n");
        } else {
            dprintf(STDERR_FILENO, "[WineProc] Wine exited with code %d (caught by longjmp)\n", wine_ios_exit_code);
        }

        /* wine_ios_exit_code is _Thread_local, so copy it somewhere the app
         * thread can read. RELEASE so a reader that sees g_wine_running == 0
         * is guaranteed to see this value too -- volatile alone does not order
         * these on arm64. */
        __atomic_store_n(&g_wine_exit_code, (int)wine_ios_exit_code,
                         __ATOMIC_RELEASE); /* madeira-exit-code */

        /* A launcher stub that starts the game and exits at once (GTA V
         * Enhanced: PlayGTAV.exe -> GTA5_Enhanced.exe) must not end the
         * session -- stopping the wineserver here killed the game while it
         * loaded. If a child process that is not a crash reporter / helper was
         * started in the last 60 s and still runs, the session goes on until
         * no such child is left (process_ios.c, madeira_live_game_children).
         * A game that exits normally long after starting its helpers is not
         * affected. Opt-in, MADEIRA_WAIT_CHILDREN=1 (madeira.cfg, or a game's
         * own config): a child that ends from a worker thread never releases its
         * slot (process_ios.c), and the session would then wait forever. */
        {
            extern int madeira_live_game_children(char *buf, int len, double max_age);
            const char *wc = getenv("MADEIRA_WAIT_CHILDREN");
            char names[256];
            int n = madeira_live_game_children(names, sizeof names, 60.0);
            if (n > 0 && !(wc && wc[0] == '1')) {
                dprintf(STDERR_FILENO, "[WineProc] the main process exited while %d child process(es) it started "
                        "still run (%s); the session ends with it (MADEIRA_WAIT_CHILDREN=1 keeps it while they run)\n",
                        n, names);
            } else if (n > 0) {
                dprintf(STDERR_FILENO, "[WineProc] the main process exited but %d child process(es) "
                        "it started still run (%s) -- a launcher started the game; the session goes on until "
                        "they exit (MADEIRA_WAIT_CHILDREN=1)\n", n, names);
                unsigned ticks = 0;
                while ((n = madeira_live_game_children(names, sizeof names, -1.0)) > 0) {
                    usleep(200 * 1000);
                    if ((++ticks % 300) == 0)
                        dprintf(STDERR_FILENO, "[WineProc] still running: %d child process(es) (%s), %u s\n",
                                n, names, ticks / 5);
                }
                dprintf(STDERR_FILENO, "[WineProc] the last child process exited after %u s\n", ticks / 5);
            }
        }

        g_wine_running = 0;
        /* ml1184: these belong to the launch that just ended; a later session in this app
         * run gets its own from its game, or madeira.cfg's. */
        unsetenv("MADEIRA_FASTSYNC"); unsetenv("MADEIRA_FASTSYNC_SEM");
        unsetenv("MADEIRA_CPU_COUNT"); unsetenv("DXMT_D9_ANISO_LIMIT");
        unsetenv("FEX_X87REDUCEDPRECISION");   /* ml1184 */
        unsetenv("MADEIRA_DINPUT_PAD");        /* ml1240 */
        unsetenv("MADEIRA_DESKTOP");           /* each launch chooses its own presentation mode */
        unsetenv("MADEIRA_DIRECT_WINDOW_SIZE"); /* a game's opt-in must not resize the next game */
        /* madeira-bcd: Horizon Zero Dawn's per-game switches must not reach a later game
         * of this app run (GTA V Enhanced runs without them). */
        unsetenv("MADEIRA_SRV_FGETPATH");
        g_madeira_srv_fgetpath = 0;
        unsetenv("MADEIRA_FEX_AVX"); unsetenv("MADEIRA_FRAMEGEN");   /* ml1184 */
        unsetenv("DXMT_ENABLE_NVEXT"); unsetenv("DXMT_WSI_MONITOR_IDENTITY"); unsetenv("DXMT_WSI_MODE_TABLE");
        /* madeira-bcd: the server's per-launch switches end with the session */
        unsetenv("MADEIRA_SRV_ECO_FOLLOW"); unsetenv("MADEIRA_SRV_DIRECT");
        unsetenv("MADEIRA_SRV_IDLE_US"); unsetenv("MADEIRA_SRV_LOG_ALL");
        g_madeira_srv_eco_follow = 0; g_madeira_srv_direct = 0;
        g_madeira_srv_idle_us = 0; g_madeira_srv_log_all = 0;

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

    /* The guest main thread runs on this pthread. Give it its QoS class
     * through the attribute, as wineserver_start does for the server thread:
     * a thread created with pthread_attr_setschedparam has a fixed priority,
     * and Darwin then refuses pthread_set_qos_class_self_np (EPERM), so the
     * USER_INTERACTIVE promotion in wine_process_thread never took effect and
     * the game's main thread ran at priority 20 on the efficiency cores. */
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);

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

int wine_process_exit_code(void) {
    return __atomic_load_n(&g_wine_exit_code, __ATOMIC_ACQUIRE);
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
