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
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <unistd.h>

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

/* ml803: the diagnostics gate the launch sequence already sets.
 *
 * `MADEIRA_QUIET=1` is exported for every production run (WineProcessBridge)
 * and its comment claims it disables "per-present log lines (100+/s at RAW
 * rates)" — but the compositor and the input bridge never consulted it, so the
 * hot paths kept logging anyway: one 4096-probe surface census plus an
 * fprintf+fflush on every present of every window ≥400x400 for its first 2000
 * presents, one fprintf+fflush per drained input event, and one per posted
 * touch/key. Those are synchronous writes on the present and input paths, so
 * the cost is not only CPU — it is latency added to the frame and to every
 * mouse sample in a mouse-look. Resolved once; a run cannot flip it. */
static int winios_quiet(void) {
    static int quiet = -1;
    if (quiet < 0) quiet = getenv("MADEIRA_QUIET") != NULL;
    return quiet;
}

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

void winios_pDestroyWindow(HWND hwnd) {
    WLOG("pDestroyWindow hwnd=%p", hwnd);
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
    if (!winios_quiet()) {
        fprintf(stderr, "[winios] post_touch_down x=%d y=%d\n", x, y);
        fflush(stderr);
    }
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, 0);
}

void winios_post_touch_move(int x, int y) {
    static unsigned cnt;
    if (!winios_quiet() && (cnt % 30) == 0) {
        fprintf(stderr, "[winios] post_touch_move x=%d y=%d (n=%u)\n", x, y, cnt + 1);
        fflush(stderr);
    }
    cnt++;
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, 0);
}

void winios_post_touch_up(int x, int y) {
    if (!winios_quiet()) {
        fprintf(stderr, "[winios] post_touch_up x=%d y=%d\n", x, y);
        fflush(stderr);
    }
    winios_q_push_ev(WINIOS_EV_MOUSE, x, y, MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, 0);
}

/* Key press bridge. vk = Windows virtual-key code, down = 1 for press,
 * 0 for release. Queued like mouse events; drained in pProcessEvents. */
void winios_post_key(int vk, int down) {
    if (!winios_quiet()) {
        fprintf(stderr, "[winios] post_key vk=0x%x down=%d\n", vk, down);
        fflush(stderr);
    }
    winios_q_push_ev(WINIOS_EV_KEY, vk, 0, down ? 0 : KEYEVENTF_KEYUP, 0);
}

