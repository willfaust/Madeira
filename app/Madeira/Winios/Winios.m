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

static _Atomic unsigned long long g_surface_present_count;
unsigned long long winios_surface_present_count(void)
{
    return atomic_load_explicit(&g_surface_present_count, memory_order_relaxed);
}

/* The app-facing declarations. Including them here is the only thing that
 * keeps the two sides' signatures honest — everything else in this file is
 * reached through a bridging header the compiler never compares against these
 * definitions. */
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

/* ml981: WEDGED-THREAD TRIAGE MUST NOT DEPEND ON THE DESKTOP BEING UP.
 *
 * Sample every thread's stack every 20s from an app-side timer — it keeps
 * firing when all wine threads are stuck (unlike the tree dump, which rides
 * wine's event drain).  It used to be armed only from winios_ensure_compositor,
 * i.e. only when explorer's desktop attaches: a title started DIRECTLY got no
 * [thread-stacks] at all, so a hang in that mode had to be reconstructed from
 * register dumps and nm.  Device log t85 (direct launch) has zero
 * [thread-stacks] lines and t86 (same title, same wedge, via the desktop) has
 * 697 — and t86's answered the question in one line:
 *   port=0x1f9c3 "..." pc=Madeira`ios_verify_commit_zero+0x80 run=3 cpu=0
 *   port=0x10013 "wine-x18-exc" pc=__psynch_mutexwait ... (on virtual_mutex)
 * Arm it from the freeze detector's start instead, which runs in every mode. */
static void winios_stack_timer_start(void) {
    extern void ios_dump_all_thread_stacks(void);
    static dispatch_source_t stack_timer;
    if (stack_timer) return;
    stack_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(stack_timer, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                              20 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(stack_timer, ^{ ios_dump_all_thread_stacks(); });
    dispatch_resume(stack_timer);
    dprintf(STDERR_FILENO, "[thread-stacks] 20s sampler armed rev=ml981\n");
}

void winios_freeze_watch_start(void) {
    static int started;
    pthread_t th, sup;
    if (started) return;
    started = 1;
    winios_stack_timer_start();
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
 * ml1490 — top-level window census (see Winios.h)
 * ============================================================
 *
 * A game started through the Windows Steam client runs in a desktop session:
 * explorer, the client, its Chromium helper and their console hosts all put
 * windows up before the game does. Device logs 185-187 show the pattern: the
 * helper's console window (titled with its path), explorer's small tray window,
 * hidden client windows, and only later the game's own window, each from a
 * different thread. Nothing on the app side could tell those apart, so the
 * starting screen went away on the desktop's first GDI frame.
 *
 * The one fact that separates them generically is WHICH PROGRAM owns the
 * window. win32u knows the owning process id (get_window_thread, the same call
 * [winios-tree] makes) and the server knows every process's image path
 * (SystemProcessIdInformation, which asks it by id without opening a handle).
 * Both are read on the wine thread inside the WindowPosChanged hook, where
 * win32u itself has just made the same kind of calls; each process's name is
 * looked up once. The app decides what the names mean.
 *
 * Only while the app has switched it on (winios_window_census_enable), so a
 * normal session never pays a lookup. */
#define WINIOS_GA_PARENT     1
#define WINIOS_GWL_STYLE     (-16)
#define WINIOS_WS_CHILD      0x40000000u
#define WINIOS_WS_VISIBLE    0x10000000u
#define WINIOS_WS_MINIMIZE   0x20000000u
#define WINIOS_SYSTEM_PROCESS_ID_INFORMATION 88

/* win32u / ntdll unix entry points, linked into the same image. Declared by
 * hand for the reason given at the top of this file: the Wine headers collide
 * with Apple's. Wine's LONG/ULONG/DWORD/UINT are all 32-bit here. */
extern HWND NtUserGetAncestor(HWND hwnd, unsigned int type);
extern unsigned int get_window_thread(HWND hwnd, unsigned int *process);
extern int get_window_long(HWND hwnd, int offset);
extern int NtQuerySystemInformation(int info_class, void *info, unsigned int size, unsigned int *ret_size);

/* SYSTEM_PROCESS_ID_INFORMATION: a process id and a UNICODE_STRING the caller
 * points at its own buffer (Length must be 0 on input). */
struct winios_process_id_info {
    void *pid;
    unsigned short length, maximum;
    unsigned short *buffer;
};

static pthread_mutex_t g_census_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_census_on;
static struct winios_census_window g_census[WINIOS_CENSUS_MAX];
static int g_census_n;
#define WINIOS_CENSUS_IMAGES 48
static struct { unsigned int pid; int known; char image[48]; } g_census_images[WINIOS_CENSUS_IMAGES];
static int g_census_images_n;
static _Atomic unsigned g_census_failures;

/* The owning program's executable base name, lower case ASCII, "" when the
 * server could not name it. Cached per process id for the census's lifetime.
 * Wine thread only (the lookup is a server call). */
static int winios_census_image(unsigned int pid, char out[48]) {
    out[0] = 0;
    if (!pid) return 0;
    pthread_mutex_lock(&g_census_lock);
    for (int i = 0; i < g_census_images_n; i++) {
        if (g_census_images[i].pid != pid) continue;
        memcpy(out, g_census_images[i].image, 48);
        int known = g_census_images[i].known;
        pthread_mutex_unlock(&g_census_lock);
        return known;
    }
    pthread_mutex_unlock(&g_census_lock);

    unsigned short path[520];
    struct winios_process_id_info info = { (void *)(uintptr_t)pid, 0, sizeof(path) - sizeof(path[0]), path };
    unsigned int got = 0;
    int status = NtQuerySystemInformation(WINIOS_SYSTEM_PROCESS_ID_INFORMATION, &info, sizeof(info), &got);
    int known = 0;
    if (!status && info.buffer == path && info.length < sizeof(path)) {
        size_t n = info.length / sizeof(path[0]), start = 0, j = 0;
        for (size_t i = 0; i < n; i++) if (path[i] == '\\' || path[i] == '/') start = i + 1;
        for (size_t i = start; i < n && j < 47; i++) {
            unsigned short c = path[i];
            out[j++] = c >= 'A' && c <= 'Z' ? (char)(c + 32) : (c >= 32 && c < 127 ? (char)c : '?');
        }
        out[j] = 0;
        known = j > 0;
    } else if (atomic_fetch_add(&g_census_failures, 1) < 4) {
        fprintf(stderr, "[window-census] ml1490 no image name for pid %04x status=%08x\n", pid, (unsigned)status);
        fflush(stderr);
    }
    pthread_mutex_lock(&g_census_lock);
    if (g_census_images_n < WINIOS_CENSUS_IMAGES) {
        g_census_images[g_census_images_n].pid = pid;
        g_census_images[g_census_images_n].known = known;
        memcpy(g_census_images[g_census_images_n].image, out, 48);
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
    unsigned int style = (unsigned int)get_window_long(hwnd, WINIOS_GWL_STYLE);
    if (style & WINIOS_WS_CHILD) return;
    if (!NtUserGetAncestor(hwnd, WINIOS_GA_PARENT)) return;       /* the desktop itself */
    unsigned int pid = 0;
    get_window_thread(hwnd, &pid);
    char image[48];
    winios_census_image(pid, image);
    int shown = visible && (style & WINIOS_WS_VISIBLE) && !(style & WINIOS_WS_MINIMIZE) && w > 0 && h > 0;

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
    }
    pthread_mutex_unlock(&g_census_lock);
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
        fprintf(stderr, "[window-census] ml1490 %s\n", on ? "on" : "off");
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
/* ml663: a real mouse has five buttons and two wheels. These flags were never
 * reproduced here because a touchscreen cannot produce them; a Bluetooth mouse
 * can, and winios_drv_post_mouse passes dwFlags/mouseData straight through to
 * send_hardware_message, so nothing else has to change to carry them. */
#define MOUSEEVENTF_MIDDLEDOWN  0x0020
#define MOUSEEVENTF_MIDDLEUP    0x0040
#define MOUSEEVENTF_XDOWN       0x0080
#define MOUSEEVENTF_XUP         0x0100
#define MOUSEEVENTF_WHEEL       0x0800
#define MOUSEEVENTF_HWHEEL      0x1000
#define MOUSEEVENTF_ABSOLUTE    0x8000
#define WINIOS_XBUTTON1         0x0001
#define WINIOS_XBUTTON2         0x0002
/* ml663 — KEYEVENTF_EXTENDEDKEY, for the callers that must say so themselves.
 * driver_ios.c derives the scan code from the VK and sets this flag whenever
 * MAPVK_VK_TO_VSC_EX returns an 0xE0xx code (arrows, nav cluster, right
 * ctrl/alt, numpad divide) — so nearly every extended key is already correct
 * without the app's help. The exceptions are the keys that SHARE a virtual-key
 * with a non-extended twin and can only be told apart by the flag: numpad
 * Enter (VK_RETURN + E0) is the one a keyboard actually produces. */
#define KEYEVENTF_EXTENDEDKEY   0x0001

extern void winios_drv_post_mouse(int x, int y, unsigned int flags, unsigned int mouse_data, void *hwnd);
extern void winios_drv_post_key(unsigned short vk, unsigned int flags);
extern void winios_dump_window_tree(void);
extern void ios_dump_all_thread_stacks(void);

/* ml661 — THE RING IS DRAINED AT THE GAME'S FRAME RATE, NOT AT TOUCH RATE.
 *
 * The only consumer is winios_pProcessEvents, which runs inside the game's own
 * message pump (message_ios.c process_driver_events, reached from PeekMessage
 * and from GetAsyncKeyState's check_for_events). A game rendering at 15 fps
 * drains ~15×/s; while it streams a level it can be a *tenth* of that, so the
 * ring goes untouched for seconds at a time.
 *
 * The producer does not slow down to match. The aim stick is a CADisplayLink:
 * it posts one relative MOUSEEVENTF_MOVE per display frame, 60–120/s, for as
 * long as a thumb rests on it. So in a single 5-second stall the stick alone
 * offers ~600 events into a 256-slot ring.
 *
 * The old policy was DROP-NEWEST ("if (next != tail)" and otherwise silently
 * do nothing — the comment even claimed it dropped the oldest, which it never
 * did). Once the stick had filled the ring, every subsequent event was thrown
 * away, and the events being thrown away were the ones that matter: the key
 * DOWN from the movement stick, the key UP that stops walking, the LEFTDOWN
 * from a landscape button. That is the reported failure exactly — sticks and
 * buttons go dead mid-fight, and come back when the frame rate recovers and
 * the backlog finally drains. A half-dropped pair is worse still: a surviving
 * DOWN whose UP was dropped leaves the key stuck on inside the game.
 *
 * Fix, in two parts:
 *   1. Motion is COALESCED, not queued. Consecutive pure moves merge — relative
 *      deltas sum, absolute positions keep the newest. That is lossless for the
 *      game (a mouse that moved 300 counts over 5s is indistinguishable from
 *      one 300-count report at the moment of the read) and it means the stick
 *      can no longer fill anything: a whole stall collapses into one event.
 *   2. Transitions are NEVER dropped. A key down/up or a button down/up always
 *      gets a slot; if the ring is somehow still full, room is made by dropping
 *      the oldest *move*, which is the only event class that can be lost
 *      without the game ending up in a wrong state.
 *
 * A "pure move" is the only mergeable/droppable class: MOUSEEVENTF_MOVE with
 * (optionally) ABSOLUTE and nothing else. Note post_touch_down deliberately
 * posts MOVE|LEFTDOWN|ABSOLUTE as one event — the button bit makes it a
 * transition, so it is never touched by either mechanism.
 */
#define WINIOS_RING_SIZE 1024
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
    /* ml661 diagnostics — see winios_q_report */
    unsigned int pushed, coalesced, compactions, high_water;
    unsigned int dropped_move, dropped_trans;
    unsigned int keys_down;            /* driver-side held-key count */
    unsigned int keydown_mask[8];      /* 256 vk bits: which are held */
    /* ml663: bit0 left, bit1 right, bit2 middle, bit3 X1, bit4 X2. The three
     * new bits exist for exactly one reason — winios_release_all_keys() below
     * is the valve that un-sticks a button when the app loses the event that
     * would have released it, and a button it does not track is a button it
     * cannot un-stick. */
    unsigned int btn_mask;
    /* ml667: relative moves are the mouse-look signal and nothing counted them
     * separately — "pushed" mixes them with absolute moves, keys and buttons,
     * so a log could not say whether the camera stopped because the deltas
     * stopped being produced or because they stopped being delivered. */
    unsigned int rel_moves;
} g_input_q = { .lock = PTHREAD_MUTEX_INITIALIZER };

static inline int winios_ev_is_pure_move(const winios_input_event_t *e) {
    if (e->type != WINIOS_EV_MOUSE) return 0;
    if (!(e->flags & MOUSEEVENTF_MOVE)) return 0;
    /* any button / wheel bit makes it a transition */
    return (e->flags & ~(unsigned)(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE)) == 0;
}

/* Mergeable only into an identical KIND of move: relative into relative,
 * absolute into absolute. Mixing the two would turn a delta into a position. */
static inline int winios_ev_mergeable(const winios_input_event_t *a, const winios_input_event_t *b) {
    return winios_ev_is_pure_move(a) && winios_ev_is_pure_move(b) && a->flags == b->flags;
}

static inline void winios_ev_merge(winios_input_event_t *dst, const winios_input_event_t *src) {
    if (src->flags & MOUSEEVENTF_ABSOLUTE) {
        dst->x = src->x; dst->y = src->y;      /* a position: newest wins */
    } else {
        long long x = (long long)dst->x + src->x;   /* a delta: they add */
        long long y = (long long)dst->y + src->y;
        dst->x = (int)(x < -30000 ? -30000 : (x > 30000 ? 30000 : x));
        dst->y = (int)(y < -30000 ? -30000 : (y > 30000 ? 30000 : y));
    }
}

/* Merge every run of consecutive pure moves already sitting in the ring.
 * Only runs when the ring is full, so the O(n) rewrite is off the hot path.
 * Caller holds the lock. */
static winios_input_event_t g_q_scratch[WINIOS_RING_SIZE];
static void winios_q_compact(void) {
    unsigned int n = 0, i;
    for (i = g_input_q.tail; i != g_input_q.head; i = (i + 1) % WINIOS_RING_SIZE) {
        winios_input_event_t *s = &g_input_q.buf[i];
        if (n && winios_ev_mergeable(&g_q_scratch[n - 1], s)) {
            winios_ev_merge(&g_q_scratch[n - 1], s);
            g_input_q.coalesced++;
            continue;
        }
        g_q_scratch[n++] = *s;
    }
    memcpy(g_input_q.buf, g_q_scratch, n * sizeof(g_q_scratch[0]));
    g_input_q.tail = 0;
    g_input_q.head = n % WINIOS_RING_SIZE;
    g_input_q.compactions++;
}

/* Last resort when the ring is full of UNmergeable events: evict the oldest
 * pure move (alternating abs/rel moves defeat compaction but are still
 * individually expendable). Returns 0 if the ring holds nothing but
 * transitions — in which case the caller must not drop the newcomer either.
 * Caller holds the lock. */
static int winios_q_drop_oldest_move(void) {
    unsigned int i, j;
    for (i = g_input_q.tail; i != g_input_q.head; i = (i + 1) % WINIOS_RING_SIZE)
        if (winios_ev_is_pure_move(&g_input_q.buf[i])) break;
    if (i == g_input_q.head) return 0;
    for (j = i; j != g_input_q.tail; ) {           /* close the gap backwards */
        unsigned int p = (j + WINIOS_RING_SIZE - 1) % WINIOS_RING_SIZE;
        g_input_q.buf[j] = g_input_q.buf[p];
        j = p;
    }
    g_input_q.tail = (g_input_q.tail + 1) % WINIOS_RING_SIZE;
    g_input_q.dropped_move++;
    return 1;
}

static void winios_q_push_ev(unsigned int type, int x, int y, unsigned int flags, unsigned int data) {
    winios_input_event_t e = { type, x, y, flags, data };
    unsigned int next, depth;

    pthread_mutex_lock(&g_input_q.lock);
    g_input_q.pushed++;
    if (type == WINIOS_EV_MOUSE && (flags & MOUSEEVENTF_MOVE) &&
        !(flags & MOUSEEVENTF_ABSOLUTE))
        g_input_q.rel_moves++;                                  /* ml667 */

    /* Fast path: fold this move into the newest queued one. This is what keeps
     * a 120Hz stick from ever occupying more than a single slot. */
    if (g_input_q.head != g_input_q.tail) {
        unsigned int prev = (g_input_q.head + WINIOS_RING_SIZE - 1) % WINIOS_RING_SIZE;
        if (winios_ev_mergeable(&g_input_q.buf[prev], &e)) {
            winios_ev_merge(&g_input_q.buf[prev], &e);
            g_input_q.coalesced++;
            goto done;
        }
    }

    next = (g_input_q.head + 1) % WINIOS_RING_SIZE;
    if (next == g_input_q.tail) {                  /* full — reclaim, don't drop */
        winios_q_compact();
        next = (g_input_q.head + 1) % WINIOS_RING_SIZE;
    }
    if (next == g_input_q.tail && winios_q_drop_oldest_move())
        next = (g_input_q.head + 1) % WINIOS_RING_SIZE;

    if (next != g_input_q.tail) {
        g_input_q.buf[g_input_q.head] = e;
        g_input_q.head = next;
    } else {
        /* 1023 pending transitions and another one arriving. Physically
         * impossible from ten fingers; log every occurrence if it ever is. */
        if (winios_ev_is_pure_move(&e)) g_input_q.dropped_move++;
        else {
            g_input_q.dropped_trans++;
            fprintf(stderr, "[input] OVERFLOW dropped transition type=%u x=%d flags=0x%x "
                            "(total dropped_trans=%u)\n",
                    e.type, e.x, e.flags, g_input_q.dropped_trans);
            fflush(stderr);
        }
    }

done:
    depth = (g_input_q.head + WINIOS_RING_SIZE - g_input_q.tail) % WINIOS_RING_SIZE;
    if (depth > g_input_q.high_water) g_input_q.high_water = depth;
    pthread_mutex_unlock(&g_input_q.lock);
}

/* ml661 — one line naming the state of every input stage, so the next log
 * says which one failed instead of leaving it to be inferred. Emitted from
 * the drain at most once a second, and only when something is actually
 * happening (queued work, held keys, or a non-zero drop count). */
static void winios_q_report(unsigned int depth) {
    static double next_at;
    double now = CACurrentMediaTime();
    unsigned int i, pushed, coalesced, hw, dm, dt, comp, keys, btns, rel;
    char held[256];
    int n = 0;

    pthread_mutex_lock(&g_input_q.lock);
    pushed = g_input_q.pushed; coalesced = g_input_q.coalesced;
    hw = g_input_q.high_water; dm = g_input_q.dropped_move;
    dt = g_input_q.dropped_trans; comp = g_input_q.compactions;
    keys = g_input_q.keys_down; btns = g_input_q.btn_mask;
    rel = g_input_q.rel_moves;
    held[0] = 0;
    for (i = 0; i < 256 && n < (int)sizeof(held) - 8; i++)
        if (g_input_q.keydown_mask[i >> 5] & (1u << (i & 31)))
            n += snprintf(held + n, sizeof(held) - n, "%s%02x", n ? "," : "", i);
    pthread_mutex_unlock(&g_input_q.lock);

    if (now < next_at) return;
    if (!depth && !keys && !btns && !dm && !dt && !hw) return;
    next_at = now + 1.0;
    fprintf(stderr, "[input] ring depth=%u high=%u pushed=%u rel=%u coalesced=%u compact=%u "
                    "dropped(move=%u trans=%u) drv_keys=%u[%s] drv_btn=0x%x\n",
            depth, hw, pushed, rel, coalesced, comp, dm, dt, keys, held, btns);
    fflush(stderr);
}

/* ml665 — the same two counters winios_q_report prints, but readable on
 * demand so the app can attribute them to a measurement window of its own.
 * Takes the ring lock; called once per 10 s window from the mouse queue, so
 * the cost is not on any hot path. */
void winios_q_stats(unsigned int *pushed, unsigned int *coalesced) {
    pthread_mutex_lock(&g_input_q.lock);
    if (pushed)    *pushed    = g_input_q.pushed;
    if (coalesced) *coalesced = g_input_q.coalesced;
    pthread_mutex_unlock(&g_input_q.lock);
}

/* Public C entry points for Swift / UIKit gesture handlers.
 * Coordinates are in iOS view-local pixels; we scale to a fixed
 * 1024×768 logical surface inside winios_pProcessEvents to match
 * what DXMT swapchains use. */
/* ml — THE POSITION SOURCE FOR DIRECT-LAUNCH MODE'S DRAWN CURSOR.
 *
 * These three carry the app's touch-to-mouse bridge and, until now, never
 * touched the cursor layer at all — winios_pointer (below) is a SEPARATE
 * entry point (the desktop trackpad, the relative aim-stick/hardware-mouse
 * path) that already called winios_cursor_move/winios_cursor_advance on
 * its own ABSOLUTE/relative branches. A direct-launch program's ordinary
 * absolute tap-and-drag never went through winios_pointer, so it never
 * moved a drawn cursor even in desktop mode. winios_cursor_move is cheap
 * to call unconditionally (it no-ops with no layer/host to draw into,
 * exactly like winios_pointer's own callers already rely on) and mode-
 * correct on its own — see winios_cursor_host_layer — so no `#ifdef`/mode
 * check belongs here.
 *
 * NOT covered: a program that warps the cursor itself (SetCursorPos,
 * ClipCursor) without a touch in between — we have no signal for that and
 * the drawn arrow will not follow it. Acceptable for now; the next touch
 * (or a resumed drag) snaps it back, same as winios_cursor_advance's own
 * drift note below. */
void winios_post_touch_down(int x, int y) {
    fprintf(stderr, "[winios] post_touch_down x=%d y=%d\n", x, y); fflush(stderr);
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, 0);
    winios_cursor_move(x, y);
}

void winios_post_touch_move(int x, int y) {
    static unsigned cnt;
    if ((cnt++ % 30) == 0) {
        fprintf(stderr, "[winios] post_touch_move x=%d y=%d (n=%u)\n", x, y, cnt); fflush(stderr);
    }
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 0);
    winios_cursor_move(x, y);
}

