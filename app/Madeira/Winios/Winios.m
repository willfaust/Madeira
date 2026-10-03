/* Winios.m — iOS user_driver implementation for Wine.
 *
 * The Wine win32u-unix side declares weak externs `winios_pCreateWindow`,
 * `winios_pProcessEvents`, etc. in build/win32u-unix/driver_ios.c. This
 * file implements them and gets linked into Madeira.app, completing the
 * driver-funcs slots. Slots we don't implement here (e.g. WintabProc,
 * Vulkan) stay weak-resolved-to-NULL and __wine_set_user_driver falls
 * back to win32u's always-success nulldrv_* stubs.
 *
 * Architecture goal: every UIKit-side state lives here, on the Madeira
 * app side; the driver-facing surface is plain C functions taking Wine
 * types (HWND, HCURSOR, etc.) so the win32u side stays portable.
 *
 * Current status: SCAFFOLD. Functions return success/identity values
 * suitable for "first frames render" — full UIKit window/event bridging
 * lands incrementally. Real games will need pProcessEvents to actually
 * drain UIKit events into Wine's queue.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <os/log.h>
#include <stdarg.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <unistd.h>

/* The window census struct is shared with Swift through this header;
 * including it here keeps both sides' definitions the same. */
#include "Winios.h"

/* csops syscall — CS_DEBUGGED is the flag StikDebug JIT rides on. Declared by
 * hand for the same reason JITAllocator.c does: <sys/codesign.h> is not in the
 * iOS SDK's public headers. */
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

/* Wine-side typedefs we need without pulling in the whole win32u
 * headers (which collide with Apple framework types in Obj-C).
 * BOOL is provided by Foundation; everything else we declare here. */
typedef void *HWND;
typedef void *HCURSOR;
typedef unsigned int UINT;
typedef int  INT;
typedef unsigned long DWORD;
typedef long WINELONG;
typedef struct { WINELONG left, top, right, bottom; } RECT;

/* Wine driver func signatures actually pull more types (window_rects,
 * window_surface) — we forward-declare them as opaque pointers; we
 * never deref them from Obj-C. */
struct window_rects;
struct window_surface;

#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif


/* ============================================================ *
 * freeze detector (ml519)
 * ============================================================
 *
 * Every run suffers a long whole-app freeze — measured at 96.0s starting
 * t+8.5s in ml515 — that ends with StikDebug detaching (after which no NEW
 * exec mappings are possible). It is NOT a deadlock in our code: #67's
 * in-process "accuser" sampler could not run during it either, which means
 * the whole Mach TASK is suspended from outside. It happens in Thumper as
 * well as Steam, so it is a property of the port, not of any title.
 *
 * Nothing inside the process can observe a suspension WHILE it happens.
 * But it can be measured RETROSPECTIVELY: sleep a short fixed interval and
 * compare against a clock that keeps counting while we are stopped.
 * mach_absolute_time() does exactly that. gettimeofday() is logged beside
 * it so a device sleep (both jump) is distinguishable from a task
 * suspension (both jump, but the app was foreground) and from a clock
 * glitch (only one jumps).
 *
 * The HEARTBEAT is not decoration. The srcwatch probe wasted two runs
 * because "armed but zero firings" was read as a clean result when it
 * actually meant the probe was dead. Here, silence is ambiguous the same
 * way — no GAP lines could mean no freeze, or a detector that never
 * started. The heartbeat removes that ambiguity: if heartbeats are present
 * and GAPs are absent, the run genuinely did not freeze.
 *
 * Context is logged with each gap so freezes can be correlated ACROSS
 * TITLES: thread count and resident size are the two things that differ
 * most between Thumper (few threads) and Steam (100+), which is exactly
 * the comparison that would show whether cost scales with thread count.
 */
static double winios_now_mono(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static unsigned winios_thread_count(void) {
    thread_act_array_t list; mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(*list));
    return (unsigned)n;
}

static unsigned winios_resident_mb(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t cnt = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &cnt) != KERN_SUCCESS)
        return 0;
    return (unsigned)(info.resident_size >> 20);
}


/* ml526: startup phase timeline.
 *
 * Steam takes ~33s from the desktop's first present to the login window, and we
 * could only account for it in coarse chunks pieced together from Steam's own
 * cumulative logs. madeira-log cannot time anything on its own: its
 * `[HH:MM:SS.mmm]` prefixes stop after the boot phase, and `[HEARTBEAT]` goes to
 * os_log only (0 hits in madeira-log). The only way to bound a run at all was the
 * last `[footprint] cycle=N` × 2s — which is 2s-granular and says nothing about
 * what happened in between.
 *
 * So: one monotonic origin, stamped at the first call, and a line per milestone.
 * Callable from Swift, from ntdll-unix (same Mach-O), and from here. Passive —
 * it changes no behaviour, so it can ship alongside an experiment without
 * violating one-variable-per-run. */
static double wph_t0;
static pthread_mutex_t wph_lock = PTHREAD_MUTEX_INITIALIZER;
void winios_phase(const char *name)
{
    double now = winios_now_mono(), first;
    pthread_mutex_lock( &wph_lock );
    if (wph_t0 == 0.0) wph_t0 = now;
    first = wph_t0;
    pthread_mutex_unlock( &wph_lock );
    dprintf(STDERR_FILENO, "[phase] %-22s t+%7.3fs rev=ml526\n", name ? name : "(null)", now - first);
}

/* ml522: is the debugger relationship still alive?
 *
 * ⚠️ REPLACES ml521's mmap(MAP_JIT)+mprotect(PROT_EXEC) probe, which was a
 * DUD: it reported NO-RESERVE on every single line of every run — including
 * long before any freeze — because MAP_JIT needs the dynamic-codesigning
 * entitlement a free provisioning profile cannot carry. Our RX pages never
 * came from MAP_JIT in the first place; they come from StikDebug's BRK
 * #0xf00d protocol. The probe's healthy state did not exist, so it measured
 * nothing and could not have answered the question it was written for.
 *
 * CS_DEBUGGED is the flag StikDebug JIT actually rides on, it is what the
 * app's own green checkmark reads, and BOTH of its states are observable in
 * a normal run (set while attached, clear after detach) — so this probe can
 * be trusted when it says "no change", which is the whole point. */
static int winios_cs_debugged(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return -1;
    return (flags & CS_DEBUGGED) ? 1 : 0;
}
static const char *winios_dbg_str(int v) {
    return v == 1 ? "DEBUGGED" : (v == 0 ? "detached" : "csops-fail");
}
/* ml525: shared detector state, so a SUPERVISOR can tell "no freeze" from
 * "detector is dead" — and so a GAP can be attributed to app SUSPENSION rather
 * than a real stall.
 *
 * Both problems bit us on the same ml524 Steam run: the worker printed one
 * heartbeat at t+30s and never again while footprint/waiters/alert-ring each
 * logged 14 more cycles, so "gaps=0" covered only the first ~60s of a
 * login-window run; and a 29.0s GAP in the Thumper run had NO in-log correlate
 * at all and the user saw no freeze — the signature of backgrounding, which
 * stops the task for real while nothing in-process is left to log it.
 * gettimeofday beside the monotonic delta only separates device SLEEP; it
 * cannot see suspension, because both clocks advance normally through it. */
static volatile uint64_t wfz_iter;        /* bumped every worker loop */
static volatile unsigned wfz_gen;         /* worker generation (respawn count) */
static volatile double   wfz_t0;          /* one origin across respawns */
static volatile double   wfz_bg_enter;    /* mono time of DidEnterBackground */
static volatile double   wfz_bg_exit;     /* mono time of WillEnterForeground */
static volatile int      wfz_bg_now;

/* UIKit posts these on the main run loop BEFORE suspension and again on
 * resume, so they bracket a suspension window. If the main thread is genuinely
 * wedged they never arrive — which is exactly the discriminator: a gap with a
 * background transition inside it is the OS stopping us, a gap without one is
 * a real freeze. */
static void winios_bg_observe(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { (void)n;
                    wfz_bg_enter = winios_now_mono(); wfz_bg_now = 1; }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { (void)n;
                    wfz_bg_exit = winios_now_mono(); wfz_bg_now = 0; }];
}

static void *winios_freeze_watch(void *arg) {
    const double SLEEP_S = 0.25;
    const double GAP_S   = 2.0;    /* well above any scheduling delay */
    const double BEAT_S  = 30.0;
    unsigned my_gen = (unsigned)(uintptr_t)arg;
    double t0 = wfz_t0, last = winios_now_mono(), last_beat = last;
    unsigned gaps = 0, beats = 0;
    int dbg = winios_cs_debugged();     /* ml522: track debugger attachment */

    dprintf(STDERR_FILENO, "[freeze] detector started gen=%u (sleep=%.2fs gap>%.1fs) rev=ml525\n",
            my_gen, SLEEP_S, GAP_S);

    for (;;) {
        /* A respawned worker supersedes us; exit rather than double-report. */
        if (my_gen != wfz_gen) {
            dprintf(STDERR_FILENO, "[freeze] detector gen=%u superseded by gen=%u — exiting rev=ml525\n",
                    my_gen, wfz_gen);
            return NULL;
        }
        wfz_iter++;
        struct timeval w0, w1;
        gettimeofday(&w0, NULL);
        usleep((useconds_t)(SLEEP_S * 1e6));
        double now = winios_now_mono();
        gettimeofday(&w1, NULL);

        double slept = now - last;
        double wall  = (double)(w1.tv_sec - w0.tv_sec) + (double)(w1.tv_usec - w0.tv_usec) / 1e6;

        {   /* ml522: report transitions immediately, with t+ so they can be
             * placed exactly against the gap boundaries. Which SIDE of a gap
             * the detach lands on is the causal question: at the START the
             * stall is a consequence of losing the debugger, at the END the
             * stall IS the kernel tearing the relationship down. */
            int now_dbg = winios_cs_debugged();
            if (now_dbg != dbg) {
                dprintf(STDERR_FILENO, "[dbg-state] CS_DEBUGGED %s -> %s at t+%.1fs rev=ml522\n",
                        winios_dbg_str(dbg), winios_dbg_str(now_dbg), now - t0);
                dbg = now_dbg;
            }
        }

        if (slept > GAP_S) {
            /* ml525: did the OS stop us? A DidEnterBackground stamped at or just
             * before the gap start, with no matching return to foreground before
             * the gap end, means the task was SUSPENDED — not frozen. Slack on
             * the leading edge because the notification is posted a moment before
             * the kernel actually stops us. */
            int bg = (wfz_bg_enter > 0.0 &&
                      wfz_bg_enter >= last - 3.0 && wfz_bg_enter <= now);
            gaps++;
            dprintf(STDERR_FILENO,
                    "[freeze] GAP #%u  %.1fs (wall %.1fs) — started t+%.1fs, ended t+%.1fs;"
                    " threads=%u resident=%uMB dbg=%s gen=%u cause=%s rev=ml525\n",
                    gaps, slept, wall, last - t0, now - t0,
                    winios_thread_count(), winios_resident_mb(),
                    winios_dbg_str(dbg), my_gen,
                    bg ? "BACKGROUNDED(not-a-freeze)" : "unexplained-FREEZE");
            if (bg)
                dprintf(STDERR_FILENO, "[freeze]   bg-enter t+%.1fs bg-exit t+%.1fs bg_now=%d\n",
                        wfz_bg_enter - t0, wfz_bg_exit - t0, wfz_bg_now);
        }

        if (now - last_beat >= BEAT_S) {
            beats++;
            /* Liveness. Absence of GAPs only means "no freeze" if these are
             * present — otherwise it means the detector is not running. iter is
             * printed so a WEDGED worker (iter frozen) is distinguishable from a
             * merely quiet one. */
            dprintf(STDERR_FILENO, "[freeze] alive t+%.0fs beats=%u gaps=%u iter=%llu gen=%u "
                            "threads=%u resident=%uMB dbg=%s rev=ml525\n",
                    now - t0, beats, gaps, (unsigned long long)wfz_iter, my_gen,
                    winios_thread_count(), winios_resident_mb(),
                    winios_dbg_str(dbg));
            last_beat = now;
        }
        last = now;
    }
    return NULL;
}

