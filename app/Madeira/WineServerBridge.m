// WineServerBridge.m - Run Wine's wineserver as a thread on iOS
// This bridges the wineserver (compiled as a static library) into the iOS app.

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <sys/stat.h>
#import <pthread.h>
#import <stdarg.h>

#include "WineServerBridge.h"
#include <sys/time.h>

static FILE *g_ws_bridge_log = NULL;
static pthread_mutex_t g_ws_bridge_log_mutex = PTHREAD_MUTEX_INITIALIZER;

static void wine_log_msg_impl(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void wine_log_msg_impl(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%s", buf);
    extern void wine_ui_log(const char *message);
    wine_ui_log(buf);
    pthread_mutex_lock(&g_ws_bridge_log_mutex);
    if (g_ws_bridge_log) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);
        fprintf(g_ws_bridge_log, "[%02d:%02d:%02d.%03d] %s\n",
                tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec/1000), buf);
        fflush(g_ws_bridge_log);
    }
    pthread_mutex_unlock(&g_ws_bridge_log_mutex);
}

#define wine_log_msg(fmt, ...) wine_log_msg_impl("[Wine] " fmt, ##__VA_ARGS__)

// The wineserver's main() renamed to wineserver_main()
extern int wineserver_main(int argc, char *argv[]);

// File logging for wineserver C code (defined in wine_log_ios.h, linked from libwineserver.a)
extern void wineserver_log_set_file(const char *path);

// Set NLS directory for wineserver (defined in unicode_ios.c)
extern void wineserver_set_nls_dir(const char *path);

// Override wineserver's fatal_error to use logging and pthread_exit instead of exit(1)
void fatal_error( const char *err, ... ) {
    va_list args;
    char buf[1024];
    va_start(args, err);
    vsnprintf(buf, sizeof(buf), err, args);
    va_end(args);
    wine_log_msg_impl("[Wine] FATAL: %s", buf);
    // Don't call exit(1) — that kills the whole app.
    // Instead, terminate just this thread.
    pthread_exit(NULL);
}

// Wineserver globals we need to set before calling main
extern int foreground;
extern int debug_level;

// Stop flag checked by wineserver event loop (fd_ios.c)
volatile int g_wineserver_should_stop = 0;
int g_wineserver_session_stop = 0;
int g_wineserver_root_retired = 0;

static pthread_t g_wineserver_thread;
static int g_wineserver_running = 0;
static char *g_prefix_path = NULL;

static void wineserver_thread_finished(void *arg) {
    (void)arg;
    /* Server timeout/fatal paths use pthread_exit, skipping ordinary returns. */
    __atomic_store_n(&g_wineserver_running, 0, __ATOMIC_RELEASE);
}

static void *wineserver_thread_func(void *arg) {
    pthread_cleanup_push(wineserver_thread_finished, NULL);
    @autoreleasepool {
        // Set up file-based logging
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *logPath = [docs stringByAppendingPathComponent:@"madeira-log.txt"];
        pthread_mutex_lock(&g_ws_bridge_log_mutex);
        if (g_ws_bridge_log) fclose(g_ws_bridge_log);
        g_ws_bridge_log = fopen(logPath.UTF8String, "a");
        pthread_mutex_unlock(&g_ws_bridge_log_mutex);
        // Also set up logging for wineserver C code (main_ios.c, fd_ios.c, request_ios.c)
        wineserver_log_set_file(logPath.UTF8String);

        // Redirect wineserver stderr to log file
        {
            int logfd = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (logfd >= 0) {
                dup2(logfd, STDERR_FILENO);
                close(logfd);
            }
        }

        // Test that ws_log works from here
        extern void ws_log(const char *fmt, ...);
        ws_log("[wineserver-bridge] ws_log test - log file set up OK");

        wine_log_msg("Wineserver thread started");

        // Set up environment for wineserver
        setenv("WINEPREFIX", g_prefix_path, 1);
        setenv("HOME", g_prefix_path, 1);  // Fallback if WINEPREFIX not used

        wine_log_msg("WINEPREFIX=%s", g_prefix_path);

        // Create the Wine prefix directory if it doesn't exist
        mkdir(g_prefix_path, 0755);

        // Tell wineserver where NLS files are (inside the app bundle)
        NSString *nlsDir = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"nls"];
        wineserver_set_nls_dir(nlsDir.UTF8String);
        wine_log_msg("NLS dir=%s", nlsDir.UTF8String);

        // wineserver_main sets foreground=1 based on args, but we set it directly
        foreground = 1;

        // Call wineserver's main function with minimal args
        // No --debug: debug output floods stderr pipe, blocking the main_loop
        char *argv[] = { "wineserver", "--foreground", NULL };
        int argc = 2;

        wine_log_msg("Calling wineserver_main...");
        int ret = wineserver_main(argc, argv);
        wine_log_msg("wineserver_main returned: %d", ret);

    }
    pthread_cleanup_pop(1);
    return NULL;
}