void winios_post_touch_up(int x, int y) {
    fprintf(stderr, "[winios] post_touch_up x=%d y=%d\n", x, y); fflush(stderr);
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, 0);
    winios_cursor_move(x, y);
}

/* Key press bridge. vk = Windows virtual-key code, down = 1 for press,
 * 0 for release. Queued like mouse events; drained in pProcessEvents. */
/* ml663 — the general form. extra carries KEYEVENTF_* bits the CALLER knows and
 * the driver cannot derive: in practice only KEYEVENTF_EXTENDEDKEY, and only for
 * a key whose virtual-key code is shared with a non-extended twin (numpad Enter
 * vs Enter). driver_ios.c ORs its own MapVirtualKey-derived extended bit on top,
 * so passing 0 leaves every other extended key exactly as it behaves today.
 *
 * No driver change is required for this: winios_drv_post_key already takes the
 * queued flags as its starting value rather than rebuilding them. */
void winios_post_key_ex(int vk, int down, unsigned int extra) {
    /* A hardware keyboard makes this a hot path in a way ten fingers never
     * could (held WASD + a chord + autorepeat-free down/up pairs). Log the first
     * few and then one in 64 — the drain and drv_post_key log the same events
     * with the same thinning, so a transition is still traceable end to end. */
    static unsigned cnt;
    if (cnt++ < 16 || (cnt & 0x3f) == 0) {
        fprintf(stderr, "[winios] post_key vk=0x%x down=%d extra=0x%x (n=%u)\n",
                vk, down, extra, cnt);
        fflush(stderr);
    }
    winios_q_push_ev(WINIOS_EV_KEY, vk, 0, (down ? 0 : KEYEVENTF_KEYUP) | extra, 0);
}

void winios_post_key(int vk, int down) { winios_post_key_ex(vk, down, 0); }