/* ml525: supervisor. The worker's for(;;) has no normal exit, so if it stops
 * ticking it was killed or wedged from outside — plausibly as a host thread
 * with no TEB hitting the ios_fault_is_foreign / ios_decline_foreign_fault
 * path (#85). Silence there is indistinguishable from "no freezes", which is
 * precisely the ml524 Steam ambiguity.
 *
 * Self-calibrating: a task-wide suspension stops the SUPERVISOR too, so it only
 * judges the worker when its own sleep took roughly the expected wall time.
 * That way a genuine 54s freeze can never be misread as a dead worker. */
static void *winios_freeze_super(void *arg) {
    const double CHECK_S = 10.0;
    (void)arg;
    for (;;) {
        double s0 = winios_now_mono();
        uint64_t a = wfz_iter;
        usleep((useconds_t)(CHECK_S * 1e6));
        double s1 = winios_now_mono();
        uint64_t b = wfz_iter;

        if (b != a) continue;                       /* worker healthy */
        if (s1 - s0 > CHECK_S * 2.0) continue;      /* WE were stopped too — not the worker */

        wfz_gen++;
        dprintf(STDERR_FILENO, "[freeze] ⚠️ DETECTOR DEAD — iter stuck at %llu across %.1fs; "
                        "respawning as gen=%u. Every 'gaps=0' before this line covers "
                        "only up to here. rev=ml525\n",
                (unsigned long long)b, s1 - s0, wfz_gen);
        {
            pthread_t th;
            if (pthread_create(&th, NULL, winios_freeze_watch,
                               (void *)(uintptr_t)wfz_gen) == 0)
                pthread_detach(th);
            else {
                dprintf(STDERR_FILENO, "[freeze] respawn FAILED — detector is gone rev=ml525\n");
            }
        }
    }
    return NULL;
}

void winios_freeze_watch_start(void) {
    static int started;
    pthread_t th, sup;
    if (started) return;
    started = 1;
    wfz_t0 = winios_now_mono();
    winios_bg_observe();
    wfz_gen = 1;
    if (pthread_create(&th, NULL, winios_freeze_watch, (void *)(uintptr_t)1) == 0)
        pthread_detach(th);
    else
        dprintf(STDERR_FILENO, "[freeze] detector FAILED to start rev=ml525\n");
    if (pthread_create(&sup, NULL, winios_freeze_super, NULL) == 0)
        pthread_detach(sup);
    else
        dprintf(STDERR_FILENO, "[freeze] supervisor FAILED to start rev=ml525\n");
}

static os_log_t winios_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.madeira.emulator", "winios.drv"); });
    return log;
}

#define WLOG(fmt, ...) os_log(winios_log(), "[winios] " fmt, ##__VA_ARGS__)

/* ============================================================ *
 * window lifecycle
 * ============================================================ */

BOOL winios_pCreateWindow(HWND hwnd) {
    /* Real impl will set up a UIView with a CAMetalLayer attached to
     * the Madeira window and bind it to this hwnd. For now: success.
     * DXMT-rendered games already get their CAMetalLayer via the
     * IOSDisplayShim macdrv_functions path — no need to allocate one
     * per HWND yet. */
    WLOG("pCreateWindow hwnd=%p", hwnd);
    return TRUE;
}

static void winios_remove_layer(HWND hwnd);   /* compositor, below */

/* ============================================================ *
 * Top-level window census (see Winios.h)
 * ============================================================
 *
 * A game started through Madeira Dock runs in a desktop session: explorer,
 * the Dock host's console window, Valve's client inside the host, and the
 * game's one-time installers can all put windows up before the game does,
 * each from a different thread. Nothing on the app side could tell those
 * apart, so the starting screen went away on the desktop's first GDI frame.
 *
 * The one fact that separates them generically is WHICH PROGRAM owns the
 * window, and where that program lives on drive C. win32u knows the owning
 * process id and the server knows every process's image path
 * (SystemProcessIdInformation asks it by id without opening a handle). Both
 * are read on the Wine thread inside the WindowPosChanged hook
 * (winios_drv_census_owner / winios_drv_process_image in driver_ios.c); each
 * process's path is looked up once. The app decides what the paths mean.
 *
 * Only while the app has switched it on (winios_window_census_enable), so a
 * normal session never pays a lookup. */
#define WINIOS_WS_VISIBLE    0x10000000u
#define WINIOS_WS_MINIMIZE   0x20000000u

extern int winios_drv_census_owner(HWND hwnd, unsigned int *pid, unsigned int *style);
extern int winios_drv_process_image(unsigned int pid, char *out, unsigned int size);
extern int winios_drv_post_restore(HWND hwnd);
extern int winios_drv_foreground_if_owner(HWND hwnd);

/* A game's main window can be shown minimized the first time it is shown
 * (ShowWindow cmd 2, parked at -32000,-32000). On Windows the taskbar brings
 * it back; Madeira has no taskbar, so the starting screen waited for a window
 * that never appeared. While the census runs, a top-level window whose first
 * show is minimized is sent what a taskbar click sends: WM_SYSCOMMAND/
 * SC_RESTORE, once. A window that was shown and later minimized itself (e.g.
 * on losing focus) is left alone. MADEIRA_RESTORE_BORN_MINIMIZED=0 turns this
 * off. Restored, such a window was shown but its game stayed idle (a
 * fullscreen game pauses without focus): a taskbar click also brings the
 * window to the front, which its own thread does from its event pump
 * (g_restore_foreground, winios_pProcessEvents). */
static _Atomic(uintptr_t) g_restore_foreground;
static int winios_restore_born_minimized_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) { const char *e = getenv("MADEIRA_RESTORE_BORN_MINIMIZED"); enabled = !(e && e[0] == '0'); }   /* 0: while a Dock start's census runs, a window first shown minimized stays minimized */
    return enabled;
}

static pthread_mutex_t g_census_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_census_on;
static struct winios_census_window g_census[WINIOS_CENSUS_MAX];
static int g_census_n;
#define WINIOS_CENSUS_IMAGES 48
static struct { unsigned int pid; int known; char image[WINIOS_CENSUS_IMAGE]; } g_census_images[WINIOS_CENSUS_IMAGES];
static int g_census_images_n;
static _Atomic unsigned g_census_failures;

/* The owning program's executable path (see Winios.h), "" when the server
 * could not name it. Cached per process id for the census's lifetime.
 * Wine thread only (the lookup is a server call). */
static int winios_census_image(unsigned int pid, char out[WINIOS_CENSUS_IMAGE]) {
    out[0] = 0;
    if (!pid) return 0;
    pthread_mutex_lock(&g_census_lock);
    for (int i = 0; i < g_census_images_n; i++) {
        if (g_census_images[i].pid != pid) continue;
        memcpy(out, g_census_images[i].image, WINIOS_CENSUS_IMAGE);
        int known = g_census_images[i].known;
        pthread_mutex_unlock(&g_census_lock);
        return known;
    }
    pthread_mutex_unlock(&g_census_lock);

    int known = winios_drv_process_image(pid, out, WINIOS_CENSUS_IMAGE);
    if (!known) {
        out[0] = 0;
        if (atomic_fetch_add(&g_census_failures, 1) < 4) {
            fprintf(stderr, "[window-census] no image path for pid %04x\n", pid);
            fflush(stderr);
        }
    }
    pthread_mutex_lock(&g_census_lock);
    if (g_census_images_n < WINIOS_CENSUS_IMAGES) {
        g_census_images[g_census_images_n].pid = pid;
        g_census_images[g_census_images_n].known = known;
        memcpy(g_census_images[g_census_images_n].image, out, WINIOS_CENSUS_IMAGE);
        g_census_images_n++;
    }
    pthread_mutex_unlock(&g_census_lock);
    return known;
}

/* Caller holds g_census_lock. */
static struct winios_census_window *winios_census_find(HWND hwnd) {
    for (int i = 0; i < g_census_n; i++)
        if (g_census[i].hwnd == (unsigned long long)(uintptr_t)hwnd) return &g_census[i];
    return NULL;
}

/* Wine thread, from winios_window_frame (the WindowPosChanged hook, which runs
 * on the window's own thread). Records top-level windows only. */
static void winios_census_note_frame(HWND hwnd, int x, int y, int w, int h, int visible) {
    if (!atomic_load_explicit(&g_census_on, memory_order_relaxed) || !hwnd) return;
    /* win32u calls stay outside the census lock: they take win32u's own. */
    unsigned int pid = 0, style = 0;
    if (!winios_drv_census_owner(hwnd, &pid, &style)) return;
    char image[WINIOS_CENSUS_IMAGE];
    winios_census_image(pid, image);
    int shown = visible && (style & WINIOS_WS_VISIBLE) && !(style & WINIOS_WS_MINIMIZE) && w > 0 && h > 0;
    int born_minimized = 0;

    pthread_mutex_lock(&g_census_lock);
    struct winios_census_window *e = winios_census_find(hwnd);
    if (!e && g_census_n < WINIOS_CENSUS_MAX) e = &g_census[g_census_n++];
    if (!e && shown) {
        /* Full: reuse a hidden window's slot rather than lose a shown one. */
        for (int i = 0; i < g_census_n && !e; i++) if (!g_census[i].visible) e = &g_census[i];
    }
    if (e) {
        if (e->hwnd != (unsigned long long)(uintptr_t)hwnd) memset(e, 0, sizeof(*e));
        e->hwnd = (unsigned long long)(uintptr_t)hwnd;
        e->x = x; e->y = y; e->w = w; e->h = h;
        e->pid = pid;
        e->visible = (unsigned char)shown;
        memcpy(e->image, image, sizeof(e->image));
        if (shown) e->shown_once = 1;
        else if ((style & WINIOS_WS_VISIBLE) && (style & WINIOS_WS_MINIMIZE) && !e->shown_once && !e->restore_sent &&
                 winios_restore_born_minimized_enabled()) {
            e->restore_sent = 1;
            born_minimized = 1;
        }
    }
    pthread_mutex_unlock(&g_census_lock);
    if (born_minimized) {
        /* Posted, not sent: this runs inside the window's WindowPosChanged. */
        int ok = winios_drv_post_restore(hwnd);
        atomic_store(&g_restore_foreground, (uintptr_t)hwnd);
        fprintf(stderr, "[born-minimized] hwnd=%p pid=%04x restore-posted=%d "
                        "(MADEIRA_RESTORE_BORN_MINIMIZED=0 leaves it minimized)\n", hwnd, pid, ok ? 1 : 0);
        fflush(stderr);
    }
}

