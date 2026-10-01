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
#include <sys/sysctl.h>

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

static pthread_t g_wine_thread;
static volatile int g_wine_running = 0;

/* Session exit report for the library front end. The app marks one process as
 * its own: the program it hands to __wine_main below, which is the session's
 * initial process. ntdll's common exit wrapper (build/ntdll-unix/server_ios.c)
 * calls wine_launched_process_did_exit() for that process only, on whichever
 * thread ends it. Only the status is kept: no names, no allocation, no
 * logging. g_launch_exit holds (1 << 32) | status when the program ended with
 * an NTSTATUS error (0xC...), else 0. */
static uint64_t g_launch_exit = 0;
void wine_launched_process_did_exit(int status) {
    if ((uint32_t)status >= 0xC0000000u)
        __atomic_store_n(&g_launch_exit, (UINT64_C(1) << 32) | (uint32_t)status, __ATOMIC_RELEASE);
}
void wine_exit_status_reset(void) {
    __atomic_store_n(&g_launch_exit, 0, __ATOMIC_RELEASE);
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
 * (build/host-tests/check-cfg-early-docs.py). */
static const char *g_madeira_docs_early = "not-run";
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

/* ===========================================================================
 * WoW64: 32-bit (i386) targets. See docs/WOW64.md.
 *
 * Everything below is used only when the bundle carries the i386 Wine set
 * (app/Madeira/i386-windows, built by build/wine-i386/build.sh) or when the
 * target exe is an i386 PE. A bundle without i386-windows and a 64-bit
 * target take exactly the code path they took before.
 * ========================================================================= */
#define MADEIRA_IMAGE_FILE_MACHINE_I386 0x014c

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
 *    links the 64-bit farms, so a name present in a 64-bit farm is not probed
 *    any further. Otherwise it is looked up in the bundle's i386-windows. To
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
            snprintf(probe, sizeof(probe), "%s/%s/%s", bundle.fileSystemRepresentation, farms64[i], exe);
            if (access(probe, R_OK) == 0) return 0;
        }
        if (snprintf(probe, sizeof(probe), "%s/i386-windows/%s", bundle.fileSystemRepresentation, exe)
                >= (int)sizeof(probe))
            return 0;
    }
    return madeira_pe_machine(probe);
}