BOOL winios_pProcessEvents(DWORD mask) {
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
    /* ml1110: the same dump, BOUNDED, in a direct launch. Log 90 could not say
     * what the windows around a blank client area even were — [win-pos] drops
     * children with an empty visible rect, and layers were created for three
     * hwnds that appear in no other line in the file. Three dumps name every
     * window, its style, its rects and its children once the overlay actually
     * has something on screen; after that it goes quiet, so this stays a
     * low-volume family rather than 30 lines every five seconds. */
    static unsigned direct_dumps;
    static double next_tree_dump;
    if (desk || (direct_dumps < 3 && winios_overlay_window_count() > 0)) {
        double now = CACurrentMediaTime();
        if (now >= next_tree_dump) {
            next_tree_dump = now + 5.0;
            if (!desk) direct_dumps++;
            winios_dump_window_tree();
        }
    }
    BOOL drained = FALSE;
    unsigned int depth = 0;
    /* ml1530: ONE DRAINER AT A TIME. Every GUI thread's message pump lands
     * here, and the pop below is locked but the post after it is not, so two
     * threads could each take one event and post them in the wrong order:
     * device log 198 drained a click as down then up and posted it to wine as
     * up then down (#267 flags=0x4, #268 flags=0x2), which leaves the button
     * held and the click lost (a dialog's accept did nothing). A thread that
     * finds another one draining returns; that one empties the whole queue in
     * order. MADEIRA_INPUT_DRAIN_ORDER=0 restores concurrent draining. */
    static pthread_mutex_t drain_lock = PTHREAD_MUTEX_INITIALIZER;
    static int ordered = -1;
    if (ordered < 0) {
        const char *o = getenv("MADEIRA_INPUT_DRAIN_ORDER");
        ordered = !(o && o[0] == '0');
    }
    if (ordered && pthread_mutex_trylock(&drain_lock) != 0) {
        static unsigned busy;
        if (busy++ < 4) { fprintf(stderr, "[input-order] ml1530 drain busy on another thread; left to it (n=%u)\n", busy); fflush(stderr); }
        return FALSE;
    }
    for (;;) {
        winios_input_event_t e;
        pthread_mutex_lock(&g_input_q.lock);
        if (g_input_q.tail == g_input_q.head) {
            pthread_mutex_unlock(&g_input_q.lock);
            break;
        }
        e = g_input_q.buf[g_input_q.tail];
        g_input_q.tail = (g_input_q.tail + 1) % WINIOS_RING_SIZE;
        depth = (g_input_q.head + WINIOS_RING_SIZE - g_input_q.tail) % WINIOS_RING_SIZE;
        /* ml661: the driver's own view of what is held. The app posts what it
         * believes; THIS is what wine was actually told. A mismatch between the
         * two ("[input] app held" vs "drv_keys_down") is the whole diagnosis. */
        if (e.type == WINIOS_EV_KEY && e.x >= 0 && e.x < 256) {
            unsigned int *w = &g_input_q.keydown_mask[e.x >> 5], b = 1u << (e.x & 31);
            if (e.flags & KEYEVENTF_KEYUP) {
                if (*w & b) { *w &= ~b; if (g_input_q.keys_down) g_input_q.keys_down--; }
            } else if (!(*w & b)) { *w |= b; g_input_q.keys_down++; }
        } else if (e.type == WINIOS_EV_MOUSE) {
            if (e.flags & MOUSEEVENTF_LEFTDOWN)   g_input_q.btn_mask |= 1u;
            if (e.flags & MOUSEEVENTF_LEFTUP)     g_input_q.btn_mask &= ~1u;
            if (e.flags & MOUSEEVENTF_RIGHTDOWN)  g_input_q.btn_mask |= 2u;
            if (e.flags & MOUSEEVENTF_RIGHTUP)    g_input_q.btn_mask &= ~2u;
            if (e.flags & MOUSEEVENTF_MIDDLEDOWN) g_input_q.btn_mask |= 4u;
            if (e.flags & MOUSEEVENTF_MIDDLEUP)   g_input_q.btn_mask &= ~4u;
            /* X1/X2 share one flag pair and are told apart by mouseData. */
            if (e.flags & MOUSEEVENTF_XDOWN)
                g_input_q.btn_mask |= (e.data & WINIOS_XBUTTON2) ? 16u : 8u;
            if (e.flags & MOUSEEVENTF_XUP)
                g_input_q.btn_mask &= ~((e.data & WINIOS_XBUTTON2) ? 16u : 8u);
        }
        pthread_mutex_unlock(&g_input_q.lock);

        /* ml661: this loop runs INSIDE the game's message pump, so its own cost
         * is frame time. A per-event fprintf+fflush with hundreds of coalesced
         * moves behind it was paying for the stall it was meant to diagnose.
         * Transitions still log every time — they are rare and they are the
         * events worth tracing; moves log one in 64. */
        if (e.type == WINIOS_EV_KEY || !winios_ev_is_pure_move(&e)) {
            fprintf(stderr, "[winios] drain type=%u x=%d y=%d flags=0x%x q=%u\n",
                    e.type, e.x, e.y, e.flags, depth);
            fflush(stderr);
        } else {
            static unsigned mv;
            if ((mv++ % 64) == 0) {
                fprintf(stderr, "[winios] drain move x=%d y=%d flags=0x%x q=%u (n=%u)\n",
                        e.x, e.y, e.flags, depth, mv);
                fflush(stderr);
            }
        }
        if (e.type == WINIOS_EV_KEY)
            winios_drv_post_key((unsigned short)e.x, e.flags);
        else
            winios_drv_post_mouse(e.x, e.y, e.flags, e.data, NULL);
        drained = TRUE;
    }
    if (ordered) pthread_mutex_unlock(&drain_lock);
    winios_q_report(depth);
    return drained;
}

/* ml661 — app-side release valve. Swift calls this when it decides the user
 * cannot possibly still be holding anything (app resigned active, the control
 * overlay was toggled away under a thumb, a gesture was cancelled): it posts a
 * key-up for every key the DRIVER still believes is down. The app's own
 * held-set is authoritative for intent, but this one closes the gap where the
 * app's down got through and its up did not. */
void winios_release_all_keys(void) {
    unsigned int vks[64];
    unsigned int i, n = 0, btns;

    pthread_mutex_lock(&g_input_q.lock);
    for (i = 0; i < 256 && n < 64; i++)
        if (g_input_q.keydown_mask[i >> 5] & (1u << (i & 31))) vks[n++] = i;
    btns = g_input_q.btn_mask;
    pthread_mutex_unlock(&g_input_q.lock);

    if (!n && !btns) return;
    fprintf(stderr, "[input] release_all: %u key(s) + btn_mask=0x%x still down driver-side\n",
            n, btns);
    fflush(stderr);
    for (i = 0; i < n; i++)
        winios_q_push_ev(WINIOS_EV_KEY, (int)vks[i], 0, KEYEVENTF_KEYUP, 0);
    if (btns & 1u)  winios_q_push_ev(WINIOS_EV_MOUSE, 0, 0, MOUSEEVENTF_LEFTUP, 0);
    if (btns & 2u)  winios_q_push_ev(WINIOS_EV_MOUSE, 0, 0, MOUSEEVENTF_RIGHTUP, 0);
    if (btns & 4u)  winios_q_push_ev(WINIOS_EV_MOUSE, 0, 0, MOUSEEVENTF_MIDDLEUP, 0);
    if (btns & 8u)  winios_q_push_ev(WINIOS_EV_MOUSE, 0, 0, MOUSEEVENTF_XUP, WINIOS_XBUTTON1);
    if (btns & 16u) winios_q_push_ev(WINIOS_EV_MOUSE, 0, 0, MOUSEEVENTF_XUP, WINIOS_XBUTTON2);
}

/* ml661 — what the driver believes is held, for the app's [input] line. Bit i
 * of the 8-word mask is vk i; returns the count. mask may be NULL. */
int winios_held_keys(unsigned int mask[8]) {
    int i, n;
    pthread_mutex_lock(&g_input_q.lock);
    if (mask) for (i = 0; i < 8; i++) mask[i] = g_input_q.keydown_mask[i];
    n = (int)g_input_q.keys_down;
    pthread_mutex_unlock(&g_input_q.lock);
    return n;
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
 * scale).
 *
 * ml — the SAME per-HWND layers now also serve a DIRECT launch, where
 * the host is the transparent overlay inside the game's own presented
 * layer rather than this full-screen view, and the desktop-pixel ->
 * point mapping is the game rect's instead of the letterbox's. Only
 * those two things differ; everything below is shared. See the overlay
 * section after the cursor code, and Winios.h's doc comment for why a
 * direct launch needed it at all. */

/* ml — direct-launch overlay. Defined after the cursor section below,
 * which is where the game layer it hosts on (g_game_layer), the live
 * guest resolution (winios_screen_size) and the mode test
 * (winios_cursor_desktop_mode) are already declared — same
 * forward-declaration idiom as winios_place_metal_layer/
 * winios_remove_layer above and below. */
static int winios_overlay_active(void);
static CALayer *winios_ensure_window_host(void);
static CGRect winios_overlay_layer_rect(int x, int y, int w, int h);
static void winios_overlay_refresh_live(void);
static CGRect winios_layer_rect(int x, int y, int w, int h);
static void winios_overlay_recompute_fit(void);
static int winios_overlay_map_px(CGFloat x, CGFloat y, CGPoint *out, CGSize *scale);
static void winios_place_window_layer(NSNumber *key);
static int winios_overlay_fit_active(void);
static CGSize winios_game_rect_size(void);
/* Implemented in IOSDisplayShim.m — the LIVE guest resolution, which a guest
 * ChangeDisplaySettings really changes; see its doc comment there. Declared
 * here as well as at its other use below because the compositor's own layout
 * needs it, and that runs earlier in this file. */
extern void winios_screen_size(int *w, int *h);

static NSMutableDictionary<NSNumber *, CALayer *> *g_layers;
static NSMutableDictionary<NSNumber *, NSValue *> *g_px_rects;  /* hwnd → last px rect */
static NSMutableDictionary<NSNumber *, NSValue *> *g_surf_sizes; /* hwnd → surface px size */
static NSMutableDictionary<NSNumber *, NSValue *> *g_surf_org;   /* hwnd → surface origin, window-local px */
static NSMutableDictionary<NSNumber *, CAMetalLayer *> *g_metal_layers; /* hwnd → DXMT layer */
static NSMutableDictionary<NSNumber *, NSValue *> *g_client_rects;      /* hwnd → client px rect */
/* ml2000: hwnd → PEB of the process that framed it (main thread only). A
 * process that dies without destroying its windows (crash, TerminateProcess)
 * never runs pDestroyWindow, and its last frame stayed on screen after exit.
 * MADEIRA_WINIOS_EXIT_SWEEP=0 keeps such layers. */
static NSMutableDictionary<NSNumber *, NSNumber *> *g_hwnd_owner;
/* ml2000: desktop fit state (winios_desktop_fit below), main thread only. */
static NSNumber *g_fit_key;
static CGRect g_fit_client_px;   /* the window's client rect, desktop px */
static CGRect g_fit_view_pt;     /* where it is shown, compositor-view points */
extern void *madeira_current_peb(void) __attribute__((weak));
static uintptr_t winios_caller_owner(void) {
    if ([NSThread isMainThread] || !madeira_current_peb) return 0;
    static int enabled = -1;
    if (enabled < 0) { const char *e = getenv("MADEIRA_WINIOS_EXIT_SWEEP"); enabled = !(e && e[0] == '0'); }
    return enabled ? (uintptr_t)madeira_current_peb() : 0;
}
static void winios_note_owner(NSNumber *key, uintptr_t owner) {   /* main thread */
    if (!owner) return;
    if (!g_hwnd_owner) g_hwnd_owner = [NSMutableDictionary new];
    g_hwnd_owner[key] = @(owner);
}

/* ml2000: called by ntdll's exit wrapper on a thread of the exiting process. */
void winios_process_exited(void *peb) {
    uintptr_t owner = (uintptr_t)peb;
    if (!owner) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_hwnd_owner.count) return;
        NSMutableArray<NSNumber *> *gone = [NSMutableArray new];
        [g_hwnd_owner enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSNumber *value, BOOL *stop) {
            if (value.unsignedLongLongValue == owner) [gone addObject:key];
        }];
        if (!gone.count) return;
        unsigned metal = 0;
        for (NSNumber *key in gone) {
            HWND hwnd = (HWND)(uintptr_t)key.unsignedLongLongValue;
            [g_hwnd_owner removeObjectForKey:key];
            if (g_metal_layers[key]) metal++;
            winios_census_forget(hwnd);
            winios_remove_layer(hwnd);
        }
        fprintf(stderr, "[winios] ml2000 process exit: retired %lu window layer(s), %u Metal\n",
                (unsigned long)gone.count, metal);
        fflush(stderr);
    });
}
static void winios_place_metal_layer(NSNumber *key);

/* ml1110 — MADEIRA_SURFACE_EXACT=0 restores the pre-ml1110 placement (layer
 * framed to the whole window, contents clamped to it) for a window whose
 * surface does not cover it. Nothing else reads this. */
static int winios_surface_exact(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MADEIRA_SURFACE_EXACT");
        on = !(e && *e == '0');
    }
    return on;
}