BOOL winios_pProcessEvents(DWORD mask) {
    static unsigned int cnt;
    if ((cnt++ % 240) == 0 && !winios_quiet()) {
        fprintf(stderr, "[winios] pProcessEvents called n=%u\n", cnt); fflush(stderr);
    }
    /* Desktop debugging: dump the full window tree every ~5s. Runs on
     * this wine thread (valid TEB — the dump walks win32u internals).
     * ml803: gated — it walks win32u internals and prints, every 5s, for
     * the whole session, which is a diagnostic and not a heartbeat. */
    static int desk = -1;
    if (desk < 0) desk = ({ const char *d = getenv("MADEIRA_DESKTOP"); d && *d == '1'; });
    if (desk && !winios_quiet()) {
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

        /* ml803: this is the input path, and the log write was synchronous
         * (fprintf + fflush) on every single event. A mouse-look posts one
         * relative move per tick, so the write landed between the sample and
         * the game seeing it. */
        if (!winios_quiet()) {
            fprintf(stderr, "[winios] drain type=%u x=%d y=%d flags=0x%x\n", e.type, e.x, e.y, e.flags);
            fflush(stderr);
        }
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
static UIView *g_compositor_view;
static CALayer *g_desk_bg;               /* teal desktop-area backdrop */
static CGFloat g_px_to_pt = 1.0 / 3.0;   /* desktop px → screen pt */
static CGPoint g_desk_origin;            /* desktop (0,0) in view pt (letterbox offset) */
static CGRect g_comp_frame;              /* presentation area (window coords), from Swift */
static BOOL g_comp_frame_set;

static CGRect winios_layer_rect(int x, int y, int w, int h) {
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

    const char *dw = getenv("MADEIRA_SCREEN_W"), *dh = getenv("MADEIRA_SCREEN_H");
    int desk_w = dw ? atoi(dw) : 1024, desk_h = dh ? atoi(dh) : 768;
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
    /* letterbox area: near-black; desktop area: classic teal (until
     * explorer's own background paint works) */
    g_compositor_view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    g_desk_bg = [CALayer layer];
    g_desk_bg.backgroundColor = [UIColor colorWithRed:0.0 green:0.502 blue:0.502 alpha:1.0].CGColor;
    [g_compositor_view.layer addSublayer:g_desk_bg];
    [win addSubview:g_compositor_view];
    winios_layout_compositor();
    fprintf(stderr, "[winios] compositor attached inside presentation frame\n");
    fflush(stderr);
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
static void winios_place_metal_layer(NSNumber *key) {
    CAMetalLayer *ml = g_metal_layers[key];
    if (!ml) return;
    NSValue *wv = g_px_rects[key], *cv = g_client_rects[key];
    if (!wv || !cv) return;
    CGRect w = wv.CGRectValue, c = cv.CGRectValue;
    CGFloat s = g_px_to_pt;
    ml.frame = CGRectMake((c.origin.x - w.origin.x) * s,
                          (c.origin.y - w.origin.y) * s,
                          c.size.width * s, c.size.height * s);
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
    dispatch_async(dispatch_get_main_queue(), ^{
        winios_ensure_compositor();
        if (!g_compositor_view) return;
        CALayer *l = winios_layer_for(hwnd, true);
        NSNumber *key = @((uintptr_t)hwnd);
        g_px_rects[key] = [NSValue valueWithCGRect:CGRectMake(x, y, w, h)];
        if (!g_client_rects) g_client_rects = [NSMutableDictionary new];
        g_client_rects[key] = [NSValue valueWithCGRect:CGRectMake(cx, cy, cw, ch)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        l.frame = winios_layer_rect(x, y, w, h);
        l.hidden = !visible;
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
 * whole DIB. Copy immediately — `bits` is only valid for this call. */
void winios_surface_present(HWND hwnd, int dx, int dy, int dw, int dh,
                            int sw, int sh, int stride, const void *bits) {
    if (sw <= 0 || sh <= 0 || !bits) return;
    NSData *data = [NSData dataWithBytes:bits length:(size_t)stride * sh];
    const int quiet = winios_quiet();
    static int dumpSurf = -1;
    if (dumpSurf < 0) dumpSurf = getenv("MADEIRA_DUMP_SURFACES") != NULL && !quiet;
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
        if (seqFrames > 0 && !quiet && sw >= seqMinDim && sh >= seqMinDim) {
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
    if (sentinelMode < 0) sentinelMode = getenv("MADEIRA_SURF_SENTINEL") != NULL && !quiet;
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

    if (!quiet && (mycnt <= 16 || (mycnt % 200) == 0 ||
        (sw >= 400 && sh >= 400 && mycnt <= 2000))) {
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
        if (!g_compositor_view) return;
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
            g_surf_sizes[key] = [NSValue valueWithCGSize:CGSizeMake(sw, sh)];
            if (CGRectIsEmpty(l.frame)) {
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

/* main thread only */
static void winios_ensure_cursor_layer(void) {
    if (g_cursor_layer || !g_compositor_view) return;
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
    if (g_cur_w > 0) {
        g_cursor_layer.bounds = CGRectMake(0, 0, g_cur_w * g_px_to_pt, g_cur_h * g_px_to_pt);
        g_cursor_layer.position = CGPointMake(g_desk_origin.x + (x - g_cur_hx) * g_px_to_pt,
                                              g_desk_origin.y + (y - g_cur_hy) * g_px_to_pt);
    } else {
        g_cursor_layer.position = CGPointMake(g_desk_origin.x + x * g_px_to_pt,
                                              g_desk_origin.y + y * g_px_to_pt);
    }
}

void winios_cursor_move(int x, int y) {
    dispatch_async(dispatch_get_main_queue(), ^{
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