/* Wine thread, from the GDI flush: count frames of listed windows only. */
static void winios_census_note_present(HWND hwnd) {
    if (!atomic_load_explicit(&g_census_on, memory_order_relaxed)) return;
    pthread_mutex_lock(&g_census_lock);
    struct winios_census_window *e = winios_census_find(hwnd);
    if (e && e->presents < 0xffffffffu) e->presents++;
    pthread_mutex_unlock(&g_census_lock);
}

/* A desktop-mode swapchain was made for this window (any thread). A swapchain
 * on a child window is not listed; the app also watches DXMT's present count. */
static void winios_census_note_metal(HWND hwnd) {
    if (!atomic_load_explicit(&g_census_on, memory_order_relaxed)) return;
    pthread_mutex_lock(&g_census_lock);
    struct winios_census_window *e = winios_census_find(hwnd);
    if (e) e->metal = 1;
    pthread_mutex_unlock(&g_census_lock);
}

static void winios_census_forget(HWND hwnd) {
    if (!atomic_load_explicit(&g_census_on, memory_order_relaxed)) return;
    pthread_mutex_lock(&g_census_lock);
    struct winios_census_window *e = winios_census_find(hwnd);
    if (e) { *e = g_census[--g_census_n]; memset(&g_census[g_census_n], 0, sizeof(g_census[0])); }
    pthread_mutex_unlock(&g_census_lock);
}

void winios_window_census_enable(int on) {
    pthread_mutex_lock(&g_census_lock);
    int was = atomic_load(&g_census_on);
    g_census_n = 0;
    g_census_images_n = 0;
    memset(g_census, 0, sizeof(g_census));
    atomic_store(&g_census_on, on ? 1 : 0);
    pthread_mutex_unlock(&g_census_lock);
    if (!was != !on) {
        fprintf(stderr, "[window-census] %s\n", on ? "on" : "off");
        fflush(stderr);
    }
}

int winios_window_census(struct winios_census_window *out, int max) {
    if (!out || max <= 0) return 0;
    pthread_mutex_lock(&g_census_lock);
    int n = g_census_n < max ? g_census_n : max;
    memcpy(out, g_census, (size_t)n * sizeof(*out));
    pthread_mutex_unlock(&g_census_lock);
    return n;
}

void winios_pDestroyWindow(HWND hwnd) {
    WLOG("pDestroyWindow hwnd=%p", hwnd);
    uintptr_t pending = (uintptr_t)hwnd;
    atomic_compare_exchange_strong(&g_restore_foreground, &pending, 0);
    winios_census_forget(hwnd);
    winios_remove_layer(hwnd);
}

UINT winios_pShowWindow(HWND hwnd, INT cmd, RECT *rect, UINT swp) {
    /* ml528 (#86 VARIANCE): the sentinel for "we did not override the swp
     * flags" is ~0, NOT 0. This returned 0 — and 0 is a perfectly valid flag
     * word meaning "no flags at all", so win32u took it literally and threw
     * away everything show_window() had just computed.
     *
     *   win32u/window.c:4842
     *     else if ((new_swp = user_driver->pShowWindow(hwnd, cmd, &newPos, swp)) == ~0)
     *     { ... else new_swp = swp; }        <- only reached when we return ~0
     *     swp = new_swp;
     *     NtUserSetWindowPos( hwnd, HWND_TOP, ..., swp );
     *
     * and for the case that matters:
     *   case SW_SHOW:  swp |= SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE;
     *
     * So every ShowWindow that reached this hook lost SWP_SHOWWINDOW, and the
     * window was moved/resized but never made visible. Measured directly on
     * the Steam login popup — identical rect, ex-style, thread and SetWindowPos
     * traffic in a working and a failing run, differing in exactly one bit:
     *   fail: 0x1010a "Sign in to Steam" style=86ca0000 vis=0
     *   ok:   0x1010a "Sign in to Steam" style=96ca0000 vis=1   (0x10000000 = WS_VISIBLE)
     * No WS_VISIBLE => no [surf-create] for the hwnd => zero presents => nothing
     * on screen, while Steam's own log happily reports PopupHTMLWindow and
     * BrowserReady:131073.
     *
     * ⚠️ It is intermittent rather than total because there are paths that never
     * consult us: `if (IsRectEmpty(&newPos)) new_swp = swp;` skips the driver
     * entirely, and a window created already-WS_VISIBLE or shown by a later
     * SetWindowPos carrying SWP_SHOWWINDOW never comes through here.
     *
     * ~0 is what nulldrv_ShowWindow returns (driver_ios.c:1340), i.e. this is
     * now behaviour-identical to having no hook at all — which is what the
     * original comment intended.
     *
     * ml529: log the hook ITSELF. The ml528 analysis INFERRED whether this ran
     * by looking for a `[win-pos] flags=00000000` (the swp=0 signature) and
     * found none — but `[win-pos]` only logs `n <= 200 || n % 128 == 0`, and the
     * login window's events land at #190-200, so a call just past the cap would
     * be invisible. Inferring a probe's coverage instead of measuring it is how
     * that analysis went wrong; this answers it directly.
     *
     * Also logs whether the window is already WS_VISIBLE-bound for the given
     * cmd, so a run that freezes with a dead cursor can be checked against the
     * activation theory: swp=0 carried neither SWP_NOACTIVATE nor SWP_NOZORDER
     * while NtUserSetWindowPos is called with HWND_TOP, so the old code would
     * ACTIVATE and RAISE an invisible window — an input sink that would look
     * exactly like "desktop frozen, cursor gone, logs still moving". */
    {
        static volatile int sw_n;
        int n = __sync_add_and_fetch( &sw_n, 1 );
        if (n <= 64 || (n % 64) == 0)
            dprintf( STDERR_FILENO,
                     "[show-win] #%d hwnd=%p cmd=%d swp_in=%08x -> returning ~0 "
                     "(pre-ml528 returned 0, which destroyed SWP_SHOWWINDOW) rev=ml529\n",
                     n, hwnd, cmd, (unsigned)swp );
    }
    return ~0u;
}

void winios_pWindowPosChanged(HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags,
                              const struct window_rects *new_rects, struct window_surface *surface) {
    /* Real impl will resize the UIView/CAMetalLayer to match. No-op
     * for now — DXMT's swapchain owns its own dimensions explicitly. */
}

/* ============================================================ *
 * event pump — touch → mouse bridge
 * ============================================================
 *
 * Ring buffer of pending touch events posted by the Madeira Swift UI
 * (via winios_post_touch / winios_post_touch_move / winios_post_touch_up).
 * The Wine thread drains it from pProcessEvents, translating each
 * touch event into a synthesized hardware mouse INPUT and dispatching
 * via NtUserSendHardwareInput (through the winios_drv_post_mouse C
 * bridge in driver_ios.c). */

/* Mouse-event flags from <winuser.h> that we emit. We don't include
 * winuser.h to avoid header soup with UIKit, so reproduce constants. */
#define MOUSEEVENTF_MOVE        0x0001
#define MOUSEEVENTF_LEFTDOWN    0x0002
#define MOUSEEVENTF_LEFTUP      0x0004
#define MOUSEEVENTF_RIGHTDOWN   0x0008
#define MOUSEEVENTF_RIGHTUP     0x0010
#define MOUSEEVENTF_WHEEL       0x0800
#define MOUSEEVENTF_ABSOLUTE    0x8000

extern void winios_drv_post_mouse(int x, int y, unsigned int flags, unsigned int mouse_data, void *hwnd);
extern void winios_drv_post_key(unsigned short vk, unsigned int flags);
extern void winios_dump_window_tree(void);
extern void ios_dump_all_thread_stacks(void);

#define WINIOS_RING_SIZE 256
#define WINIOS_EV_MOUSE 0
#define WINIOS_EV_KEY   1
#define KEYEVENTF_KEYUP 0x0002
typedef struct {
    unsigned int type;       /* WINIOS_EV_MOUSE / WINIOS_EV_KEY */
    int x, y;                /* mouse: coords; key: x = virtual-key code */
    unsigned int flags;      /* mouse: MOUSEEVENTF_*; key: KEYEVENTF_* */
    unsigned int data;       /* mouse: mouseData (wheel delta) */
} winios_input_event_t;

static struct {
    winios_input_event_t buf[WINIOS_RING_SIZE];
    unsigned int head;       /* producer cursor (Swift side) */
    unsigned int tail;       /* consumer cursor (Wine drain) */
    pthread_mutex_t lock;
} g_input_q = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void winios_q_push_ev(unsigned int type, int x, int y, unsigned int flags, unsigned int data) {
    pthread_mutex_lock(&g_input_q.lock);
    unsigned int next = (g_input_q.head + 1) % WINIOS_RING_SIZE;
    if (next != g_input_q.tail) {
        g_input_q.buf[g_input_q.head] = (winios_input_event_t){type, x, y, flags, data};
        g_input_q.head = next;
    }
    /* If buffer is full we drop the oldest event by simply not advancing —
     * better than blocking the UI thread on a Wine event drain. */
    pthread_mutex_unlock(&g_input_q.lock);
}

/* Public C entry points for Swift / UIKit gesture handlers.
 * Coordinates are in iOS view-local pixels; we scale to a fixed
 * 1024×768 logical surface inside winios_pProcessEvents to match
 * what DXMT swapchains use. */
void winios_post_touch_down(int x, int y) {
    fprintf(stderr, "[winios] post_touch_down x=%d y=%d\n", x, y); fflush(stderr);
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, 0);
}

void winios_post_touch_move(int x, int y) {
    static unsigned cnt;
    if ((cnt++ % 30) == 0) {
        fprintf(stderr, "[winios] post_touch_move x=%d y=%d (n=%u)\n", x, y, cnt); fflush(stderr);
    }
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 0);
}

void winios_post_touch_up(int x, int y) {
    fprintf(stderr, "[winios] post_touch_up x=%d y=%d\n", x, y); fflush(stderr);
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, 0);
}

/* Key press bridge. vk = Windows virtual-key code, down = 1 for press,
 * 0 for release. Queued like mouse events; drained in pProcessEvents. */
void winios_post_key(int vk, int down) {
    fprintf(stderr, "[winios] post_key vk=0x%x down=%d\n", vk, down); fflush(stderr);
    winios_q_push_ev(WINIOS_EV_KEY, vk, 0, down ? 0 : KEYEVENTF_KEYUP, 0);
}

BOOL winios_pProcessEvents(DWORD mask) {
    /* The restored born-minimized window's own thread brings it to the front
     * (see g_restore_foreground); other threads leave the request in place. */
    uintptr_t fg = atomic_load_explicit(&g_restore_foreground, memory_order_relaxed);
    if (fg) {
        int r = winios_drv_foreground_if_owner((HWND)fg);
        if (r && atomic_compare_exchange_strong(&g_restore_foreground, &fg, 0)) {
            fprintf(stderr, "[born-minimized] hwnd=%p foreground=%d\n", (HWND)fg, r);
            fflush(stderr);
        }
    }
    static unsigned int cnt;
    static int quiet = -1;
    if (quiet < 0) quiet = getenv("MADEIRA_QUIET") != NULL;
    if ((cnt++ % 240) == 0 && !quiet) {
        fprintf(stderr, "[winios] pProcessEvents called n=%u\n", cnt); fflush(stderr);
    }
    /* Desktop debugging: dump the full window tree every ~5s. Runs on
     * this wine thread (valid TEB — the dump walks win32u internals). */
    static int desk = -1;
    if (desk < 0) desk = ({ const char *d = getenv("MADEIRA_DESKTOP"); d && *d == '1'; });
    if (desk) {
        static double next_tree_dump;
        double now = CACurrentMediaTime();
        if (now >= next_tree_dump) {
            next_tree_dump = now + 5.0;
            winios_dump_window_tree();
        }
    }
    BOOL drained = FALSE;
    for (;;) {
        winios_input_event_t e;
        pthread_mutex_lock(&g_input_q.lock);
        if (g_input_q.tail == g_input_q.head) {
            pthread_mutex_unlock(&g_input_q.lock);
            break;
        }
        e = g_input_q.buf[g_input_q.tail];
        g_input_q.tail = (g_input_q.tail + 1) % WINIOS_RING_SIZE;
        pthread_mutex_unlock(&g_input_q.lock);

        fprintf(stderr, "[winios] drain type=%u x=%d y=%d flags=0x%x\n", e.type, e.x, e.y, e.flags); fflush(stderr);
        if (e.type == WINIOS_EV_KEY)
            winios_drv_post_key((unsigned short)e.x, e.flags);
        else
            winios_drv_post_mouse(e.x, e.y, e.flags, e.data, NULL);
        drained = TRUE;
    }
    return drained;
}