/* ml1110 — WHERE A WINDOW'S BITS ACTUALLY ARE, IN GUEST PIXELS.
 *
 * win32u's get_surface_rect() does two things this file used to assume away:
 * it rounds the surface out to a 128px grid (so it is usually LARGER than the
 * window — the case the old contentsRect clamp existed for), and, for a window
 * bigger than the virtual screen, it INTERSECTS the surface with that screen
 * first ("some applications create huge windows"). The second case makes the
 * surface SMALLER than the window: a 1286x1011 window on a 1280x720 desktop
 * gets a 1280x768 surface. Clamping contentsRect to 1.0 then drew those
 * 1280x768 bits across the full 1286x1011 window rect — a 1.32x vertical
 * stretch, with the 243 rows win32u never allocated invented by the stretch.
 *
 * So compute the covered rect explicitly. `*cov` is the whole surface mapped
 * into guest pixels (possibly hanging off the window); the return value is the
 * part of it that is inside the window, which is what gets drawn. Empty return
 * = nothing to show yet. */
static CGRect winios_window_drawn_rect(NSNumber *key, CGRect *cov) {
    NSValue *sv = g_surf_sizes[key], *rv = g_px_rects[key];
    if (cov) *cov = CGRectZero;
    if (!sv || !rv) return CGRectZero;
    CGSize surf = sv.CGSizeValue;
    CGRect px = rv.CGRectValue;
    if (surf.width <= 0 || surf.height <= 0 || CGRectIsEmpty(px)) return CGRectZero;
    CGPoint org = CGPointZero;
    NSValue *ov = g_surf_org[key];
    if (ov) { CGRect o = ov.CGRectValue; org = o.origin; }
    CGRect c = CGRectMake(px.origin.x + org.x, px.origin.y + org.y, surf.width, surf.height);
    if (cov) *cov = c;
    CGRect drawn = CGRectIntersection(c, px);
    return CGRectIsNull(drawn) ? CGRectZero : drawn;
}

/* ml1110 — THE APP SIDE OF "WHERE DID THAT WINDOW GO".
 *
 * win32u's [overlay-win]/[overlay-flush] lines say where a window is in GUEST
 * pixels; this says where that became a rectangle on screen. Both halves are
 * needed: a dialog drawn off the top-left corner is either a guest-side
 * centring that read a zero screen (win32u's line is negative) or an overlay
 * mapping that is wrong (win32u's line is sane and this one is not), and no
 * log so far could tell those apart. First three placements per window, direct
 * launch only, so it stays a low-volume family. */
static void winios_log_placement(NSNumber *key, CGRect px, CGRect drawn, CALayer *l) {
    if (!winios_overlay_active()) return;
    static NSMutableDictionary<NSNumber *, NSNumber *> *seen;
    if (!seen) seen = [NSMutableDictionary new];
    unsigned n = seen[key].unsignedIntValue;
    if (n >= 3) return;
    seen[key] = @(n + 1);
    CGRect f = l.frame, cr = l.contentsRect;
    CGSize hb = winios_game_rect_size();
    int gw = 0, gh = 0;
    winios_screen_size(&gw, &gh);
    fprintf(stderr, "[overlay-place] #%u hwnd=0x%llx guest-win={%.0f,%.0f %.0fx%.0f} "
                    "drawn={%.0f,%.0f %.0fx%.0f} layer=(%.1f,%.1f %.1fx%.1f) "
                    "contents=(%.3f,%.3f %.3fx%.3f) hidden=%d game-rect=%.0fx%.0f "
                    "guest=%dx%d fit=%d rev=ml1110\n",
            n + 1, key.unsignedLongLongValue,
            px.origin.x, px.origin.y, px.size.width, px.size.height,
            drawn.origin.x, drawn.origin.y, drawn.size.width, drawn.size.height,
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            cr.origin.x, cr.origin.y, cr.size.width, cr.size.height,
            (int)l.hidden, hb.width, hb.height, gw, gh, winios_overlay_fit_active());
    fflush(stderr);
}

/* main thread only. Frames a window's layer and crops its contents so that
 * every surface pixel lands on the guest pixel it belongs to — see
 * winios_window_drawn_rect. Identical to the pre-ml1110 placement whenever the
 * surface starts at window-local (0,0) and is at least as big as the window,
 * which is every window that fits on the guest desktop. */
static void winios_place_window_layer(NSNumber *key) {
    CALayer *l = g_layers[key];
    NSValue *rv = g_px_rects[key];
    if (!l || !rv) return;
    CGRect px = rv.CGRectValue;
    NSValue *sv = g_surf_sizes[key];
    if (!sv || !winios_surface_exact()) {
        /* No bits yet (frame delivered before the first flush), or the knob is
         * off: frame to the window and keep the old clamp. */
        l.frame = winios_layer_rect((int)px.origin.x, (int)px.origin.y,
                                    (int)px.size.width, (int)px.size.height);
        if (sv && !CGRectIsEmpty(px)) {
            CGSize surf = sv.CGSizeValue;
            if (surf.width > 0 && surf.height > 0)
                l.contentsRect = CGRectMake(0, 0, MIN(px.size.width / surf.width, 1.0),
                                                  MIN(px.size.height / surf.height, 1.0));
        }
        return;
    }
    CGRect cov, drawn = winios_window_drawn_rect(key, &cov);
    if (CGRectIsEmpty(drawn)) { l.frame = CGRectZero; return; }
    l.frame = winios_layer_rect((int)drawn.origin.x, (int)drawn.origin.y,
                                (int)drawn.size.width, (int)drawn.size.height);
    l.contentsRect = CGRectMake((drawn.origin.x - cov.origin.x) / cov.size.width,
                                (drawn.origin.y - cov.origin.y) / cov.size.height,
                                drawn.size.width / cov.size.width,
                                drawn.size.height / cov.size.height);
    winios_log_placement(key, px, drawn, l);
}

/* Called from win32u (driver_ios.c) once per surface CREATION, on a wine
 * thread — see winios_window_surface_rect's extern comment there. */
void winios_window_surface_rect(HWND hwnd, int left, int top, int right, int bottom) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_surf_org) g_surf_org = [NSMutableDictionary new];
        NSNumber *key = @((uintptr_t)hwnd);
        g_surf_org[key] = [NSValue valueWithCGRect:CGRectMake(left, top,
                                                              right - left, bottom - top)];
        if (g_layers[key]) winios_place_window_layer(key);
    });
}
static UIView *g_compositor_view;
static CALayer *g_desk_bg;               /* teal desktop-area backdrop */
static CGFloat g_px_to_pt = 1.0 / 3.0;   /* desktop px → screen pt */
static CGPoint g_desk_origin;            /* desktop (0,0) in view pt (letterbox offset) */
static CGRect g_comp_frame;              /* presentation area (window coords), from Swift */
static BOOL g_comp_frame_set;

/* Desktop pixels -> a rect in the HOST layer's own coordinate space. Desktop
 * mode: the compositor view's letterbox mapping, exactly as before. Direct
 * launch: the overlay's game-rect mapping (see winios_overlay_layer_rect). */
static CGRect winios_layer_rect(int x, int y, int w, int h) {
    if (winios_overlay_active()) return winios_overlay_layer_rect(x, y, w, h);
    CGFloat s = g_px_to_pt;
    return CGRectMake(g_desk_origin.x + x * s, g_desk_origin.y + y * s, w * s, h * s);
}

/* main thread only. Sizes the compositor to the presentation frame and
 * aspect-fits the wine desktop inside it; repositions existing layers. */
static void winios_layout_compositor(void) {
    if (!g_compositor_view) return;
    UIWindow *win = g_compositor_view.superview ? (UIWindow *)g_compositor_view.superview : nil;
    CGRect frame = g_comp_frame_set ? g_comp_frame : (win ? win.bounds : g_compositor_view.frame);
    g_compositor_view.frame = frame;

    /* ml1110: the LIVE guest size, not MADEIRA_SCREEN_W/H. That environment
     * pair is the session's launch-time SEED; win32u owns the value afterwards
     * and publishes every change through winios_display_mode_changed (see
     * IOSDisplayShim.m). Reading the seed here meant that a desktop session
     * whose shell — or any program in it — programmed a different mode kept
     * letterboxing against the OLD size: the wine desktop was then drawn into a
     * sub-rectangle of its own frame, with the taskbar and every window layer
     * placed by a scale nothing else in the app agreed with, and the touch
     * mapping below (winios_desktop_point_from_window) off by the same factor. */
    int desk_w = 0, desk_h = 0;
    winios_screen_size(&desk_w, &desk_h);
    if (desk_w <= 0) desk_w = 1024;
    if (desk_h <= 0) desk_h = 768;
    CGFloat s = MIN(frame.size.width / desk_w, frame.size.height / desk_h);
    CGSize fit = CGSizeMake(desk_w * s, desk_h * s);
    g_px_to_pt = s;
    g_desk_origin = CGPointMake((frame.size.width - fit.width) / 2,
                                (frame.size.height - fit.height) / 2);
    g_desk_bg.frame = CGRectMake(g_desk_origin.x, g_desk_origin.y, fit.width, fit.height);

    /* re-place existing window layers under the new mapping */
    for (NSNumber *key in g_px_rects) {
        winios_place_window_layer(key);
        winios_place_metal_layer(key);
    }
    fprintf(stderr, "[winios] compositor layout: frame=(%.0f,%.0f %.0fx%.0f) desk=%dx%d px_to_pt=%.3f\n",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            desk_w, desk_h, (double)g_px_to_pt);
    fflush(stderr);
}

/* Called from Swift (MetalBackedView) with the presentation area in
 * window coordinates — same geometry contract as the Metal host view. */
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

/* ml1110 — see Winios.h. The desktop-mode twin of winios_overlay_relayout /
 * winios_cursor_relayout, called from the same place in Swift: the compositor
 * letterboxes the guest desktop inside its frame, and a GUEST mode change
 * moves that mapping without moving the frame — so winios_set_compositor_frame
 * (which deliberately skips a no-op frame) can never notice it. */
/* ml1530: the library front end hides a desktop session's compositor view once
 * the session has ended (it sits directly on the app window above the library
 * and otherwise keeps the last frame: device log prev-20, a frozen installer
 * desktop after setup finished), and shows it again for the next session.
 * Returns 1 when there was a view to change. */
int winios_compositor_set_hidden(int hidden) {
    if (!g_compositor_view) return 0;
    BOOL h = hidden ? YES : NO;
    if (NSThread.isMainThread) {
        if (g_compositor_view.hidden == h) return 0;
        g_compositor_view.hidden = h;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ g_compositor_view.hidden = h; });
    }
    return 1;
}

void winios_compositor_relayout(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_compositor_view) winios_layout_compositor();
    });
}

/* main thread only */
static void winios_ensure_compositor(void) {
    if (g_compositor_view) return;
    /* desktop mode only — games render via DXMT's Metal layer and the
     * compositor backdrop would cover it (2026-07-06 Thumper regression) */
    const char *dm = getenv("MADEIRA_DESKTOP");
    if (!dm || *dm != '1') return;
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
    /* letterbox area: black; desktop area: classic teal (until explorer's own
     * background paint works).
     * ml1490: the letterbox was 8 % grey, so a portrait phone showed grey bands
     * above and below the desktop where a direct launch shows black (its host
     * view is black). This view exists only in the live view of a desktop
     * session. MADEIRA_LIVE_BLACK_BARS=0 restores the grey. */
    const char *bars = getenv("MADEIRA_LIVE_BLACK_BARS");
    int black = !(bars && bars[0] == '0');
    g_compositor_view.backgroundColor = black ? UIColor.blackColor : [UIColor colorWithWhite:0.08 alpha:1.0];
    fprintf(stderr, "[live-bars] ml1490 desktop letterbox=%s\n", black ? "black" : "grey");
    g_desk_bg = [CALayer layer];
    g_desk_bg.backgroundColor = [UIColor colorWithRed:0.0 green:0.502 blue:0.502 alpha:1.0].CGColor;
    [g_compositor_view.layer addSublayer:g_desk_bg];
    [win addSubview:g_compositor_view];
    winios_layout_compositor();
    fprintf(stderr, "[winios] compositor attached inside presentation frame\n");
    fflush(stderr);
    winios_stack_timer_start();
}

/* main thread only. `host` is whichever layer the current mode parents window
 * layers onto — the compositor view's layer in desktop mode, the overlay in a
 * direct launch — resolved by the caller (winios_ensure_window_host), which is
 * also what guarantees one exists before we add a sublayer to it. */