int wineserver_start(const char *prefix_path) {
    if (__atomic_load_n(&g_wineserver_running, __ATOMIC_ACQUIRE)) {
        wine_log_msg("Wineserver already running");
        return 0;
    }

    // Store prefix path
    if (g_prefix_path) free(g_prefix_path);
    g_prefix_path = strdup(prefix_path);

    wine_log_msg("Starting wineserver with prefix: %s", prefix_path);

    /* ml588: seed the prefix BEFORE the server thread starts. init_registry()
     * runs within milliseconds of the thread launching, and if system.reg is
     * not on disk by then the server builds an empty registry and its first
     * save overwrites the template's (ml587: 17,479 keys -> 24). Seeding is
     * idempotent, so this costs one stat() on every launch after the first. */
    {
        extern void madeira_seed_prefix_if_needed(const char *prefix_path);
        madeira_seed_prefix_if_needed(prefix_path);
    }

    __atomic_store_n(&g_wineserver_should_stop, 0, __ATOMIC_RELEASE);
    /* Profiles have already been imported. Refresh both halves together;
     * never flip the cell protocol underneath a running guest session. */
    extern int wine_process_is_running(void);
    const char *reload = getenv("MADEIRA_SESSION_SYNC_RELOAD");
    if (!wine_process_is_running() && (!reload || strcmp(reload, "0"))) {
        extern void madeira_fast_reload_session(void);
        extern void madeira_fastsync_reload_session(void);
        madeira_fast_reload_session();
        madeira_fastsync_reload_session();
        wine_log_msg("[session-policy] ml1170 synchronization settings refreshed before launch");
    }
    __atomic_store_n(&g_wineserver_session_stop, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&g_wineserver_root_retired, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&g_wineserver_running, 1, __ATOMIC_RELEASE);

    /* 2026-07-04 perf: the wineserver thread used to be created at LOWERED
     * priority (sched_priority 20, "so wineserver doesn't starve the main
     * thread"). That made every client server-request round trip wait on a
     * low-priority, E-core-eligible thread — [PROF] showed the game thread
     * parked in read_reply_data (waiting for wineserver replies) for most
     * of each 55ms frame while game threads run USER_INTERACTIVE: textbook
     * priority inversion. The server is on the critical path of every
     * object wait / message pump call — it must run AT LEAST as hot as its
     * clients. */
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);

    int ret = pthread_create(&g_wineserver_thread, &attr, wineserver_thread_func, NULL);
    pthread_attr_destroy(&attr);
    if (ret != 0) {
        wine_log_msg("Failed to create wineserver thread: %d", ret);
        __atomic_store_n(&g_wineserver_running, 0, __ATOMIC_RELEASE);
        return -1;
    }

    // Don't detach — wineserver_stop() will join to ensure clean shutdown
    wine_log_msg("Wineserver thread created");
    return 0;
}

int wineserver_is_running(void) {
    return __atomic_load_n(&g_wineserver_running, __ATOMIC_ACQUIRE);
}

int wineserver_request_session_stop(void) {
    const char *value = getenv("MADEIRA_SESSION_STOP");
    if (!wineserver_is_running() || (value && !strcmp(value, "0"))) return 0;
    __atomic_store_n(&g_wineserver_session_stop, 1, __ATOMIC_RELEASE);
    wine_log_msg("[session-stop] ml1150 queued guest termination");
    return 1;
}

void wineserver_stop(void) {
    wine_log_msg("Wineserver stop requested");
    __atomic_store_n(&g_wineserver_should_stop, 1, __ATOMIC_RELEASE);
    // Join the wineserver thread to ensure it actually stops before we return.
    // This prevents iOS from killing us for excessive CPU from a spinning wineserver.
    pthread_t t = g_wineserver_thread;
    if (t) {
        wine_log_msg("Joining wineserver thread...");
        pthread_join(t, NULL);
        g_wineserver_thread = 0;
        wine_log_msg("Wineserver thread joined");
    }
    __atomic_store_n(&g_wineserver_running, 0, __ATOMIC_RELEASE);
}

void wineserver_finish_session(void) {
    const char *value = getenv("MADEIRA_SESSION_DESCENDANTS");
    if (value && !strcmp(value, "0")) {
        wine_log_msg("[session-handoff] ml1220 descendant retention disabled");
        wineserver_stop();
        return;
    }
    wine_log_msg("[session-handoff] ml1220 original client retired; waiting for applications");
    __atomic_store_n(&g_wineserver_root_retired, 1, __ATOMIC_RELEASE);
    pthread_t thread = g_wineserver_thread;
    if (thread) {
        pthread_join(thread, NULL);
        g_wineserver_thread = 0;
    }
    wine_log_msg("[session-handoff] ml1220 session server joined");
}