/* The bundle carries the i386 Wine set. */
static BOOL madeira_bundle_has_i386(NSString *bundle)
{
    NSString *ntdll = [bundle stringByAppendingPathComponent:@"i386-windows/ntdll.dll"];
    return access(ntdll.fileSystemRepresentation, R_OK) == 0;
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

/* syswow64\wbem, for 32-bit targets. The farms are flat, but WMI's registered
 * InprocServer32 paths are C:\windows\system32\wbem\<name> (wine.inf installs
 * these modules there), so a 32-bit CoCreateInstance(CLSID_WbemLocator) -- for
 * example dxdiagn asking WMI about the display adapter -- fails with
 * c0000135 when the subdirectory is empty. The list is wine.inf's. */
static void madeira_link_syswow64_wbem(NSFileManager *fm, NSString *prefix, NSString *bundle)
{
    static const char * const wbem[] = { "wbemprox.dll", "wbemdisp.dll", "wmiutils.dll",
                                         "wmic.exe", "mofcomp.exe" };
    NSString *dir = [prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64/wbem"];
    NSString *source = [bundle stringByAppendingPathComponent:@"i386-windows"];
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
    dprintf(STDERR_FILENO, "[WineProc] syswow64\\wbem: %d/%zu links\n",
            linked, sizeof(wbem) / sizeof(wbem[0]));
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
 * asks and passes the answers in FEX_MADEIRA_HOSTPROBE. Only the WOW64 module
 * reads it (FEX Source/Windows/Common/CPUFeatures.cpp, !ARCHITECTURE_arm64ec);
 * "?" means the sysctl does not exist and keeps FEX's assumption. */
static void madeira_publish_host_probe(void)
{
    static const struct { const char *key, *sysctl; } probes[] = {
        { "AFP",     "hw.optional.arm.FEAT_AFP" },
        { "FLAGM",   "hw.optional.arm.FEAT_FlagM" },
        { "FLAGM2",  "hw.optional.arm.FEAT_FlagM2" },
        { "FCMA",    "hw.optional.arm.FEAT_FCMA" },
        { "RCPC",    "hw.optional.arm.FEAT_LRCPC" },
        { "AES",     "hw.optional.arm.FEAT_AES" },
        { "PMULL",   "hw.optional.arm.FEAT_PMULL" },
        { "SHA",     "hw.optional.arm.FEAT_SHA256" },
        { "CRC",     "hw.optional.armv8_crc32" },
        { "ATOMICS", "hw.optional.arm.FEAT_LSE" },
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
         * are cleared here, so no later launch inherits them. */
        const char *dock_session = getenv("MADEIRA_DOCK_SESSION");
        const char *direct_app = getenv("MADEIRA_STEAM_APPID");    /* set by the library for one direct Steam start (Start with: The game); not a setting */
        const char *direct_path = getenv("MADEIRA_STEAM_APPPATH"); /* that game's install folder, with MADEIRA_STEAM_APPID; not a setting */
        if (dock_session && dock_session[0] == '1') {
            unsetenv("SteamAppPath");
            unsetenv("SteamGameId");
            unsetenv("SteamAppId");
            dprintf(STDERR_FILENO, "[steam-env] Madeira Dock session: no fixed Steam game identity published\n");
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
                /* Fastsync is the default sync engine: with neither inproc-sync nor
                 * env.MADEIRA_FASTSYNC in madeira.cfg, Wine gets MADEIRA_FASTSYNC=auto,
                 * the value Settings > Sync engine > Fastsync writes. Never overrides a
                 * value already set (a game's own fastsync switch sets 0). */
                if (madeira_cfg_sync_engine() == MADEIRA_SYNC_FASTSYNC && !getenv("MADEIRA_FASTSYNC")) {
                    setenv("MADEIRA_FASTSYNC", "auto", 0);
                    fprintf(stderr, "[madeira-env] sync engine: fastsync (default), MADEIRA_FASTSYNC=auto\n");
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
            NSString *flag = [docs3 stringByAppendingPathComponent:@"madeira-stdout.txt"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
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
        // See the generator for the full chain.
        {
            NSString *docs2 = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSData *seed = [NSData dataWithContentsOfFile:
                            [docs2 stringByAppendingPathComponent:@"madeira-stdin.txt"]];
            if (seed) {
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
                    if (seed.length) {
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
        BOOL use_arm64ec = (force_ec && *force_ec == '1') ||
                           (strstr(madeira_exe, "x64") != NULL) ||
                           (strchr(madeira_exe, '\\') != NULL);

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
        if (is_i386_target) use_arm64ec = NO;
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
        } else if (is_i386_target) {
            /* WoW64: a bare i386 name lives in the syswow64 farm */
            snprintf(exe_path, sizeof(exe_path), "C:\\windows\\syswow64\\%s", madeira_exe);
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
         * launches; bare-name launches (cube, hello-x64) use C:\windows\system32.
         *
         * A Steam game started as its own program ("Start with: The game") may carry
         * the working folder Steam's launch configuration names, in MADEIRA_WORKDIR
         * (a C:\ folder of the prefix, for this launch only; cleared here). That folder
         * is used instead of the exe's own. */
        const char *launch_workdir = getenv("MADEIRA_WORKDIR");   /* set by the library for one launch: Steam's working folder; not a setting */
        char workdir[512] = "";
        if (launch_workdir && (launch_workdir[0] == 'C' || launch_workdir[0] == 'c') && launch_workdir[1] == ':' &&
            launch_workdir[2] == '\\' && launch_workdir[3] && !strstr(launch_workdir, "..") &&
            strlen(launch_workdir) < sizeof(workdir) - 2)
            snprintf(workdir, sizeof(workdir), "%s", launch_workdir);
        unsetenv("MADEIRA_WORKDIR");
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
        if (has_i386_set) madeira_publish_host_probe();

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