static CALayer *winios_layer_for(HWND hwnd, bool create) {
    NSNumber *key = @((uintptr_t)hwnd);
    CALayer *l = g_layers[key];
    if (!l && create) {
        CALayer *host = winios_ensure_window_host();
        if (!host) return nil;
        l = [CALayer layer];
        l.anchorPoint = CGPointMake(0, 0);
        l.magnificationFilter = kCAFilterNearest;
        l.opaque = YES;
        [host addSublayer:l];
        g_layers[key] = l;
        fprintf(stderr, "[winios] layer created for hwnd=%p (%lu layers)\n",
                hwnd, (unsigned long)g_layers.count);
        fflush(stderr);
        winios_overlay_refresh_live();
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
            [g_surf_sizes removeObjectForKey:key];
            [g_surf_org removeObjectForKey:key];
            /* Direct launch: the last window going away is what retires the
             * overlay, so the live count and the teardown are decided in one
             * place. No-op in desktop mode. */
            winios_overlay_refresh_live();
        }
        CAMetalLayer *ml = g_metal_layers[key];
        if (ml) {
            [ml removeFromSuperlayer];
            [g_metal_layers removeObjectForKey:key];
            [g_client_rects removeObjectForKey:key];
            if (g_fit_key && [g_fit_key isEqual:key]) g_fit_key = nil;   /* ml2000 */
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

/* main thread only — frame the metal sublayer to the client rect in the
 * parent (window) layer's coordinate space. Parent bounds are the window
 * rect in points, so client offset = (client_px - window_px) * scale. */
/* ml2000: DESKTOP FIT. A presenting window whose client area does not fit the
 * wine desktop (a 1920x1080 window on a 1280x720 desktop) was cropped: only its
 * top-left showed, under a title bar, which looked like a frozen, non-fullscreen
 * game. Its Metal layer is instead aspect-fitted to the whole desktop, and taps
 * and the arrow are mapped through the same rectangle so the program still gets
 * its own client coordinates. Main thread only. MADEIRA_DESKTOP_FIT=0 crops. */
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
        fprintf(stderr, "[desktop-fit] ml2000 hwnd=0x%llx client-px={%.0f,%.0f %.0fx%.0f} desk=%dx%d -> view=(%.1f,%.1f %.1fx%.1f)\n",
                key.unsignedLongLongValue, c.origin.x, c.origin.y, c.size.width, c.size.height, desk_w, desk_h,
                view.origin.x, view.origin.y, view.size.width, view.size.height);
    }
    return YES;
}
/* ml2000: desktop px -> compositor-view points through the fitted window, if any. */
static BOOL winios_desktop_fit_map(CGFloat x, CGFloat y, CGPoint *pt, CGFloat *scale) {
    if (!g_fit_key || g_fit_client_px.size.width <= 0 || !CGRectContainsPoint(g_fit_client_px, CGPointMake(x, y)))
        return NO;
    CGFloat k = g_fit_view_pt.size.width / g_fit_client_px.size.width;
    if (pt) *pt = CGPointMake(g_fit_view_pt.origin.x + (x - g_fit_client_px.origin.x) * k,
                              g_fit_view_pt.origin.y + (y - g_fit_client_px.origin.y) * k);
    if (scale) *scale = k;
    return YES;
}

static void winios_place_metal_layer(NSNumber *key) {
    CAMetalLayer *ml = g_metal_layers[key];
    if (!ml) return;
    NSValue *wv = g_px_rects[key], *cv = g_client_rects[key];
    if (!wv || !cv) return;
    CGRect w = wv.CGRectValue, c = cv.CGRectValue;
    /* ml1110: the window layer is framed to the part of the window its surface
     * actually covers — the whole window unless get_surface_rect() cropped it
     * (winios_window_drawn_rect) — so the sublayer's offset is measured from
     * THAT origin, not the window's. Identical whenever nothing was cropped. */
    CGRect drawn = winios_window_drawn_rect(key, NULL);
    CGPoint org = (winios_surface_exact() && !CGRectIsEmpty(drawn)) ? drawn.origin : w.origin;
    CGFloat s = g_px_to_pt;
    ml.frame = CGRectMake((c.origin.x - org.x) * s,
                          (c.origin.y - org.y) * s,
                          c.size.width * s, c.size.height * s);
    winios_desktop_fit(key, ml, c);   /* ml2000 */
    {   /* ml1730: where the swapchain layer went, and where its window layer is. */
        static unsigned logged;
        if (logged < 60) {
            logged++;
            CALayer *parent = ml.superlayer;
            fprintf(stderr, "[metal-place] ml1730 hwnd=0x%llx win-px={%.0f,%.0f %.0fx%.0f} client-px={%.0f,%.0f %.0fx%.0f} "
                            "metal=(%.1f,%.1f %.1fx%.1f) in window-layer=(%.1f,%.1f %.1fx%.1f)\n",
                    key.unsignedLongLongValue, w.origin.x, w.origin.y, w.size.width, w.size.height,
                    c.origin.x, c.origin.y, c.size.width, c.size.height,
                    ml.frame.origin.x, ml.frame.origin.y, ml.frame.size.width, ml.frame.size.height,
                    parent.frame.origin.x, parent.frame.origin.y, parent.frame.size.width, parent.frame.size.height);
        }
    }
}

/* Called by IOSDisplayShim on a wine thread when DXMT creates a swapchain
 * view for an HWND in desktop mode. Returns the (unretained) CAMetalLayer;
 * the shim CFRetains it for DXMT's lifetime handling. */
CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd) {
    __block CAMetalLayer *result = nil;
    uintptr_t owner = winios_caller_owner();   /* ml2000 */
    void (^make)(void) = ^{
        winios_ensure_compositor();
        if (!g_compositor_view) return;
        if (!g_metal_layers) g_metal_layers = [NSMutableDictionary new];
        NSNumber *key = @((uintptr_t)hwnd);
        winios_note_owner(key, owner);
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
            winios_census_note_metal((HWND)hwnd);   /* ml1490 */
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
    /* ml1490: here, not in the block below — the census asks win32u about the
     * window, which needs this wine thread. No-op unless the app turned it on. */
    winios_census_note_frame(hwnd, x, y, w, h, visible);
    uintptr_t owner = winios_caller_owner();   /* ml2000 */
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!winios_ensure_window_host()) return;
        CALayer *l = winios_layer_for(hwnd, true);
        if (!l) return;
        NSNumber *key = @((uintptr_t)hwnd);
        winios_note_owner(key, owner);
        g_px_rects[key] = [NSValue valueWithCGRect:CGRectMake(x, y, w, h)];
        if (!g_client_rects) g_client_rects = [NSMutableDictionary new];
        g_client_rects[key] = [NSValue valueWithCGRect:CGRectMake(cx, cy, cw, ch)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        l.hidden = !visible;
        winios_place_window_layer(key);
        winios_place_metal_layer(key);
        [CATransaction commit];
        /* A window being shown or hidden changes how many overlay windows are
         * on screen, which is what win32u's blocking wait polls on. */
        winios_overlay_refresh_live();
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
    /* ml — before the copy, not after: a direct launch's D3D device window
     * flushes a full-size black client area and forwarding it would both
     * cover the game image and pay a whole-surface memcpy per flush for a
     * bitmap we would then throw away. The win32u side asks the same question
     * (winios_overlay_skip_hwnd) and normally never calls us at all for such
     * a window; this is the backstop for a flush already in flight when the
     * swapchain registered. Desktop mode never skips — see that function. */
    if (winios_overlay_skip_hwnd(hwnd)) return 1;
    winios_census_note_present(hwnd);   /* ml1490: no-op unless the census is on */
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
        if (!winios_ensure_window_host()) return;
        CALayer *l = winios_layer_for(hwnd, true);
        if (!l) return;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        /* GDI 32bpp DIB = BGRX little-endian, no alpha */
        CGImageRef img = CGImageCreate(sw, sh, 8, 32, stride, cs,
                                       kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                       dp, NULL, false, kCGRenderingIntentDefault);
        if (img) {
            NSNumber *key = @((uintptr_t)hwnd);
            l.contents = (__bridge id)img;
            atomic_fetch_add_explicit(&g_surface_present_count, 1, memory_order_relaxed);
            NSValue *old = g_surf_sizes[key];
            CGSize now = CGSizeMake(sw, sh);
            int grew = !old || !CGSizeEqualToSize(old.CGSizeValue, now);
            g_surf_sizes[key] = [NSValue valueWithCGSize:now];
            if (!g_px_rects[key] || CGRectIsEmpty(g_px_rects[key].CGRectValue)) {
                /* frame not delivered yet — place at surface size */
                g_px_rects[key] = [NSValue valueWithCGRect:CGRectMake(0, 0, sw, sh)];
                grew = 1;
            }
            winios_place_window_layer(key);
            /* ml1110: a window's DRAWN extent is only known once its bits have
             * arrived, and that extent is what the direct-launch fit scales by.
             * Only on a CHANGE — this runs on every flush. */
            if (grew) winios_overlay_refresh_live();
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

/* ml — DIRECT-LAUNCH CURSOR HOST.
 *
 * Desktop mode hosts the drawn cursor on g_compositor_view (above) — that
 * view only exists in desktop mode, by winios_ensure_compositor's own
 * gate. A directly-launched program has no such view: its presented
 * surface is the app's own window-level CAMetalLayer (MetalHostView, added
 * directly to the UIWindow above the entire SwiftUI tree — see
 * ContentView.swift's file-top comment), so in that mode the cursor is
 * hosted as a sublayer of THAT layer instead. Swift hands us its address
 * once, right after registering the same layer with DXMT
 * (MetalBackedView.didMoveToWindow) — see winios_set_game_layer, and
 * Winios.h's doc comment for why this takes `void *` and not `CAMetalLayer
 * *`.
 *
 * Positioning then needs only two numbers this file can get on its own:
 * the layer's own `bounds` (which IS the current game rect in POINTS —
 * MetalHostView.shared.frame is set to exactly GameSurfaceLayout.rect()
 * converted to window coordinates on every apply, so the layer's LOCAL
 * bounds are that rect's SIZE at local origin (0,0), independent of where
 * the rect sits in the window) and the guest's logical resolution
 * (winios_screen_size(), the same live source ContentView.swift's own
 * touch-mapping and display code reads — see its guestSize()/mapTouch()).
 * A drawable presented into a CAMetalLayer fills its bounds exactly
 * (default contentsGravity is resize/stretch, and gameRect() already chose
 * this rect to HAVE the guest's own aspect for every DisplayMode except
 * Stretch, where stretching is the guest's own mapping too) — so
 * guest-pixel -> layer-point is one uniform scale that is correct for
 * every DisplayMode, in the normal view, the wide view and fullscreen,
 * with no separate rect math to keep in sync with GameSurfaceLayout's. */
static CALayer *g_game_layer;

void winios_set_game_layer(void *metal_layer) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_game_layer = (__bridge CALayer *)metal_layer;
    });
}

/* ml1090 — THE GAME RECT, PUBLISHED RATHER THAN INFERRED.
 *
 * Everything in direct-launch mode maps guest pixels through one rect: the
 * drawn cursor, the GDI overlay and its per-window layers, and Swift's own
 * touch mapping. Until now this file inferred that rect from
 * g_game_layer.bounds, which is only correct once Swift has sized
 * MetalHostView AND a drawable has been presented into it. Before the first
 * Present there may be no correct rect there at all: log 77 created the
 * overlay against game-rect=320x240 while GameSurfaceLayout had already
 * chosen 402x226, so the dialog it drew was scaled by a number nothing else
 * in the app agreed with.
 *
 * So Swift publishes the rect it actually laid out (applyDisplayModeAndLog,
 * the same place it sets MetalHostView's frame and calls the two relayout
 * hooks), and the layer bounds are only the fallback. One rect, one source,
 * valid before anything has been presented. */
static CGSize g_game_rect;   /* main thread only, points */

void winios_set_game_rect(double w, double h) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_game_rect = CGSizeMake(w, h);
    });
}

/* main thread only. CGSizeZero when neither source has a usable rect yet —
 * every caller treats that as "nothing to place". */
static CGSize winios_game_rect_size(void) {
    if (g_game_rect.width > 0 && g_game_rect.height > 0) return g_game_rect;
    if (g_game_layer) {
        CGRect b = g_game_layer.bounds;
        if (b.size.width > 0 && b.size.height > 0) return b.size;
    }
    return CGSizeZero;
}

/* Implemented in IOSDisplayShim.m; declared there for Swift, not exported
 * through a shared ObjC header this pure-C-safe file could include. Same
 * "read the LIVE published size, not a launch-time constant" reasoning as
 * every other caller — see winios_screen_size's own doc comment there. */
extern void winios_screen_size(int *w, int *h);

/* The mode belongs to a session, not to the app process: desktop and direct
 * launches can alternate without recreating the UIKit host. */