/* ============================================================ *
 * S2 compositor: window surfaces → CALayers
 * ============================================================
 *
 * The win32u side (driver_ios.c winios_surface_flush) calls
 * winios_surface_present with a window's full 32bpp BGRX DIB after
 * every GDI flush, and winios_window_frame with the window's visible
 * rect (desktop pixel coords) on every position change. We keep one
 * CALayer per HWND inside a full-screen, touch-transparent UIView and
 * let Core Animation do the compositing. Desktop coords are native
 * pixels (e.g. 1170x2532); layers are placed in points (÷ screen
 * scale). Only active when MADEIRA_DESKTOP=1 (the driver side gates
 * surface creation, so games never reach these). */

static NSMutableDictionary<NSNumber *, CALayer *> *g_layers;
static NSMutableDictionary<NSNumber *, NSValue *> *g_px_rects;  /* hwnd → last px rect */
static NSMutableDictionary<NSNumber *, NSValue *> *g_surf_sizes; /* hwnd → surface px size */
static NSMutableDictionary<NSNumber *, CAMetalLayer *> *g_metal_layers; /* hwnd → DXMT layer */
static NSMutableDictionary<NSNumber *, NSValue *> *g_client_rects;      /* hwnd → client px rect */
/* Desktop fit state (winios_desktop_fit below), main thread only. */
static NSNumber *g_fit_key;
static CGRect g_fit_client_px;   /* the window's client rect, desktop px */
static CGRect g_fit_view_pt;     /* where it is shown, compositor-view points */
static void winios_place_metal_layer(NSNumber *key);

/* Surfaces are 128px-aligned (win32u), usually LARGER than the window.
 * Crop the layer contents to the window's actual size or everything
 * stretches/squashes. Main thread only. */
static void winios_apply_contents_rect(NSNumber *key, CALayer *l) {
    NSValue *sv = g_surf_sizes[key], *rv = g_px_rects[key];
    if (!sv || !rv) return;
    CGSize surf = sv.CGSizeValue;
    CGRect px = rv.CGRectValue;
    if (surf.width <= 0 || surf.height <= 0 || CGRectIsEmpty(px)) return;
    l.contentsRect = CGRectMake(0, 0,
                                MIN(px.size.width / surf.width, 1.0),
                                MIN(px.size.height / surf.height, 1.0));
}

/* GDI window images the compositor has shown (desktop sessions). The library
 * front end reads it to notice a desktop session's first frame, the way it
 * reads DXMT's present counter for a direct launch. */
static _Atomic unsigned long long g_surface_present_count;
unsigned long long winios_surface_present_count(void) {
    return atomic_load_explicit(&g_surface_present_count, memory_order_relaxed);
}

/* IOSDisplayShim.m: the guest's virtual monitor as win32u last published it
 * (the session default until a program changes the display mode). */
extern void winios_screen_size(int *w, int *h);
extern NSString * const MadeiraDisplayModeChangedNotification;

static UIView *g_compositor_view;
static BOOL g_comp_game;   /* g_compositor_view is the game-mode overlay (below) */
static void winios_drop_compositor(const char *why);
static CALayer *g_desk_bg;               /* teal desktop-area backdrop */
static CGFloat g_px_to_pt = 1.0 / 3.0;   /* desktop px → screen pt (x, and y unless stretched) */
static CGFloat g_px_to_pt_y;             /* y scale when the display mode stretches; 0 = same as x */
static CGPoint g_desk_origin;            /* desktop (0,0) in view pt (letterbox offset) */
/* The rect the front end laid the guest display out in (its Aspect / Fill /
 * Stretch / Fit choice, GameSurfaceLayout), in compositor-view points. When
 * set, the desktop is placed there instead of being aspect-fit into the
 * whole frame, so the display-mode setting applies to desktop sessions too. */
static CGRect g_desk_rect;
static BOOL g_desk_rect_set;
#define WINIOS_PX_TO_PT_Y (g_px_to_pt_y > 0 ? g_px_to_pt_y : g_px_to_pt)
static CGRect g_comp_frame;              /* presentation area (window coords), from Swift */
static BOOL g_comp_frame_set;

static CGRect winios_layer_rect(int x, int y, int w, int h) {
    CGFloat s = g_px_to_pt, sy = WINIOS_PX_TO_PT_Y;
    return CGRectMake(g_desk_origin.x + x * s, g_desk_origin.y + y * sy, w * s, h * sy);
}

/* main thread only. Sizes the compositor to the presentation frame and
 * aspect-fits the wine desktop inside it; repositions existing layers. */
static void winios_layout_compositor(void) {
    if (!g_compositor_view) return;
    UIWindow *win = g_compositor_view.superview ? (UIWindow *)g_compositor_view.superview : nil;
    CGRect frame = g_comp_frame_set ? g_comp_frame : (win ? win.bounds : g_compositor_view.frame);
    g_compositor_view.frame = frame;

    /* The LIVE guest size, not MADEIRA_SCREEN_W/H. That environment pair is
     * the session's launch-time seed; win32u owns the value afterwards and
     * publishes every change through winios_display_mode_changed
     * (IOSDisplayShim.m). Reading the seed kept letterboxing against the old
     * size after a program programmed a different mode, so an 800x600 game
     * stayed a small window inside a 1280x720 frame. */
    int desk_w = 0, desk_h = 0;
    winios_screen_size(&desk_w, &desk_h);
    if (desk_w <= 0) desk_w = 1024;
    if (desk_h <= 0) desk_h = 768;
    CGFloat s = MIN(frame.size.width / desk_w, frame.size.height / desk_h);
    CGSize fit = CGSizeMake(desk_w * s, desk_h * s);
    g_px_to_pt = s;
    g_px_to_pt_y = 0;
    g_desk_origin = CGPointMake((frame.size.width - fit.width) / 2,
                                (frame.size.height - fit.height) / 2);
    if (g_desk_rect_set && g_desk_rect.size.width >= 1 && g_desk_rect.size.height >= 1) {
        /* The front end's display mode: Fit and Aspect keep the guest shape
         * (uniform), Fill overflows the frame (clipped by the view), Stretch
         * is the one anisotropic case. */
        g_px_to_pt = g_desk_rect.size.width / desk_w;
        CGFloat sy = g_desk_rect.size.height / desk_h;
        if (fabs(sy - g_px_to_pt) > 0.0005) g_px_to_pt_y = sy;
        g_desk_origin = g_desk_rect.origin;
        fit = g_desk_rect.size;
    }
    g_desk_bg.frame = CGRectMake(g_desk_origin.x, g_desk_origin.y, fit.width, fit.height);

    /* re-place existing window layers under the new mapping */
    for (NSNumber *key in g_px_rects) {
        CALayer *l = g_layers[key];
        CGRect r = g_px_rects[key].CGRectValue;
        if (l) l.frame = winios_layer_rect((int)r.origin.x, (int)r.origin.y,
                                           (int)r.size.width, (int)r.size.height);
        winios_place_metal_layer(key);
    }
    fprintf(stderr, "[winios] compositor layout: frame=(%.0f,%.0f %.0fx%.0f) desk=%dx%d px_to_pt=%.3f\n",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            desk_w, desk_h, (double)g_px_to_pt);
    fflush(stderr);
}

/* Called from Swift (MetalBackedView) with the presentation area in
 * window coordinates — same geometry contract as the Metal host view. */
/* Called from Swift (MetalBackedView.applyDisplayMode) with the rect its
 * display mode laid the guest display out in, in the compositor view's own
 * points (the compositor frame is that view's bounds). `set` 0 clears it and
 * the desktop goes back to an aspect fit of the whole frame. */
void winios_set_desktop_rect(double x, double y, double w, double h, int set) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect r = CGRectMake(x, y, w, h);
        if (g_desk_rect_set == (set != 0) && (!set || CGRectEqualToRect(g_desk_rect, r))) return;
        g_desk_rect = r;
        g_desk_rect_set = set != 0;
        winios_layout_compositor();
    });
}

void winios_set_compositor_frame(double x, double y, double w, double h) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect f = CGRectMake(x, y, w, h);
        /* layoutSubviews storms identical frames — skip no-op relayouts */
        if (g_comp_frame_set && CGRectEqualToRect(g_comp_frame, f)) return;
        g_comp_frame = f;
        g_comp_frame_set = YES;
        winios_layout_compositor();
    });
}

/* Library front end (Library.swift): a desktop session's compositor view sits
 * on the app window above the library and keeps showing the last frame after
 * the session ended, so the library hides it then and shows it again for the
 * next session. Returns 1 when there was a view to change. */
int winios_compositor_set_hidden(int hidden) {
    if (!g_compositor_view) return 0;
    if (g_comp_game) {   /* an ended game session's windows go away */
        if (!hidden) return 0;
        dispatch_async(dispatch_get_main_queue(), ^{ winios_drop_compositor("session ended"); });
        return 1;
    }
    BOOL h = hidden ? YES : NO;
    if (NSThread.isMainThread) {
        if (g_compositor_view.hidden == h) return 0;
        g_compositor_view.hidden = h;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ g_compositor_view.hidden = h; });
    }
    return 1;
}

/* Main thread only. A window point (points) to desktop pixels through the same
 * mapping winios_layout_compositor placed the desktop with, for the front end's
 * Touch pointer mode in desktop sessions. Returns 0 when there is no desktop. */
int winios_desktop_point_from_window(double wx, double wy, int *px, int *py) {
    /* the live guest size, as winios_layout_compositor uses: the two must
     * agree or a touch lands somewhere the desktop is not */
    int desk_w = 0, desk_h = 0;
    winios_screen_size(&desk_w, &desk_h);
    if (desk_w <= 0) desk_w = 1024;
    if (desk_h <= 0) desk_h = 768;
    if (px) *px = 0;
    if (py) *py = 0;
    if (!g_compositor_view || g_px_to_pt <= 0) return 0;
    CGRect f = g_compositor_view.frame;
    /* a tap on a fitted window (winios_desktop_fit) lands in that window's
     * own client pixels */
    if (g_fit_key && CGRectContainsPoint(g_fit_view_pt, CGPointMake(wx - f.origin.x, wy - f.origin.y))) {
        CGFloat k = g_fit_client_px.size.width / g_fit_view_pt.size.width;
        if (px) *px = (int)(g_fit_client_px.origin.x + (wx - f.origin.x - g_fit_view_pt.origin.x) * k);
        if (py) *py = (int)(g_fit_client_px.origin.y + (wy - f.origin.y - g_fit_view_pt.origin.y) * k);
        return 1;
    }
    double x = (wx - f.origin.x - g_desk_origin.x) / g_px_to_pt;
    double y = (wy - f.origin.y - g_desk_origin.y) / WINIOS_PX_TO_PT_Y;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > desk_w - 1) x = desk_w - 1;
    if (y > desk_h - 1) y = desk_h - 1;
    if (px) *px = (int)x;
    if (py) *py = (int)y;
    return 1;
}