static int winios_cursor_desktop_mode(void) {
    static int legacy = -1, reported = -1;
    const char *dm = getenv("MADEIRA_DESKTOP");
    int mode = dm && *dm == '1', unset = -1;
    if (__atomic_load_n(&legacy, __ATOMIC_RELAXED) < 0)
        __atomic_compare_exchange_n(&legacy, &unset, mode, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
    const char *value = getenv("MADEIRA_CURSOR_SESSION_MODE");
    if (value && !strcmp(value, "0")) return __atomic_load_n(&legacy, __ATOMIC_RELAXED);
    if (__atomic_load_n(&reported, __ATOMIC_RELAXED) != mode &&
        __atomic_exchange_n(&reported, mode, __ATOMIC_RELAXED) != mode)
        fprintf(stderr, "[cursor-session] ml1170 desktop=%d\n", mode);
    return mode;
}

/* The layer the cursor draws into for the CURRENT mode: the desktop
 * compositor in desktop mode (ensuring it exists first, same as every
 * other desktop-mode caller in this file), or the game's own presented
 * layer in direct-launch mode — NEVER the compositor there, which
 * winios_ensure_compositor already refuses to create outside desktop mode
 * (its own gate), so calling it in direct-launch mode is a harmless no-op
 * left in place below rather than duplicating that mode check here. */
static CALayer *winios_cursor_host_layer(void) {
    if (winios_cursor_desktop_mode()) {
        winios_ensure_compositor();
        return g_compositor_view.layer;
    }
    return g_game_layer;
}

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
static int g_cursor_pos_seeded;

/* Main-thread only, like placement. Seed a new trackpad gesture from the
 * last guest position instead of teleporting to the finger's down point. */
int winios_get_cursor_position(int *x, int *y) {
    if (!g_cursor_pos_seeded) return 0;
    *x = (int)g_cursor_pos_px.x; *y = (int)g_cursor_pos_px.y;
    return 1;
}

/* ml1090 — WHO DECIDES WHETHER THE POINTER IS ON SCREEN IN A DIRECT LAUNCH.
 *
 * -1 = the driver has not spoken yet, 0/1 = its last winios_cursor_show().
 * Before it speaks, "an ordinary GDI window is on screen" means there is a
 * pointer: a directly-launched program whose first window is a dialog only
 * ever gets a WM_SETCURSOR — and therefore a winios_drv_set_cursor call —
 * once the mouse is already over one of its windows, which is impossible
 * while nothing it owns has been drawn. Log 77 is that deadlock exactly: the
 * chooser dialog was up, every tap reached the server, and the log has not a
 * single cursor line in it. Once the driver DOES speak, its word wins in both
 * directions, so a program that hides the pointer still hides it. */
static int g_cursor_drv_show = -1;
static unsigned g_cursor_gdi_windows;

/* ml1420 — TOUCH POINTER REVEAL. Programs commonly hide their cursor after a
 * few seconds without mouse movement and show it again on the next movement;
 * device log: the pointer vanished ~10 s after the last click. With a mouse
 * that costs a wiggle. With a finger, the only way to "move" in Touch pointer
 * mode is a tap, which is also a click, so the user points blind. While a
 * finger is pointing, the drawn arrow stays visible until REVEAL_SECONDS
 * after the last touch even if the program hid its cursor; the program's own
 * show/hide still applies otherwise, and relative mouse-look never reveals
 * (the caller skips it). MADEIRA_CURSOR_REVEAL=0 disables. */
#define WINIOS_CURSOR_REVEAL_SECONDS 3.0
static CFAbsoluteTime g_cursor_reveal_until;

static int winios_cursor_reveal_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char *v = getenv("MADEIRA_CURSOR_REVEAL");
        enabled = !(v && !strcmp(v, "0"));
    }
    return enabled;
}

/* main thread only */
static void winios_cursor_apply_visibility(void) {
    if (!g_cursor_layer) return;
    if (winios_cursor_desktop_mode()) return;   /* desktop mode is unchanged */
    int program = g_cursor_drv_show > 0 || (g_cursor_drv_show < 0 && g_cursor_gdi_windows > 0);
    int revealed = winios_cursor_reveal_enabled() && CFAbsoluteTimeGetCurrent() < g_cursor_reveal_until;
    g_cursor_layer.hidden = !(program || revealed);
}

static void winios_ensure_cursor_layer(void);

/* main thread only. Hides the arrow again once the reveal window has passed;
 * a later touch only moves the deadline, so at most one of these is pending. */
static void winios_cursor_reveal_recheck(void) {
    CFAbsoluteTime left = g_cursor_reveal_until - CFAbsoluteTimeGetCurrent();
    if (left > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((left + 0.05) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ winios_cursor_reveal_recheck(); });
        return;
    }
    winios_cursor_apply_visibility();
}

void winios_cursor_reveal(void) {
    static unsigned notes;
    static CFAbsoluteTime last_note;
    if (!winios_cursor_reveal_enabled() || winios_cursor_desktop_mode()) return;
    /* ml1980: a program that has never supplied a cursor image draws its own pointer
     * (device log: no cursor ever set, fullscreen D3D window, input through raw input).
     * Revealing the fallback arrow then shows a second pointer the program ignores, and
     * the user aims with it. MADEIRA_CURSOR_REVEAL_UNSET=1 reveals it anyway. */
    if (g_cur_w == 0) {
        static int reveal_unset = -1;
        static int logged;
        if (reveal_unset < 0) {
            const char *value = getenv("MADEIRA_CURSOR_REVEAL_UNSET");
            reveal_unset = value && !strcmp(value, "1");
        }
        if (!reveal_unset) {
            if (!logged) {
                logged = 1;
                fprintf(stderr, "[cursor-reveal] ml1980 program never set a cursor; no drawn arrow (it draws its own)\n");
            }
            return;
        }
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    int pending = now < g_cursor_reveal_until;
    g_cursor_reveal_until = now + WINIOS_CURSOR_REVEAL_SECONDS;
    /* Touch moves arrive at display rate: an open window only moves its
     * deadline; the pending recheck picks the new one up. */
    if (pending) return;
    if (g_cursor_drv_show == 0 && notes < 16 && now - last_note > 10) {
        ++notes; last_note = now;
        fprintf(stderr, "[cursor-reveal] ml1420 program hid the cursor; shown for %.0fs after touch\n",
                WINIOS_CURSOR_REVEAL_SECONDS);
    }
    winios_ensure_cursor_layer();
    winios_cursor_apply_visibility();
    winios_cursor_reveal_recheck();
}

/* main thread only. Creates the layer at most once (process lifetime, like
 * every other singleton layer in this file) and re-parents it onto
 * whichever host is current — needed because a single app process can run
 * a desktop session and a direct-launch session back to back, and the two
 * modes host on different layers (see winios_cursor_host_layer above).
 * Superlayer-equality check makes the re-parent a no-op on the hot path
 * (called from every cursor move/set), not just on a genuine mode switch. */
static void winios_ensure_cursor_layer(void) {
    CALayer *host = winios_cursor_host_layer();
    if (!host) return;
    if (!g_cursor_layer) {
        UIImage *img = winios_cursor_image();
        g_cursor_layer = [CALayer layer];
        g_cursor_layer.zPosition = 10000;   /* above every window/game layer */
        g_cursor_layer.anchorPoint = CGPointMake(0, 0);
        g_cursor_layer.contents = (id)img.CGImage;
        g_cursor_layer.bounds = CGRectMake(0, 0, img.size.width, img.size.height);
        g_cursor_layer.magnificationFilter = kCAFilterNearest;
        /* ml — VISIBILITY DEFAULT. Desktop mode's default here was always
         * NO (a plain CALayer starts visible) — untouched, so an existing
         * session's exact behaviour never changes (a move before the
         * first WM_SETCURSOR already drew the builtin fallback arrow, and
         * that stays true). Direct-launch mode starts HIDDEN instead: a
         * game's first TOUCH (see winios_post_touch_down/move, which now
         * call winios_cursor_move too — the position source for absolute
         * taps/drags) can create this layer before the game has ever
         * called SetCursor, and the spec is explicit that the cursor stays
         * hidden until it does. winios_cursor_show below ensures this
         * layer itself in direct-launch mode specifically so an early
         * pSetCursor(NULL)/show(1) that arrives before any image is never
         * lost to this ordering. */
        g_cursor_layer.hidden = winios_cursor_desktop_mode() ? NO : YES;
        /* ml1090: …unless an ordinary GDI window is already on screen, which
         * in a direct launch is the only evidence of a pointer the program
         * can give us before it is ever asked for one. */
        winios_cursor_apply_visibility();
    }
    if (g_cursor_layer.superlayer != host) {
        [g_cursor_layer removeFromSuperlayer];
        [host addSublayer:g_cursor_layer];
    }
}

/* main thread only — place (and size) the cursor at its stored px pos,
 * honoring the wine cursor's hotspot when one is set */
static void winios_cursor_place(void) {
    if (!g_cursor_layer) return;
    if (winios_cursor_desktop_mode()) {
        CGFloat x = g_cursor_pos_px.x, y = g_cursor_pos_px.y;
        CGPoint fitted; CGFloat k = 0;
        if (winios_desktop_fit_map(x, y, &fitted, &k)) {   /* ml2000 */
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
                                                  g_desk_origin.y + (y - g_cur_hy) * g_px_to_pt);
        } else {
            g_cursor_layer.position = CGPointMake(g_desk_origin.x + x * g_px_to_pt,
                                                  g_desk_origin.y + y * g_px_to_pt);
        }
        return;
    }
    /* Direct-launch mode — see winios_set_game_layer's doc comment above
     * for why g_game_layer's own bounds ARE the current game rect and no
     * window-coordinate offset belongs here (these are LOCAL sublayer
     * coordinates, origin at the layer's own top-left). */
    /* ml1090: the PUBLISHED game rect, not g_game_layer.bounds — see
     * winios_game_rect_size. Before the first Present the layer's bounds are
     * not the rect Swift laid out.
     * ml1110: and the mapping itself now comes from winios_overlay_map_px, the
     * one the overlay's window layers use — so when an oversized window has
     * shrunk the overlay to fit, the arrow shrinks and moves with it instead of
     * pointing at a window that is no longer under it. */
    CGPoint pos;
    CGSize s;
    CGFloat x = g_cursor_pos_px.x, y = g_cursor_pos_px.y;
    if (!winios_overlay_map_px(x - (g_cur_w > 0 ? g_cur_hx : 0),
                               y - (g_cur_w > 0 ? g_cur_hy : 0), &pos, &s)) return;
    /* Match the same guest-pixel transform as the surface and hotspot. The
     * previous 1-point minimum drew a 32px cursor at 32pt even in a 0.3x
     * letterbox, which also separated its visible tip from its click point. */
    if (g_cur_w > 0) {
        static int exact = -1;
        if (exact < 0) {
            const char *value = getenv("MADEIRA_CURSOR_SCALE");
            exact = !value || strcmp(value, "0");
            fprintf(stderr, "[cursor-scale] ml1170 guest-pixel sizing=%d\n", exact);
        }
        CGFloat oldScale = MAX(1.0, MIN(s.width, s.height));
        g_cursor_layer.bounds = CGRectMake(0, 0, g_cur_w * (exact ? s.width : oldScale),
                                                g_cur_h * (exact ? s.height : oldScale));
    } else {
        /* ml1980: the builtin fallback arrow was a fixed 14x21 POINTS, about twice a
         * Windows arrow at the game's resolution (device log: 0.56 pt per guest px).
         * Size it as guest pixels like a real cursor, with a small floor.
         * MADEIRA_CURSOR_FALLBACK_SCALE=0 keeps the fixed size. */
        static int scaled = -1;
        if (scaled < 0) {
            const char *value = getenv("MADEIRA_CURSOR_FALLBACK_SCALE");
            scaled = !value || strcmp(value, "0");
        }
        if (scaled) {
            CGSize img = winios_cursor_image().size;
            g_cursor_layer.bounds = CGRectMake(0, 0, MAX(7.0, img.width * s.width), MAX(10.5, img.height * s.height));
        }
    }
    g_cursor_layer.position = pos;
}

int winios_desktop_point_from_window(double wx, double wy, int *px, int *py) {
    /* ml1110: the LIVE guest size — same reasoning as winios_layout_compositor,
     * and they MUST agree or a touch lands somewhere the desktop is not. */
    int desk_w = 0, desk_h = 0;
    winios_screen_size(&desk_w, &desk_h);
    if (desk_w <= 0) desk_w = 1024;
    if (desk_h <= 0) desk_h = 768;
    if (!g_compositor_view || g_px_to_pt <= 0) { if (px) *px = 0; if (py) *py = 0; return 0; }
    /* g_desk_origin is relative to the compositor view, whose frame is in
     * window coordinates (see winios_layout_compositor). */
    CGRect f = g_compositor_view.frame;
    /* ml2000: a tap on a fitted window lands in that window's own client pixels. */
    if (g_fit_key && CGRectContainsPoint(g_fit_view_pt, CGPointMake(wx - f.origin.x, wy - f.origin.y))) {
        CGFloat k = g_fit_client_px.size.width / g_fit_view_pt.size.width;
        if (px) *px = (int)(g_fit_client_px.origin.x + (wx - f.origin.x - g_fit_view_pt.origin.x) * k);
        if (py) *py = (int)(g_fit_client_px.origin.y + (wy - f.origin.y - g_fit_view_pt.origin.y) * k);
        return 1;
    }
    double x = (wx - f.origin.x - g_desk_origin.x) / g_px_to_pt;
    double y = (wy - f.origin.y - g_desk_origin.y) / g_px_to_pt;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > desk_w - 1) x = desk_w - 1;
    if (y > desk_h - 1) y = desk_h - 1;
    if (px) *px = (int)x;
    if (py) *py = (int)y;
    return 1;
}

void winios_cursor_move(int x, int y) {
    dispatch_async(dispatch_get_main_queue(), ^{
        winios_ensure_cursor_layer();
        if (!g_cursor_layer) return;
        g_cursor_pos_px = CGPointMake(x, y);
        g_cursor_pos_seeded = 1;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        winios_cursor_place();
        [CATransaction commit];
    });
}

/* See winios_cursor_relayout's doc comment in Winios.h. */
void winios_cursor_relayout(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_cursor_layer || winios_cursor_desktop_mode()) return;
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
        winios_ensure_cursor_layer();
        if (!g_cursor_layer) return;
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
        static unsigned visibility_notes;
        const char *diagnostics = getenv("MADEIRA_MOUSE_DELIVERY");
        if (g_cursor_drv_show != !!show && visibility_notes < 32 &&
            !(diagnostics && !strcmp(diagnostics, "0"))) {
            ++visibility_notes;
            fprintf(stderr, "[cursor-visibility] ml1180 guest-show=%d pos=%.0f,%.0f\n",
                    !!show, g_cursor_pos_px.x, g_cursor_pos_px.y);
        }
        /* ml — direct-launch mode only: winios_drv_set_cursor calls
         * show(1)/show(0) BEFORE winios_cursor_set for the very first
         * cursor of a session (see its own ordering in driver_ios.c), so
         * without ensuring the layer here that first show() call would
         * arrive with no layer to act on, and — since a freshly created
         * layer now starts HIDDEN in direct-launch mode (see
         * winios_ensure_cursor_layer) — the cursor could end up stuck
         * hidden even after a real, non-NULL SetCursor. Desktop mode is
         * untouched: it never ensured the layer here before, and still
         * doesn't — winios_cursor_move/winios_cursor_set already do that
         * on the very next call in the exact same order they always have,
         * so behaviour there is unchanged. */
        /* ml1090: record the driver's word, then let the one visibility rule
         * apply it — from here on it overrides the "a GDI window is on screen"
         * inference in both directions (see g_cursor_drv_show). */
        g_cursor_drv_show = show ? 1 : 0;
        if (!winios_cursor_desktop_mode()) {
            winios_ensure_cursor_layer();
            winios_cursor_apply_visibility();
            return;
        }
        if (g_cursor_layer) g_cursor_layer.hidden = !show;
    });
}

/* ml1090. Called from winios_overlay_refresh_live (main thread) with the
 * number of ordinary GDI windows currently on screen — the direct-launch
 * stand-in for "the pointer is over something of ours", see
 * g_cursor_drv_show. Also seeds the pointer position: a cursor that appears
 * at the guest's top-left corner reads as a stuck artefact, and the centre is
 * where Windows puts an untouched pointer on a fresh desktop. */
static void winios_cursor_note_gdi_windows(unsigned n) {
    if (winios_cursor_desktop_mode()) return;
    g_cursor_gdi_windows = n;
    /* ml1100 — SAY SO. Log 85 contains no `[winios] cursor` line at all, and
     * that was read as "the pointer never appeared". It is not evidence of
     * anything: the only cursor line this file ever printed came from
     * winios_drv_set_cursor (driver_ios.c), which needs a WM_SETCURSOR the
     * program cannot send while nothing it owns is under the pointer — the
     * exact case this hand-off exists to cover. A path whose whole purpose is
     * to run when the other one cannot must not be the silent one. */
    {
        static unsigned last = (unsigned)-1;
        if (n != last) {
            last = n;
            fprintf(stderr, "[winios] cursor ml1100 gdi-windows=%u host=%p layer=%p drv-show=%d "
                            "pos=(%.0f,%.0f)%s\n",
                    n, winios_cursor_host_layer(), g_cursor_layer, g_cursor_drv_show,
                    g_cursor_pos_px.x, g_cursor_pos_px.y,
                    winios_cursor_host_layer() ? "" : " — NO HOST LAYER YET, nothing can be drawn");
            fflush(stderr);
        }
    }
    if (!n) { winios_cursor_apply_visibility(); return; }
    if (!g_cursor_pos_seeded) {
        int gw = 0, gh = 0;
        winios_screen_size(&gw, &gh);
        if (gw <= 0) gw = 1024;
        if (gh <= 0) gh = 768;
        g_cursor_pos_px = CGPointMake(gw / 2, gh / 2);
        g_cursor_pos_seeded = 1;
    }
    winios_ensure_cursor_layer();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    winios_cursor_place();
    [CATransaction commit];
    winios_cursor_apply_visibility();
}

/* Swift trackpad engine → wine. Absolute desktop-pixel coords; the
 * engine owns the cursor position. */
/* ml663 — advance the DRAWN cursor by a relative delta, clamped to the wine
 * desktop. Mirrors what the wineserver does with the same event
 * (update_desktop_cursor_pos: x = cursor.x + input->mouse.x, then clamp), so the
 * arrow on screen and wine's own cursor stay at the same place.
 *
 * Deliberately NOT a second source of truth: it moves nothing in wine, it only
 * draws. If the two ever drift, the next absolute event (or wine's own
 * SetCursorPos reaching winios_cursor_move) snaps this back. */
static void winios_cursor_advance(int dx, int dy) {
    if (!dx && !dy) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        winios_ensure_cursor_layer();
        if (!g_cursor_layer) return;
        /* ml — desktop mode keeps reading MADEIRA_SCREEN_W/H exactly as it
         * always did (that session's desktop size is a launch-time
         * constant in practice — untouched, requirement is "desktop mode
         * behaves exactly as before"). Direct-launch mode reuses the SAME
         * clamp-and-advance logic (that is the whole point — this path
         * already accumulates and clamps a position for winios_cursor_move,
         * just needed somewhere to draw and the right resolution to clamp
         * against) but asks winios_screen_size() for it, the live-published
         * guest resolution a game may have changed via ChangeDisplaySettings
         * — env vars are a launch-time hint only there. */
        int desk_w, desk_h;
        if (winios_cursor_desktop_mode()) {
            const char *dw = getenv("MADEIRA_SCREEN_W"), *dh = getenv("MADEIRA_SCREEN_H");
            desk_w = dw ? atoi(dw) : 1024;
            desk_h = dh ? atoi(dh) : 768;
        } else {
            winios_screen_size(&desk_w, &desk_h);
        }
        if (desk_w <= 0) desk_w = 1024;
        if (desk_h <= 0) desk_h = 768;
        CGFloat x = g_cursor_pos_px.x + dx, y = g_cursor_pos_px.y + dy;
        if (x < 0) x = 0; else if (x > desk_w - 1) x = desk_w - 1;
        if (y < 0) y = 0; else if (y > desk_h - 1) y = desk_h - 1;
        g_cursor_pos_px = CGPointMake(x, y);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        winios_cursor_place();
        [CATransaction commit];
    });
}

/* ml663 — set by the app while a hardware mouse is driving relative motion.
 * The aim stick and the touch mouse-look path leave it off: in those modes the
 * game has hidden the cursor and the extra main-queue hop per sample is pure
 * cost (see the ml641 note below). A real mouse in a menu is the opposite case —
 * there IS a visible arrow and it has to follow the hand. */
static _Atomic int g_rel_cursor;
void winios_cursor_track_relative(int on) { g_rel_cursor = on ? 1 : 0; }

void winios_pointer(int x, int y, unsigned int flags, unsigned int data) {
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, flags, data);
    /* ml641: ONLY an ABSOLUTE move carries a position. A relative move carries a
     * DELTA, so handing it to the cursor layer would fling the drawn arrow to the
     * top-left corner on every event. Relative mode is mouse-look, where the game
     * has hidden the cursor anyway — there is nothing to draw, and skipping this
     * also drops a dispatch_async to the main queue per touch sample. */
    if (flags & MOUSEEVENTF_MOVE) {
        if (flags & MOUSEEVENTF_ABSOLUTE) winios_cursor_move(x, y);
        else if (g_rel_cursor) winios_cursor_advance(x, y);
    }
}

/* ============================================================ *
 * ml — THE DIRECT-LAUNCH GDI OVERLAY
 * ============================================================
 *
 * See Winios.h's doc comment for the problem. The mechanics, all of which
 * fall out of hosting inside the game layer rather than beside it:
 *
 * WHERE IT LIVES. A plain CALayer added to g_game_layer — the same layer the
 * drawn cursor already hosts on (winios_set_game_layer), for the same reason:
 * it is the ONE thing in a direct launch whose bounds are the live game rect
 * in points. Sublayers of a CAMetalLayer composite ABOVE its presented
 * drawable (that is how the cursor has always worked), so the overlay is
 * above the game image; zPosition keeps it below the cursor's 10000, and the
 * app's on-screen controls live in a separate UIWindow entirely, so they stay
 * above both. Fullscreen changes only the game rect, which this reads live.
 *
 * NO BACKDROP. winios_ensure_compositor's opaque letterbox + teal desktop
 * backdrop is exactly what must not happen here (the 2026-07-06 regression in
 * its own comment: the backdrop covered a game's Metal layer). This layer has
 * no background colour at all; only the per-window layers paint, and each is
 * exactly its window's rect.
 *
 * COORDINATES. Guest pixel -> layer point is one uniform scale, the game
 * layer's bounds over the live guest resolution — identical to
 * winios_cursor_place's, and identical to what MetalBackedView.mapPoint
 * computes for a touch (GameSurfaceLayout.map against the same guest size and
 * the same rect). So a dialog is drawn where a tap on it lands, in Absolute,
 * Relative and Touch pointer modes alike, with no mapping of its own to keep
 * in step. When no GDI window exists, nothing here runs and input mapping is
 * byte-for-byte what it was.
 *
 * TOUCHES. A CALayer is not a view and has no hit-testing, so the overlay can
 * never intercept a touch — "it must not steal input once the dialog is gone"
 * is structural here rather than something to remember to switch off.
 * ============================================================ */

/* The overlay container. nil whenever no GDI window exists, so its mere
 * existence is the answer to "is a direct-launch window on screen". */
static CALayer *g_overlay;

/* Overlay windows currently VISIBLE. Written on the main thread by
 * winios_overlay_refresh_live, read from wine threads in win32u's blocking
 * message wait — see winios_overlay_window_count. */
static _Atomic unsigned g_overlay_live;

/* MADEIRA_DIRECT_OVERLAY=0 -> behave exactly as before this existed. Cached
 * once, like every other env knob in this file; announced once so a device log
 * distinguishes "the overlay decided there was nothing to draw" from "the
 * overlay was switched off". */
static int winios_overlay_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MADEIRA_DIRECT_OVERLAY");
        on = !(e && *e == '0');
        if (!on) {
            fprintf(stderr, "[overlay] disabled by MADEIRA_DIRECT_OVERLAY=0 — "
                            "ordinary GDI windows will not be shown in a direct launch\n");
            fflush(stderr);
        }
    }
    return on;
}

static int winios_overlay_active(void) {
    return !winios_cursor_desktop_mode() && winios_overlay_enabled();
}

/* Windows that HOST the presented Metal layer. A fixed table of atomics
 * rather than a dictionary + lock because the reader is win32u's GDI flush
 * path on a wine thread: it must not block, and in practice there is one
 * entry (a swapchain per D3D device). Overflow just means a window is not
 * recognised, which is the pre-overlay behaviour for it. */
#define WINIOS_METAL_HWNDS 8
static _Atomic(uintptr_t) g_metal_hwnds[WINIOS_METAL_HWNDS];

void winios_overlay_note_metal_hwnd(void *hwnd) {
    uintptr_t v = (uintptr_t)hwnd;
    if (!v || !winios_overlay_active()) return;
    for (int i = 0; i < WINIOS_METAL_HWNDS; i++) {
        uintptr_t expected = 0;
        if (atomic_load(&g_metal_hwnds[i]) == v) return;      /* already known */
        if (atomic_compare_exchange_strong(&g_metal_hwnds[i], &expected, v)) {
            fprintf(stderr, "[overlay] metal window hwnd=%p — its GDI surface will not be drawn\n",
                    hwnd);
            fflush(stderr);
            /* A D3D window normally paints its client area (black) once
             * before the swapchain exists, so a layer for it may already be
             * up and covering the first frames. Retire it now. */
            winios_remove_layer((HWND)hwnd);
            return;
        }
    }
}