/* GAME-MODE WINDOWS. A game's launcher or message box (Ghost of Tsushima's
 * Play / Options box, its "No installed graphics card" dialog) is a GDI
 * window; outside desktop mode nothing drew it, so the game sat waiting for a
 * click on something invisible. In a game session the compositor view is
 * created too, as a transparent overlay: no backdrop, no letterbox colour, no
 * touches (userInteractionEnabled = NO), laid out in the same game rect the
 * front end publishes (winios_set_desktop_rect), which is the rect
 * MetalBackedView maps touches through -- a tap lands where the window is
 * drawn. Only top-level windows reach it (driver_ios.c), and a
 * window is drawn only if it does not cover the whole guest desktop and does
 * not present through Metal (winios_note_game_metal_hwnd): a game's own
 * window never covers its picture, and God of War's (full-desktop) window is
 * never drawn. MADEIRA_GAME_WINDOWS=0 turns it off (both sides). */
static NSMutableSet<NSNumber *> *g_game_metal;  /* game mode: hwnds presenting through Metal */

static int winios_desktop_session(void) {
    /* read every time: one app run can hold desktop and game sessions */
    const char *dm = getenv("MADEIRA_DESKTOP");
    return dm && *dm == '1';
}

static int winios_game_windows_enabled(void) {
    const char *e = getenv("MADEIRA_GAME_WINDOWS");
    return !(e && *e == '0');
}

/* A window whose rect covers the whole guest desktop: a game's own window. */
static BOOL winios_covers_desktop(CGRect px) {
    int dw = 0, dh = 0;
    winios_screen_size(&dw, &dh);
    if (dw <= 0 || dh <= 0) return NO;
    return px.origin.x <= 0 && px.origin.y <= 0
        && px.origin.x + px.size.width >= dw && px.origin.y + px.size.height >= dh;
}

static void winios_forget_cursor_layer(void);   /* cursor section, below */

/* main thread only. Removes the compositor view and every window layer. */
static void winios_drop_compositor(const char *why) {
    if (!g_compositor_view) return;
    winios_forget_cursor_layer();
    for (CALayer *l in g_layers.allValues) [l removeFromSuperlayer];
    [g_layers removeAllObjects];
    [g_px_rects removeAllObjects];
    [g_surf_sizes removeAllObjects];
    [g_metal_layers removeAllObjects];
    [g_client_rects removeAllObjects];
    g_fit_key = nil;
    [g_compositor_view removeFromSuperview];
    g_compositor_view = nil;
    g_desk_bg = nil;
    fprintf(stderr, "[winios] %s compositor removed (%s)\n", g_comp_game ? "game-mode" : "desktop", why);
    fflush(stderr);
    g_comp_game = NO;
}

/* main thread only. Is this window drawn by the game overlay? Removes its
 * layer when it is not. Desktop mode: always YES. */
static BOOL winios_game_window_shown(NSNumber *key) {
    if (!g_comp_game) return YES;
    NSValue *rv = g_px_rects[key];
    BOOL metal = [g_game_metal containsObject:key];
    if (!metal && rv && !winios_covers_desktop(rv.CGRectValue)) return YES;
    CALayer *l = g_layers[key];
    if (l) {
        [l removeFromSuperlayer];
        [g_layers removeObjectForKey:key];
        fprintf(stderr, "[winios] game window hwnd=0x%llx not drawn (%s)\n", key.unsignedLongLongValue,
                metal ? "presents through Metal" : rv ? "covers the guest desktop" : "no position yet");
        fflush(stderr);
    }
    return NO;
}

/* Called by IOSDisplayShim on a wine thread when a swapchain (D3D9/11/12)
 * takes the game layer for an HWND in a game session. */
void winios_note_game_metal_hwnd(void *hwnd) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *key = @((uintptr_t)hwnd);
        if (!g_game_metal) g_game_metal = [NSMutableSet new];
        if ([g_game_metal containsObject:key]) return;
        [g_game_metal addObject:key];
        fprintf(stderr, "[winios] game window hwnd=%p presents through Metal; its GDI surface is not drawn\n", hwnd);
        fflush(stderr);
        if (g_comp_game) (void)winios_game_window_shown(key);
    });
}

/* Called at every Wine session start (WineProcessBridge): a game session
 * starts with no overlay windows and no known Metal windows. */
void winios_session_reset(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_game_metal removeAllObjects];
        if (g_comp_game) winios_drop_compositor("new session");
    });
}

/* main thread only */
static void winios_ensure_compositor(void) {
    BOOL desk = winios_desktop_session();
    if (g_compositor_view) {
        if (g_comp_game == !desk) return;
        /* the other kind, left by an earlier session of this app run */
        winios_drop_compositor("session kind changed");
    }
    /* Desktop mode, or the game overlay above. The desktop compositor's
     * backdrop must never exist in a game session -- it would cover DXMT's
     * Metal layer (2026-07-06 Thumper regression). */
    if (!desk && !winios_game_windows_enabled()) return;
    if (!desk) {
        UIWindow *win = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
        if (!win) return;
        if (!g_layers) g_layers = [NSMutableDictionary new];
        if (!g_px_rects) g_px_rects = [NSMutableDictionary new];
        if (!g_surf_sizes) g_surf_sizes = [NSMutableDictionary new];
        g_compositor_view = [[UIView alloc] initWithFrame:win.bounds];
        g_compositor_view.userInteractionEnabled = NO;  /* touches fall through */
        g_compositor_view.clipsToBounds = YES;
        g_compositor_view.backgroundColor = UIColor.clearColor;
        g_compositor_view.opaque = NO;
        g_comp_game = YES;
        [win addSubview:g_compositor_view];
        winios_layout_compositor();
        fprintf(stderr, "[winios] game-mode window overlay attached (MADEIRA_GAME_WINDOWS=0 disables)\n");
        fflush(stderr);
        static id game_mode_observer;
        if (!game_mode_observer) {
            game_mode_observer = [[NSNotificationCenter defaultCenter]
                addObserverForName:MadeiraDisplayModeChangedNotification object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) { winios_layout_compositor(); }];
        }
        return;
    }
    UIWindow *win = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    if (!win) return;
    g_layers = [NSMutableDictionary new];
    g_px_rects = [NSMutableDictionary new];
    g_surf_sizes = [NSMutableDictionary new];
    g_compositor_view = [[UIView alloc] initWithFrame:win.bounds];
    g_compositor_view.userInteractionEnabled = NO;  /* touches fall through */
    g_compositor_view.clipsToBounds = YES;
    /* letterbox area: black, like the rest of a session's screen (the game
     * view's host and the library's session view are black); an 8 % grey
     * showed as grey bands around a fitted desktop. desktop area: classic
     * teal (until explorer's own background paint works) */
    g_compositor_view.backgroundColor = UIColor.blackColor;
    g_desk_bg = [CALayer layer];
    g_desk_bg.backgroundColor = [UIColor colorWithRed:0.0 green:0.502 blue:0.502 alpha:1.0].CGColor;
    [g_compositor_view.layer addSublayer:g_desk_bg];
    [win addSubview:g_compositor_view];
    winios_layout_compositor();
    fprintf(stderr, "[winios] compositor attached inside presentation frame\n");
    fflush(stderr);
    /* A guest display-mode change moves the desktop's size without moving
     * the presentation frame, so winios_set_compositor_frame (which skips a
     * no-op frame) never notices it: re-fit the desktop when win32u
     * publishes one (IOSDisplayShim posts this on the main queue). */
    static id mode_observer;
    if (!mode_observer) {
        mode_observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:MadeiraDisplayModeChangedNotification object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { winios_layout_compositor(); }];
    }
    /* Wedged-thread triage: sample every thread's stack every 20s from
     * an app-side timer — keeps firing even when all wine threads are
     * stuck (unlike the tree dump, which rides wine's event drain). */
    static dispatch_source_t stack_timer;
    if (!stack_timer) {
        stack_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                          dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(stack_timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                                  20 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(stack_timer, ^{ ios_dump_all_thread_stacks(); });
        dispatch_resume(stack_timer);
    }
}

/* main thread only */
static CALayer *winios_layer_for(HWND hwnd, bool create) {
    NSNumber *key = @((uintptr_t)hwnd);
    CALayer *l = g_layers[key];
    if (!l && create) {
        l = [CALayer layer];
        l.anchorPoint = CGPointMake(0, 0);
        l.magnificationFilter = kCAFilterNearest;
        l.opaque = YES;
        [g_compositor_view.layer addSublayer:l];
        g_layers[key] = l;
        fprintf(stderr, "[winios] layer created for hwnd=%p (%lu layers)\n",
                hwnd, (unsigned long)g_layers.count);
        fflush(stderr);
    }
    return l;
}

static void winios_remove_layer(HWND hwnd) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_layers) return;
        NSNumber *key = @((uintptr_t)hwnd);
        CALayer *l = g_layers[key];
        if (l) {
            [l removeFromSuperlayer];
            [g_layers removeObjectForKey:key];
            [g_px_rects removeObjectForKey:key];
        }
        CAMetalLayer *ml = g_metal_layers[key];
        if (ml) {
            [ml removeFromSuperlayer];
            [g_metal_layers removeObjectForKey:key];
            [g_client_rects removeObjectForKey:key];
            if (g_fit_key && [g_fit_key isEqual:key]) g_fit_key = nil;
            fprintf(stderr, "[winios] metal layer removed for hwnd=%p\n", hwnd);
            fflush(stderr);
        }
    });
}

/* ============================================================ *
 * S2-7: DXMT presentation into desktop windows
 * ============================================================
 *
 * In desktop mode a D3D11 app's swapchain gets a CAMetalLayer that is a
 * SUBLAYER of its window's compositor CALayer, framed to the window's
 * CLIENT rect. Sublayers render above the layer's own contents (the GDI
 * DIB), so the title bar / borders stay visible around the game while
 * the client area shows DXMT output. Core Animation composites the rest.
 * Game (non-desktop) mode keeps the fullscreen singleton layer via
 * IOSDisplayShim — none of this runs. */

/* DESKTOP FIT. A presenting window whose client area does not fit the wine
 * desktop (a 1920x1080 window on a 1280x720 desktop) was cropped: only its
 * top-left showed, under a title bar, which looked like a frozen,
 * non-fullscreen game. Its Metal layer is instead aspect-fitted to the whole
 * desktop, and taps and the arrow are mapped through the same rectangle so
 * the program still gets its own client coordinates. Main thread only.
 * MADEIRA_DESKTOP_FIT=0 crops. */
static int winios_desktop_fit_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) { const char *e = getenv("MADEIRA_DESKTOP_FIT"); enabled = !(e && e[0] == '0'); }
    return enabled;
}
static BOOL winios_desktop_fit(NSNumber *key, CAMetalLayer *ml, CGRect c) {
    int desk_w = 0, desk_h = 0;
    winios_screen_size(&desk_w, &desk_h);
    CGRect desk = CGRectMake(0, 0, desk_w, desk_h);
    BOOL outside = desk_w > 0 && desk_h > 0 && c.size.width >= 64 && c.size.height >= 64
        && !CGRectContainsRect(CGRectInset(desk, -8, -8), c);
    if (!winios_desktop_fit_enabled() || !outside || !ml.superlayer || !g_compositor_view) {
        if (g_fit_key && [g_fit_key isEqual:key]) g_fit_key = nil;
        return NO;
    }
    CGFloat k = MIN(desk_w / c.size.width, desk_h / c.size.height) * g_px_to_pt;
    CGSize sz = CGSizeMake(c.size.width * k, c.size.height * k);
    CGRect view = CGRectMake(g_desk_origin.x + (desk_w * g_px_to_pt - sz.width) / 2,
                             g_desk_origin.y + (desk_h * g_px_to_pt - sz.height) / 2, sz.width, sz.height);
    ml.frame = [ml.superlayer convertRect:view fromLayer:g_compositor_view.layer];
    BOOL changed = !g_fit_key || ![g_fit_key isEqual:key] || !CGRectEqualToRect(g_fit_client_px, c);
    g_fit_key = key; g_fit_client_px = c; g_fit_view_pt = view;
    static unsigned logged;
    if (changed && logged < 16) {
        logged++;
        fprintf(stderr, "[desktop-fit] hwnd=0x%llx client-px={%.0f,%.0f %.0fx%.0f} desk=%dx%d -> view=(%.1f,%.1f %.1fx%.1f)\n",
                key.unsignedLongLongValue, c.origin.x, c.origin.y, c.size.width, c.size.height, desk_w, desk_h,
                view.origin.x, view.origin.y, view.size.width, view.size.height);
    }
    return YES;
}
/* Desktop px -> compositor-view points through the fitted window, if any. */
static BOOL winios_desktop_fit_map(CGFloat x, CGFloat y, CGPoint *pt, CGFloat *scale) {
    if (!g_fit_key || g_fit_client_px.size.width <= 0 || !CGRectContainsPoint(g_fit_client_px, CGPointMake(x, y)))
        return NO;
    CGFloat k = g_fit_view_pt.size.width / g_fit_client_px.size.width;
    if (pt) *pt = CGPointMake(g_fit_view_pt.origin.x + (x - g_fit_client_px.origin.x) * k,
                              g_fit_view_pt.origin.y + (y - g_fit_client_px.origin.y) * k);
    if (scale) *scale = k;
    return YES;
}

/* main thread only — frame the metal sublayer to the client rect in the
 * parent (window) layer's coordinate space. Parent bounds are the window
 * rect in points, so client offset = (client_px - window_px) * scale. */
static void winios_place_metal_layer(NSNumber *key) {
    CAMetalLayer *ml = g_metal_layers[key];
    if (!ml) return;
    NSValue *wv = g_px_rects[key], *cv = g_client_rects[key];
    if (!wv || !cv) return;
    CGRect w = wv.CGRectValue, c = cv.CGRectValue;
    CGFloat s = g_px_to_pt;
    ml.frame = CGRectMake((c.origin.x - w.origin.x) * s,
                          (c.origin.y - w.origin.y) * WINIOS_PX_TO_PT_Y,
                          c.size.width * s, c.size.height * WINIOS_PX_TO_PT_Y);
    winios_desktop_fit(key, ml, c);
}

/* Called by IOSDisplayShim on a wine thread when DXMT creates a swapchain
 * view for an HWND in desktop mode. Returns the (unretained) CAMetalLayer;
 * the shim CFRetains it for DXMT's lifetime handling. */
CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd) {
    __block CAMetalLayer *result = nil;
    void (^make)(void) = ^{
        winios_ensure_compositor();
        if (!g_compositor_view) return;
        if (!g_metal_layers) g_metal_layers = [NSMutableDictionary new];
        NSNumber *key = @((uintptr_t)hwnd);
        CAMetalLayer *ml = g_metal_layers[key];
        if (!ml) {
            CALayer *win = winios_layer_for(hwnd, true);
            ml = [CAMetalLayer layer];
            ml.anchorPoint = CGPointMake(0, 0);
            ml.device = MTLCreateSystemDefaultDevice();
            ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
            ml.opaque = YES;
            g_metal_layers[key] = ml;
            [win addSublayer:ml];
            winios_place_metal_layer(key);
            if (CGRectIsEmpty(ml.frame) && !CGRectIsEmpty(win.bounds))
                ml.frame = win.bounds;   /* client rect not delivered yet */
            fprintf(stderr, "[winios] metal layer created for hwnd=%p frame=(%.0f,%.0f %.0fx%.0f)\n",
                    hwnd, ml.frame.origin.x, ml.frame.origin.y,
                    ml.frame.size.width, ml.frame.size.height);
            fflush(stderr);
            winios_census_note_metal((HWND)hwnd);
        }
        result = ml;
    };
    if ([NSThread isMainThread]) make();
    else dispatch_sync(dispatch_get_main_queue(), make);
    return result;
}

/* Called from win32u's pWindowPosChanged wrapper (wine thread).
 * x/y/w/h = visible rect, cx/cy/cw/ch = client rect, desktop pixels. */
void winios_window_frame(HWND hwnd, int x, int y, int w, int h, int visible,
                         int cx, int cy, int cw, int ch) {
    /* Here, not in the block below: the census asks win32u about the window,
     * which needs this Wine thread. No-op unless the app turned it on. */
    winios_census_note_frame(hwnd, x, y, w, h, visible);
    dispatch_async(dispatch_get_main_queue(), ^{
        winios_ensure_compositor();
        if (!g_compositor_view) return;
        NSNumber *key = @((uintptr_t)hwnd);
        if (g_comp_game) {   /* game-mode windows, see winios_game_window_shown */
            g_px_rects[key] = [NSValue valueWithCGRect:CGRectMake(x, y, w, h)];
            if (!winios_game_window_shown(key)) return;
        }
        CALayer *l = winios_layer_for(hwnd, true);
        g_px_rects[key] = [NSValue valueWithCGRect:CGRectMake(x, y, w, h)];
        if (!g_client_rects) g_client_rects = [NSMutableDictionary new];
        g_client_rects[key] = [NSValue valueWithCGRect:CGRectMake(cx, cy, cw, ch)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        l.frame = winios_layer_rect(x, y, w, h);
        l.hidden = !visible;
        /* a game-mode window whose bits came before its position is on
         * screen now -- the library's starting screen counts it */
        if (g_comp_game && visible && l.contents)
            atomic_fetch_add_explicit(&g_surface_present_count, 1, memory_order_relaxed);
        winios_apply_contents_rect(key, l);
        winios_place_metal_layer(key);
        [CATransaction commit];
    });
}

/* MADEIRA_DUMP_SURFACES=1: save each window's DIB as PNG under
 * Documents/surfdump/ — surf-<hwnd>-first.png once, then
 * surf-<hwnd>-latest.png at most every 2s. Ground truth for whether a
 * rendering bug is in the surface bits (wine paint path) or in the
 * compositor (crop/scale). */
/* ml493: write one surface to an explicitly named PNG. Used both by the
 * throttled first/latest dump and by the consecutive-frame burst, which
 * needs frames that are ADJACENT in time — a 2s-throttled "latest" can
 * never show what changes between one present and the next. */
static void winios_dump_surface_named(NSData *data, int sw, int sh, int stride, NSString *name) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("winios.surfdump", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *dir = [docs stringByAppendingPathComponent:@"surfdump"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef img = CGImageCreate(sw, sh, 8, 32, stride, cs,
                                       kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                       dp, NULL, false, kCGRenderingIntentDefault);
        if (img) {
            NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (dest) {
                CGImageDestinationAddImage(dest, img, NULL);
                CGImageDestinationFinalize(dest);
                CFRelease(dest);
            }
            CGImageRelease(img);
        }
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
    });
}

static void winios_dump_surface_png(HWND hwnd, NSData *data, int sw, int sh, int stride) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("winios.surfdump", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        static NSMutableDictionary<NSNumber *, NSNumber *> *lastWrite;
        static NSMutableSet<NSNumber *> *wroteFirst;
        if (!lastWrite) { lastWrite = [NSMutableDictionary new]; wroteFirst = [NSMutableSet new]; }
        NSNumber *key = @((uintptr_t)hwnd);
        double now = CACurrentMediaTime();
        BOOL first = ![wroteFirst containsObject:key];
        NSNumber *lw = lastWrite[key];
        if (!first && lw && now - lw.doubleValue < 2.0) return;
        lastWrite[key] = @(now);
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *dir = [docs stringByAppendingPathComponent:@"surfdump"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef img = CGImageCreate(sw, sh, 8, 32, stride, cs,
                                       kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                       dp, NULL, false, kCGRenderingIntentDefault);
        if (img) {
            NSString *name = [NSString stringWithFormat:@"surf-%p-%s.png", hwnd, first ? "first" : "latest"];
            NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (dest) {
                CGImageDestinationAddImage(dest, img, NULL);
                if (CGImageDestinationFinalize(dest) && first) {
                    [wroteFirst addObject:key];
                    fprintf(stderr, "[winios] surfdump wrote %s (%dx%d)\n", name.UTF8String, sw, sh);
                    fflush(stderr);
                }
                CFRelease(dest);
            }
            CGImageRelease(img);
        }
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
    });
}

/* ml536: dump Chromium's SOURCE bitmap, straight from dibdrv_PutImage.
 *
 * The paired surfdump is written from the window surface AFTER the blit. Having
 * both lets one offline comparison answer what five srcwatch iterations could
 * not: whether the displaced panel is already present in Chromium's input, or
 * appears only in our output.
 *
 * Deliberately reuses winios_dump_surface_named, so both PNGs are produced by
 * the identical encoder — the only difference between them is the buffer, which
 * is the whole point. Bounded and gated on MADEIRA_DUMP_SURFACES so it costs
 * nothing unless we are hunting. */
/* ml537: the src dump and the surface dump must be PAIRED, or the comparison
 * is worthless. They fire at different points — src at blit time from
 * dibdrv_PutImage, surface at flush time from winios_surface_present, gated by
 * its own independent MADEIRA_SURF_SEQ burst logic — so an unpaired src-003 and
 * seq-... could easily be different FRAMES, and any difference between them
 * would be frame-to-frame change rather than corruption. That would have looked
 * exactly like a finding.
 *
 * So: a src dump arms `wph_pair`, and the very next present of any window dumps
 * its surface under the SAME pair number. That is the tightest coupling
 * available from these two call sites.
 * ⚠️ Still not atomic — more than one blit can land between presents, so the
 * surface may reflect a later blit than the src. Treat a difference as a lead,
 * not proof, unless the src is clean and the surface is grossly displaced. */
static volatile int wph_pair;          /* pair id armed by a src dump, 0 = none */
static volatile int wph_pair_n;