/* ml1110 — "is a Metal layer presenting". Registration happens once per
 * swapchain (winios_overlay_note_metal_hwnd above), and the slots fill in
 * order, so slot 0 alone answers it. */
static int winios_overlay_metal_live(void) {
    return atomic_load(&g_metal_hwnds[0]) != 0;
}

int winios_overlay_skip_hwnd(void *hwnd) {
    uintptr_t v = (uintptr_t)hwnd;
    if (!v || !winios_overlay_active()) return 0;
    for (int i = 0; i < WINIOS_METAL_HWNDS; i++) {
        uintptr_t s = atomic_load(&g_metal_hwnds[i]);
        if (!s) break;                    /* slots fill in order */
        if (s == v) return 1;
    }
    return 0;
}

unsigned winios_overlay_window_count(void) {
    return atomic_load(&g_overlay_live);
}

/* ml1110 — A WINDOW BIGGER THAN THE GUEST DESKTOP, WITH NO WAY TO MOVE IT.
 *
 * In a desktop session an oversized window is a nuisance: the user drags it, or
 * the taskbar gets them back to it. A DIRECT launch has no window manager, no
 * title-bar drag that goes anywhere useful and no keyboard Alt+Space — whatever
 * hangs off the guest desktop is simply unreachable forever. Programs do size
 * themselves past the screen (a 1286x1011 window on a 1280x720 desktop is what
 * prompted this), and nothing else in the pipeline can recover it.
 *
 * So when the union of what the overlay actually draws is larger than the guest
 * desktop, map that UNION into the game rect instead of the desktop: one
 * uniform scale (aspect preserved — a non-uniform fit would shear every window
 * and break the touch inverse), centred, and never magnifying, because the
 * union always contains the desktop rect. When nothing overflows, the union IS
 * the desktop rect and the mapping is byte-for-byte what it was before — the
 * per-axis sx/sy of the ml1090 mapping, not a uniform scale, so Stretch mode
 * keeps stretching exactly as it did.
 *
 * Gated on "no Metal layer is presenting": once a swapchain exists, the game
 * image owns the game rect and its scale is DXMT's, so shrinking the overlay
 * under it would put every GDI window in a coordinate system the presented
 * frame does not share. MADEIRA_OVERLAY_FIT=0 disables the whole thing.
 *
 * Swift's touch mapping reads the same three numbers back through
 * winios_overlay_fit_source() and inverts them, which is what keeps
 * MetalBackedView.mapPoint an exact inverse of this. */
static CGRect g_fit_src;        /* guest px: the rect that maps onto the game rect */
static CGFloat g_fit_scale;     /* guest px -> points, uniform, fit only */
static CGPoint g_fit_org;       /* game-rect points: where g_fit_src's top-left lands */
static int g_fit_active;

static int winios_overlay_fit_active(void) { return g_fit_active; }

static int winios_overlay_fit_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MADEIRA_OVERLAY_FIT");
        on = !(e && *e == '0');
        if (!on) {
            fprintf(stderr, "[overlay] fit disabled by MADEIRA_OVERLAY_FIT=0 — a window larger "
                            "than the guest desktop will hang off the game rect\n");
            fflush(stderr);
        }
    }
    return on;
}

/* main thread only. Recomputes the guest->overlay mapping from the windows
 * currently on screen. Cheap: a handful of dictionary entries, run only when a
 * window appears, moves, is hidden or first delivers its bits. */
static void winios_overlay_recompute_fit(void) {
    int gw = 0, gh = 0;
    winios_screen_size(&gw, &gh);
    if (gw <= 0) gw = 1024;
    if (gh <= 0) gh = 768;
    CGRect desk = CGRectMake(0, 0, gw, gh), src = desk;

    if (winios_overlay_fit_enabled() && !winios_overlay_metal_live()) {
        for (NSNumber *key in g_px_rects) {
            CALayer *l = g_layers[key];
            if (!l || l.hidden) continue;
            /* Only a window that OWNS a surface has an extent worth reserving
             * room for: a child paints into an ancestor's bits and is already
             * inside it, and a window that has never flushed has nothing to
             * show yet. winios_window_drawn_rect is empty for both, and it is
             * the DRAWN rect rather than the window rect deliberately — the
             * rows win32u cropped away have no bits and reserving screen space
             * for them would shrink everything else for a blank strip. */
            CGRect drawn = winios_window_drawn_rect(key, NULL);
            if (CGRectIsEmpty(drawn)) continue;
            src = CGRectUnion(src, drawn);
        }
    }

    CGSize hb = winios_game_rect_size();
    int active = !CGRectEqualToRect(src, desk) && hb.width > 0 && hb.height > 0;
    CGFloat k = active ? MIN(hb.width / src.size.width, hb.height / src.size.height) : 0;
    CGPoint org = active ? CGPointMake((hb.width - src.size.width * k) / 2,
                                       (hb.height - src.size.height * k) / 2)
                         : CGPointZero;

    if (active == g_fit_active && CGRectEqualToRect(src, g_fit_src)
        && k == g_fit_scale && CGPointEqualToPoint(org, g_fit_org)) return;
    g_fit_src = src;
    g_fit_scale = k;
    g_fit_org = org;
    g_fit_active = active;
    fprintf(stderr, "[overlay] fit %s src={%.0f,%.0f %.0fx%.0f} desktop=%dx%d "
                    "game-rect=%.0fx%.0f scale=%.4f origin=(%.1f,%.1f)\n",
            active ? "ON" : "off (windows fit the guest desktop)",
            src.origin.x, src.origin.y, src.size.width, src.size.height,
            gw, gh, hb.width, hb.height, (double)k, org.x, org.y);
    fflush(stderr);

    /* Every window layer (and the cursor) is placed through this mapping. */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSNumber *key in g_px_rects) winios_place_window_layer(key);
    [CATransaction commit];
    winios_cursor_relayout();
}

/* See Winios.h. Reports the guest-pixel rect the overlay currently maps onto
 * the game rect, so Swift can invert exactly this transform for a touch. */
int winios_overlay_fit_source(double *x, double *y, double *w, double *h) {
    if (!g_fit_active) return 0;
    if (x) *x = g_fit_src.origin.x;
    if (y) *y = g_fit_src.origin.y;
    if (w) *w = g_fit_src.size.width;
    if (h) *h = g_fit_src.size.height;
    return 1;
}

/* Guest pixel rect -> the overlay's own (game-layer-local) coordinate space.
 * The two numbers are the same ones winios_cursor_place reads, and for the
 * same reasons its doc comment gives: g_game_layer.bounds IS the current game
 * rect's size at local origin (0,0), and winios_screen_size() is the LIVE
 * guest resolution, not a launch-time constant. */
static CGRect winios_overlay_layer_rect(int x, int y, int w, int h) {
    int gw = 0, gh = 0;
    winios_screen_size(&gw, &gh);
    if (gw <= 0) gw = 1024;
    if (gh <= 0) gh = 768;
    CGSize hb = winios_game_rect_size();   /* ml1090 — published rect first */
    if (g_fit_active && g_fit_scale > 0) {  /* ml1110 — see g_fit_src above */
        CGFloat k = g_fit_scale;
        return CGRectMake(g_fit_org.x + (x - g_fit_src.origin.x) * k,
                          g_fit_org.y + (y - g_fit_src.origin.y) * k, w * k, h * k);
    }
    CGFloat sx = hb.width / gw, sy = hb.height / gh;
    return CGRectMake(x * sx, y * sy, w * sx, h * sy);
}

/* ml1110 — the same mapping for a POINT, for the drawn cursor. Returns 0 when
 * there is no usable game rect yet (the caller then leaves the cursor alone).
 * `*scale` is the per-axis scale the caller sizes its glyph by. */
static int winios_overlay_map_px(CGFloat x, CGFloat y, CGPoint *out, CGSize *scale) {
    int gw = 0, gh = 0;
    winios_screen_size(&gw, &gh);
    if (gw <= 0) gw = 1024;
    if (gh <= 0) gh = 768;
    CGSize hb = winios_game_rect_size();
    if (hb.width <= 0 || hb.height <= 0) return 0;
    if (g_fit_active && g_fit_scale > 0) {
        if (out) *out = CGPointMake(g_fit_org.x + (x - g_fit_src.origin.x) * g_fit_scale,
                                    g_fit_org.y + (y - g_fit_src.origin.y) * g_fit_scale);
        if (scale) *scale = CGSizeMake(g_fit_scale, g_fit_scale);
        return 1;
    }
    CGFloat sx = hb.width / gw, sy = hb.height / gh;
    if (out) *out = CGPointMake(x * sx, y * sy);
    if (scale) *scale = CGSizeMake(sx, sy);
    return 1;
}

/* main thread only */
static void winios_ensure_overlay(void) {
    if (g_overlay) return;
    if (!winios_overlay_active()) return;
    /* Swift publishes the game layer once, at first attach (MetalBackedView.
     * didMoveToWindow), long before any program runs — so this is only ever
     * nil in the window between app launch and that attach, where retrying on
     * the next flush is exactly right. */
    if (!g_game_layer) return;
    if (!g_layers) g_layers = [NSMutableDictionary new];
    if (!g_px_rects) g_px_rects = [NSMutableDictionary new];
    if (!g_surf_sizes) g_surf_sizes = [NSMutableDictionary new];
    g_overlay = [CALayer layer];
    g_overlay.anchorPoint = CGPointMake(0, 0);
    /* ml1090: the published game rect — see winios_game_rect_size. The layer's
     * own bounds are not yet the laid-out rect before the first Present. */
    g_overlay.frame = (CGRect){ CGPointZero, winios_game_rect_size() };
    g_overlay.zPosition = 5000;    /* above the drawable, below the cursor's 10000 */
    /* A program may size its window past the guest desktop; without this the
     * window's layer is drawn outside the game rect, over the app's own controls. */
    g_overlay.masksToBounds = YES;
    int gw = 0, gh = 0;
    winios_screen_size(&gw, &gh);
    [g_game_layer addSublayer:g_overlay];
    fprintf(stderr, "[overlay] created host=%p game-rect=%.0fx%.0f (layer bounds %.0fx%.0f) guest=%dx%d\n",
            g_game_layer, g_overlay.frame.size.width, g_overlay.frame.size.height,
            g_game_layer.bounds.size.width, g_game_layer.bounds.size.height, gw, gh);
    fflush(stderr);
}

/* main thread only. The one place that decides both "how many overlay windows
 * are on screen" (which win32u polls on) and "is the overlay still needed",
 * so those two can never disagree. Teardown waits for the last window to be
 * DESTROYED rather than merely hidden: a dialog that is hidden and shown again
 * keeps its layer and its content, and a transparent container with nothing
 * but hidden sublayers costs nothing and cannot take a touch. */
static void winios_overlay_refresh_live(void) {
    if (!winios_overlay_active()) return;   /* desktop mode is not involved */
    unsigned n = 0;
    for (NSNumber *key in g_layers) {
        CALayer *l = g_layers[key];
        if (l && !l.hidden) n++;
    }
    atomic_store(&g_overlay_live, n);
    /* ml1090: the same count is the direct-launch pointer's "is there anything
     * of ours on screen" signal — see winios_cursor_note_gdi_windows. */
    winios_cursor_note_gdi_windows(n);
    /* ml1110: which windows are on screen, and how big, is exactly what the
     * fit scales by — so this is the one place that decides all three. */
    winios_overlay_recompute_fit();
    if (!g_overlay || g_layers.count) return;
    [g_overlay removeFromSuperlayer];
    g_overlay = nil;
    fprintf(stderr, "[overlay] emptied — last GDI window destroyed, overlay removed\n");
    fflush(stderr);
}

/* main thread only. The host for per-window layers in the CURRENT mode. */
static CALayer *winios_ensure_window_host(void) {
    if (!winios_overlay_active()) {
        winios_ensure_compositor();
        return g_compositor_view.layer;
    }
    winios_ensure_overlay();
    return g_overlay;
}

/* See Winios.h. Same trigger as winios_cursor_relayout, from the same Swift
 * call site: both are sublayers of a game layer whose rect just moved. */
void winios_overlay_relayout(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_overlay || !g_game_layer) return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_overlay.frame = (CGRect){ CGPointZero, winios_game_rect_size() };   /* ml1090 */
        for (NSNumber *key in g_px_rects) winios_place_window_layer(key);
        [CATransaction commit];
        /* ml1110: the game rect just changed, and the fit is measured against
         * it. Re-places the layers again only if the mapping actually moved. */
        winios_overlay_recompute_fit();
    });
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