void winios_dump_srcbits(const void *bits, int w, int h, int stride) {
    static int on = -1;
    if (on < 0) on = getenv("MADEIRA_DUMP_SURFACES") != NULL;
    if (!on || !bits || w <= 0 || h <= 0 || stride < w * 4) return;
    if (wph_pair) return;              /* a pair is already awaiting its surface */
    /* ml542: was 12. Sample size is now the binding constraint on the render
     * hunt: 9 captured frames yielded exactly ONE clear instance of the defect
     * (adjacent tiles carrying duplicate content), which is too thin to say
     * whether the duplication is always +1 tile and always in the same
     * direction. 120 SRC frames is ~1.2 MB of PNG — nothing against a 4096 MB
     * jetsam ceiling — and the offline tile-provenance classifier scores a whole
     * run in seconds. */
    if (wph_pair_n >= 120) return;
    @autoreleasepool {
        int id = ++wph_pair_n;
        NSData *d = [NSData dataWithBytes:bits length:(size_t)stride * h];
        winios_dump_surface_named(d, w, h, stride,
            [NSString stringWithFormat:@"pair-%03d-SRC-%dx%d.png", id, w, h]);
        dprintf(STDERR_FILENO,
                "[srcdump] pair=%03d SRC %dx%d stride=%d bits=%p — awaiting surface rev=ml537\n",
                id, w, h, stride, bits);
        wph_pair = id;                 /* arm: next present completes the pair */
    }
}

/* Called from winios_surface_flush (wine thread) with the surface's
 * whole DIB. Copy immediately — `bits` is only valid for this call.
 *
 * ml1028: returns 0 if the snapshot could not be allocated, 1 otherwise.
 *
 * This used to be void and took its copy with [NSData dataWithBytes:], whose
 * allocator is NSAllocateMemoryPages -- which THROWS on failure and cannot
 * return nil. rdr95 and rdr98 both died here, identically:
 *
 *   [surf-flush] #48 hwnd=0x80054 rect={0,0,1024,640} dirty={0,0,968,572}
 *   *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
 *       reason: '*** NSAllocateMemoryPages(2621440) failed'
 *
 * 1024 * 640 * 4 = 2,621,440 exactly. The uncaught ObjC exception killed the
 * pseudo-process, whose teardown took down the PROCESS-WIDE remote-Metal
 * socket, after which the render thread spun in _MTLCommandBuffer_commit
 * forever -- a 2.5MB copy failing turned into a whole-app hang.
 *
 * Note what it is NOT: the census at that moment reports free=609 MB with a
 * 366 MB largest hole, so this is not an exhausted map. (The "NO GAP FITS"
 * verdict elsewhere in the log belongs to a different, 8960 MB request.) It is
 * a 2.5MB allocation failing through one specific allocator.
 *
 * So: allocate the snapshot with a CHECKED allocator, hand ownership to NSData
 * with freeWhenDone (CGDataProviderCreateWithCFData retains the CFData, so the
 * bytes outlive this call for as long as any consumer holds the image), and on
 * failure report it. Wine's dce.c only calls reset_bounds() when flush returns
 * TRUE, so returning 0 PRESERVES the dirty region and the frame is repainted
 * later -- no lost damage, and nothing dies.
 *
 * WARNING: the snapshot must OWN its bytes. Wrapping `bits` with no-copy would
 * be cheaper and wrong: it is only valid for the duration of this call. */
int winios_surface_present(HWND hwnd, int dx, int dy, int dw, int dh,
                           int sw, int sh, int stride, const void *bits) {
    if (sw <= 0 || sh <= 0 || !bits) return 1;   /* nothing to paint */
    winios_census_note_present(hwnd);   /* no-op unless the census is on */
    size_t snap_len = (size_t)stride * (size_t)sh;
    void *snap = malloc(snap_len);
    if (!snap) {
        static unsigned nfail;
        unsigned n = ++nfail;
        if (n <= 16 || (n % 256) == 0)
            dprintf(STDERR_FILENO,
                    "[surf-snap] ml1028 #%u ALLOC FAILED %zu bytes (%dx%d stride=%d "
                    "hwnd=%p) -- returning failure so Wine KEEPS the dirty bounds and "
                    "repaints; this used to throw and kill the pseudo-process\n",
                    n, snap_len, sw, sh, stride, hwnd);
        return 0;
    }
    memcpy(snap, bits, snap_len);
    /* freeWhenDone:YES => NSData calls free() on `snap`, which is what malloc
     * wants. Ownership now belongs to `data` and, through it, to every CGImage
     * CoreGraphics builds from it. */
    NSData *data = [NSData dataWithBytesNoCopy:snap length:snap_len freeWhenDone:YES];
    static int dumpSurf = -1;
    if (dumpSurf < 0) dumpSurf = getenv("MADEIRA_DUMP_SURFACES") != NULL;
    /* ml537: complete an armed src/surface pair with the FIRST present after the
     * blit, so the two PNGs are as close to the same frame as these call sites
     * allow. Named identically apart from SRC/SURF. */
    if (dumpSurf && wph_pair) {
        int id = wph_pair;
        wph_pair = 0;
        winios_dump_surface_named(data, sw, sh, stride,
            [NSString stringWithFormat:@"pair-%03d-SURF-hwnd%p-%dx%d.png", id, hwnd, sw, sh]);
        dprintf(STDERR_FILENO,
                "[srcdump] pair=%03d SURF hwnd=%p %dx%d stride=%d — pair COMPLETE rev=ml537\n",
                id, hwnd, sw, sh, stride);
    }
    if (dumpSurf) winios_dump_surface_png(hwnd, data, sw, sh, stride);

    /* ml493: PER-HWND accounting. The counter used to be global, so a
     * window created late (the login popup, hwnd 0x1010a) had every one of
     * its early presents fall past the first-12 window and was only ever
     * sampled 1-in-200 — which is why "was this window ever painted in
     * full?" could not be answered from ml493's log at all. Identity must
     * be the window, not a process-wide sequence number.
     *
     * Also drives MADEIRA_SURF_SEQ: bursts of N CONSECUTIVE frames, so the
     * black regions that change every frame can be measured frame-to-frame
     * offline. The 2s-throttled first/latest dump structurally cannot show
     * that. Dirty rect goes in the filename so each frame carries the one
     * fact needed to test "is the black exactly the damage rect?".
     */
    static pthread_mutex_t seq_lock = PTHREAD_MUTEX_INITIALIZER;
    enum { WINIOS_SEQ_SLOTS = 24 };
    static struct { HWND hwnd; unsigned n; unsigned burst_left; unsigned burst_idx;
                    unsigned bursts_done; double next_burst;
                    unsigned sent_rounds; } seq[WINIOS_SEQ_SLOTS];
    static int seq_used;
    static int seqFrames = -1, seqBursts, seqMinDim;
    if (seqFrames < 0) {
        const char *e = getenv("MADEIRA_SURF_SEQ");
        seqFrames = e ? atoi(e) : 0;
        if (seqFrames > 32) seqFrames = 32;
        seqBursts = 14;       /* ml496: 25s/6 bursts only ever caught the
                               * window's blank startup — the interactive
                               * frames, where the black moves, were never
                               * sampled. 6s x 14 covers them. */
        seqMinDim = 200;      /* skip taskbar/tooltip-sized windows */
    }

    unsigned mycnt = 0, dumpIdx = 0;
    BOOL wantDump = NO;
    pthread_mutex_lock(&seq_lock);
    int s = -1;
    for (int i = 0; i < seq_used; i++) if (seq[i].hwnd == hwnd) { s = i; break; }
    if (s < 0 && seq_used < WINIOS_SEQ_SLOTS) { s = seq_used++; seq[s].hwnd = hwnd; }
    if (s >= 0) {
        mycnt = ++seq[s].n;
        if (seqFrames > 0 && sw >= seqMinDim && sh >= seqMinDim) {
            double now = CACurrentMediaTime();
            if (seq[s].burst_left == 0 && seq[s].bursts_done < (unsigned)seqBursts
                && now >= seq[s].next_burst) {
                seq[s].burst_left = (unsigned)seqFrames;
                seq[s].burst_idx = 0;
                seq[s].bursts_done++;
                seq[s].next_burst = now + 6.0;
            }
            if (seq[s].burst_left > 0) {
                seq[s].burst_left--;
                dumpIdx = seq[s].bursts_done * 100 + seq[s].burst_idx++;
                wantDump = YES;
            }
        }
    }
    pthread_mutex_unlock(&seq_lock);

    if (wantDump) {
        winios_dump_surface_named(data, sw, sh, stride,
            [NSString stringWithFormat:@"seq-%p-%03u-d%d_%d_%dx%d.png",
                                       hwnd, dumpIdx, dx, dy, dw, dh]);

        /* ml499: ALPHA census on the very bytes we just dumped. The PNGs are
         * encoded kCGImageAlphaNoneSkipFirst, so they physically cannot show
         * whether a black pixel is opaque black or TRANSPARENT — and that is
         * now the whole question. Chromium composites onto a transparent
         * background; a BGRX surface that ignores the alpha byte renders
         * transparent as RGB(0,0,0). Glyphs are opaque and would survive,
         * which is exactly the text-lands-fill-doesn't asymmetry observed.
         *
         * blkA0 vs blkA255 decides it outright:
         *   black & alpha==0   -> Chromium never painted an opaque background
         *                         there; we must composite over one.
         *   black & alpha==255 -> genuinely painted opaque black; alpha is
         *                         innocent and the hunt moves elsewhere.
         * Subsampled every 4th pixel — this runs on a paint path. */
        const uint8_t *px = (const uint8_t *)bits;
        unsigned long n = 0, a0 = 0, a255 = 0, blk = 0, blkA0 = 0, blkA255 = 0;
        for (int y = 0; y < sh; y += 2) {
            const uint8_t *row = px + (size_t)y * stride;
            for (int x = 0; x < sw; x += 2) {
                const uint8_t *p = row + (size_t)x * 4;   /* B,G,R,A */
                uint8_t a = p[3];
                int is_black = (p[0] | p[1] | p[2]) == 0;
                n++;
                if (a == 0) a0++; else if (a == 255) a255++;
                if (is_black) { blk++; if (a == 0) blkA0++; else if (a == 255) blkA255++; }
            }
        }
        if (n) fprintf(stderr, "[surf-alpha] hwnd=%p seq=%03u black=%.1f%% "
                       "a0=%.1f%% a255=%.1f%% | of black: a0=%.1f%% a255=%.1f%% rev=ml499\n",
                       hwnd, dumpIdx, 100.0 * blk / n, 100.0 * a0 / n, 100.0 * a255 / n,
                       blk ? 100.0 * blkA0 / blk : 0.0, blk ? 100.0 * blkA255 / blk : 0.0);
        fflush(stderr);
    }

    /* ml496: log EVERY damage rect for big windows (bounded). The black
     * regions are the initial blank full-window paints that were never
     * re-damaged, so the open question is whether the full viewport is ever
     * damaged again after the page renders — and a 1-in-200 sample can
     * never answer that. Replaying the full damage history offline shows
     * exactly which pixels were never covered. */
    /* ml502 SENTINEL — disambiguates the ml501 alpha result.
     *
     * A freshly created window surface is ZERO-filled: RGB 0 AND alpha 0.
     * Premultiplied transparent is ALSO RGB 0, alpha 0. So "of black:
     * a0=100%" is equally consistent with "Chromium wrote transparent" and
     * "nobody ever wrote these pixels" — the alpha census cannot separate
     * them, and I reported the first as settled when the data did not
     * support it.
     *
     * Fix: after each flush, stamp every currently-zero pixel with a
     * sentinel. That leaves NO zero pixels behind, so the next flush
     * classifies every pixel with no bookkeeping at all:
     *     still SENTINEL -> Chromium never touched it
     *     back to ZERO   -> Chromium actively wrote transparent
     *     anything else  -> real content
     * The NSData copy above already happened, so dumps still show the
     * surface exactly as Chromium left it (surviving sentinels included).
     * Writes go to our own DIB while wine holds the surface lock, and only
     * ever to pixels that are currently invisible black. */
    static int sentinelMode = -1;
    if (sentinelMode < 0) sentinelMode = getenv("MADEIRA_SURF_SENTINEL") != NULL;
    if (sentinelMode && s >= 0 && sw >= 400 && sh >= 400 && seq[s].sent_rounds < 10) {
        const uint32_t SENT = 0x01FF00FFu;      /* B=FF G=00 R=FF A=01 */
        uint32_t *px = (uint32_t *)(uintptr_t)bits;
        unsigned long untouched = 0, rewritten_zero = 0, painted = 0, stamped = 0;
        for (int y = 0; y < sh; y++) {
            uint32_t *row = (uint32_t *)((char *)px + (size_t)y * stride);
            for (int x = 0; x < sw; x++) {
                uint32_t v = row[x];
                if (seq[s].sent_rounds) {
                    if (v == SENT) untouched++;
                    else if (v == 0) rewritten_zero++;
                    else painted++;
                }
                if (v == 0 || v == SENT) { row[x] = SENT; stamped++; }
            }
        }
        if (seq[s].sent_rounds)
            fprintf(stderr, "[surf-sentinel] hwnd=%p round=%u untouched=%lu "
                    "rewritten-zero=%lu painted=%lu (stamped=%lu) rev=ml502\n",
                    hwnd, seq[s].sent_rounds, untouched, rewritten_zero, painted, stamped);
        seq[s].sent_rounds++;
        fflush(stderr);
    }

    if (mycnt <= 16 || (mycnt % 200) == 0 ||
        (sw >= 400 && sh >= 400 && mycnt <= 2000)) {
        /* ml504: bits pointer + content signature per present.
         *
         * ml503 showed ~200k pixels changing across the WHOLE window while
         * the damage rect claimed a 56x52 spinner — the surface flips
         * wholesale between two states. This decides where the flip lives:
         *   bits CONSTANT, sig alternating -> one buffer being rewritten
         *       with stale content; the defect is upstream in Chromium's
         *       damage preservation.
         *   bits ALTERNATING               -> two buffers are reaching us
         *       and the handoff is ours to fix.
         * Signature is a sparse FNV over a fixed grid so it is cheap enough
         * to run on every present and still changes when any region flips. */
        uint32_t sig = 2166136261u;
        {
            const uint8_t *b = (const uint8_t *)bits;
            int ystep = sh > 64 ? sh / 64 : 1, xstep = sw > 64 ? sw / 64 : 1;
            for (int y = 0; y < sh; y += ystep) {
                const uint32_t *row = (const uint32_t *)(b + (size_t)y * stride);
                for (int x = 0; x < sw; x += xstep) {
                    sig ^= row[x];
                    sig *= 16777619u;
                }
            }
        }
        fprintf(stderr, "[winios] present hwnd=%p #%u dirty=(%d,%d %dx%d) surf=%dx%d "
                "bits=%p sig=%08x rev=ml504\n",
                hwnd, mycnt, dx, dy, dw, dh, sw, sh, bits, sig);
        fflush(stderr);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        winios_ensure_compositor();
        /* ml1028: this block is dispatch_block_t (void). The snapshot copy has
         * already SUCCEEDED by the time we get here, so the function's own
         * result stays 1 -- only the presentation is skipped. `data` is captured
         * and released with the block, which is exactly why the snapshot has to
         * own its bytes: this runs AFTER winios_surface_present has returned. */
        if (!g_compositor_view) return;
        /* game mode draws a window only once its position says it is not
         * the game's own (winios_game_window_shown); bits that arrive before
         * any position wait in a hidden layer for winios_window_frame. */
        BOOL pending = NO;   /* game mode, position not known yet: keep the bits, hidden */
        if (g_comp_game) {
            NSNumber *k = @((uintptr_t)hwnd);
            if (!g_px_rects[k] && ![g_game_metal containsObject:k]) pending = YES;
            else if (!winios_game_window_shown(k)) return;
        }
        CALayer *l = winios_layer_for(hwnd, true);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        /* GDI 32bpp DIB = BGRX little-endian, no alpha */
        CGImageRef img = CGImageCreate(sw, sh, 8, 32, stride, cs,
                                       kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                       dp, NULL, false, kCGRenderingIntentDefault);
        if (img) {
            NSNumber *key = @((uintptr_t)hwnd);
            l.contents = (__bridge id)img;
            if (pending) l.hidden = YES;   /* winios_window_frame decides */
            else atomic_fetch_add_explicit(&g_surface_present_count, 1, memory_order_relaxed);
            g_surf_sizes[key] = [NSValue valueWithCGSize:CGSizeMake(sw, sh)];
            if (!pending && CGRectIsEmpty(l.frame)) {
                /* frame not delivered yet — place at surface size */
                g_px_rects[key] = [NSValue valueWithCGRect:CGRectMake(0, 0, sw, sh)];
                l.frame = winios_layer_rect(0, 0, sw, sh);
            }
            winios_apply_contents_rect(key, l);
            CGImageRelease(img);
        }
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
    });
    return 1;
}

/* ============================================================ *
 * S2 trackpad pointer + rendered cursor
 * ============================================================ */

static CALayer *g_cursor_layer;

static UIImage *winios_cursor_image(void) {
    static UIImage *img;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize sz = CGSizeMake(14, 21);
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
        img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx __unused) {
            /* classic arrow: white fill, black outline */
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(0.5, 0.5)];
            [p addLineToPoint:CGPointMake(0.5, 15.5)];
            [p addLineToPoint:CGPointMake(4.2, 12.2)];
            [p addLineToPoint:CGPointMake(7.0, 19.0)];
            [p addLineToPoint:CGPointMake(9.6, 17.8)];
            [p addLineToPoint:CGPointMake(6.8, 11.1)];
            [p addLineToPoint:CGPointMake(11.8, 10.7)];
            [p closePath];
            [[UIColor whiteColor] setFill];
            [p fill];
            [[UIColor blackColor] setStroke];
            p.lineWidth = 1.0;
            [p stroke];
        }];
    });
    return img;
}

/* Wine cursor image state (px). w==0 → builtin arrow fallback. */
static int g_cur_w, g_cur_h, g_cur_hx, g_cur_hy;
static CGPoint g_cursor_pos_px;

/* The cursor is a sublayer of the compositor view; a dropped view takes it. */
static void winios_forget_cursor_layer(void) {
    [g_cursor_layer removeFromSuperlayer];
    g_cursor_layer = nil;
}

/* main thread only */
static void winios_ensure_cursor_layer(void) {
    if (g_cursor_layer || !g_compositor_view || g_comp_game) return;
    UIImage *img = winios_cursor_image();
    g_cursor_layer = [CALayer layer];
    g_cursor_layer.zPosition = 10000;   /* above every window layer */
    g_cursor_layer.anchorPoint = CGPointMake(0, 0);
    g_cursor_layer.contents = (id)img.CGImage;
    g_cursor_layer.bounds = CGRectMake(0, 0, img.size.width, img.size.height);
    g_cursor_layer.magnificationFilter = kCAFilterNearest;
    [g_compositor_view.layer addSublayer:g_cursor_layer];
}

/* main thread only — place (and size) the cursor at its stored px pos,
 * honoring the wine cursor's hotspot when one is set */
static void winios_cursor_place(void) {
    if (!g_cursor_layer) return;
    CGFloat x = g_cursor_pos_px.x, y = g_cursor_pos_px.y;
    CGPoint fitted; CGFloat k = 0;
    if (winios_desktop_fit_map(x, y, &fitted, &k)) {   /* over a fitted window */
        if (g_cur_w > 0) {
            g_cursor_layer.bounds = CGRectMake(0, 0, g_cur_w * k, g_cur_h * k);
            g_cursor_layer.position = CGPointMake(fitted.x - g_cur_hx * k, fitted.y - g_cur_hy * k);
        } else {
            g_cursor_layer.position = fitted;
        }
        return;
    }
    if (g_cur_w > 0) {
        g_cursor_layer.bounds = CGRectMake(0, 0, g_cur_w * g_px_to_pt, g_cur_h * g_px_to_pt);
        g_cursor_layer.position = CGPointMake(g_desk_origin.x + (x - g_cur_hx) * g_px_to_pt,
                                              g_desk_origin.y + (y - g_cur_hy) * WINIOS_PX_TO_PT_Y);
    } else {
        g_cursor_layer.position = CGPointMake(g_desk_origin.x + x * g_px_to_pt,
                                              g_desk_origin.y + y * WINIOS_PX_TO_PT_Y);
    }
}

void winios_cursor_move(int x, int y) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!winios_desktop_session()) return;   /* game sessions: no drawn arrow */
        winios_ensure_compositor();
        if (!g_compositor_view) return;
        winios_ensure_cursor_layer();
        g_cursor_pos_px = CGPointMake(x, y);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        winios_cursor_place();
        [CATransaction commit];
    });
}

/* Called from winios_drv_set_cursor (wine thread) with a straight-alpha
 * BGRA image + hotspot whenever the wine cursor changes (arrow → I-beam
 * → resize arrows → app cursors). Copy before returning. */
void winios_cursor_set(unsigned int cur_id, int w, int h, int hot_x, int hot_y, const void *bgra) {
    if (w <= 0 || h <= 0 || !bgra) return;
    NSData *data = [NSData dataWithBytes:bgra length:(size_t)w * h * 4];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!winios_desktop_session()) return;   /* game sessions: no drawn arrow */
        winios_ensure_compositor();
        if (!g_compositor_view) return;
        winios_ensure_cursor_layer();
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs,
                                       kCGBitmapByteOrder32Little | kCGImageAlphaFirst,
                                       dp, NULL, false, kCGRenderingIntentDefault);
        if (img) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            g_cursor_layer.contents = (__bridge id)img;
            g_cur_w = w; g_cur_h = h; g_cur_hx = hot_x; g_cur_hy = hot_y;
            winios_cursor_place();
            [CATransaction commit];
            CGImageRelease(img);
        }
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
    });
}

void winios_cursor_show(int show) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_cursor_layer) g_cursor_layer.hidden = !show;
    });
}

/* Swift trackpad engine → wine. Absolute desktop-pixel coords; the
 * engine owns the cursor position. */
void winios_pointer(int x, int y, unsigned int flags, unsigned int data) {
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, flags, data);
    /* ml641: ONLY an ABSOLUTE move carries a position. A relative move carries a
     * DELTA, so handing it to the cursor layer would fling the drawn arrow to the
     * top-left corner on every event. Relative mode is mouse-look, where the game
     * has hidden the cursor anyway — there is nothing to draw, and skipping this
     * also drops a dispatch_async to the main queue per touch sample. */
    if ((flags & MOUSEEVENTF_MOVE) && (flags & MOUSEEVENTF_ABSOLUTE)) winios_cursor_move(x, y);
}

/* ============================================================ *
 * cursor (no cursor on iOS — these are no-ops)
 * ============================================================ */

void winios_pSetCursor(HWND hwnd, HCURSOR cursor) {
    /* iOS has no mouse cursor. Games that hide/show the cursor for
     * mouselook etc. just get nothing — fine for touch-driven input. */
}

void winios_pDestroyCursorIcon(HCURSOR cursor) {
    /* nothing to release; we never allocated anything for the cursor */
}
