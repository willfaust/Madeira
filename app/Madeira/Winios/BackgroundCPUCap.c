/* GPL-3.0-or-later WITH the Madeira Converter Exception, version 1. */
/* Copyright 2026 ft7t8drgwf-wq */
// BackgroundCPUCap.c -- keeps Madeira's CPU use under a cap while it runs in
// the background (BackgroundRun.swift; madeira.cfg background-cpu, percent of
// one core, default 50; 0 = no cap).
//
// iOS ends an app that keeps running in the background (the audio background
// mode) once it averages more than about 80% of one core over a minute
// ("cpu_resource_fatal", sometimes stricter: 60% over 15 s). A game loading in
// the background uses several cores, so without a cap Madeira would be killed
// a minute after you switch apps -- worse than the pause it replaces.
//
// A governor thread measures the process's CPU time (getrusage) every 100 ms
// against a budget of cap% of one core, with at most 2 s of credit. Over
// budget, it suspends every thread of the process for the next 100 ms except
// itself, the main thread (it delivers the notifications that end the
// background run) and real-time threads (the RemoteIO render thread that keeps
// Madeira running, Wine's audio timer). Under budget, everything runs. The
// game simply runs slower; its threads never see a failure.
//
// Nothing that takes a lock runs while threads are suspended: thread names and
// policies are read, and the log is written, only after the previous pass's
// threads were resumed. The thread list comes from task_threads (vm memory,
// not malloc).

#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define CAP_TICK_US 100000
#define CAP_MAX_HELD 1024

static pthread_mutex_t cap_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cap_cond = PTHREAD_COND_INITIALIZER;
static int cap_percent;            /* wanted cap; 0 = off (under cap_lock) */
static int cap_idle = 1;           /* the governor holds nothing and waits (under cap_lock) */
static int cap_started;
static mach_port_t cap_main_port;

/* What the last background run looked like, for the log (BackgroundRun.swift). */
static _Atomic double cap_cpu_s, cap_wall_s, cap_held_s;

static thread_act_t cap_held[CAP_MAX_HELD];
static unsigned cap_nheld;

static double cap_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double cap_cpu_time(void)
{
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru)) return 0;
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

static void cap_resume_all(void)
{
    unsigned i;
    for (i = 0; i < cap_nheld; i++) {
        thread_resume(cap_held[i]);
        mach_port_deallocate(mach_task_self(), cap_held[i]);
    }
    cap_nheld = 0;
}

/* Real-time threads (Core Audio's render thread, Wine's audio timer) and the audio threads by name. */
static int cap_exempt(thread_act_t t)
{
    thread_time_constraint_policy_data_t pol;
    mach_msg_type_number_t count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
    boolean_t get_default = 0;
    pthread_t pt;
    char name[64] = "";

    if (t == cap_main_port) return 1;
    if (thread_policy_get(t, THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&pol, &count, &get_default) == KERN_SUCCESS
        && !get_default)
        return 1;
    pt = pthread_from_mach_thread_np(t);
    if (pt) pthread_getname_np(pt, name, sizeof(name));
    return strstr(name, "AURemoteIO") || strstr(name, "com.apple.audio") || strstr(name, "caulk");
}

/* Suspend every thread but this one and the exempt ones. Called with nothing held. */
static void cap_hold_all(void)
{
    thread_act_array_t list;
    mach_msg_type_number_t n, i;
    mach_port_t self = mach_thread_self();
    unsigned char keep[CAP_MAX_HELD];

    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), self); return; }
    /* names and policies first: pthread_getname_np takes a lock a suspended thread could hold */
    for (i = 0; i < n && i < CAP_MAX_HELD; i++)
        keep[i] = list[i] == self || cap_exempt(list[i]);
    for (i = 0; i < n; i++) {
        if (i < CAP_MAX_HELD && !keep[i] && cap_nheld < CAP_MAX_HELD && thread_suspend(list[i]) == KERN_SUCCESS) {
            cap_held[cap_nheld++] = list[i];   /* the port right is released when it is resumed */
            continue;
        }
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(*list));
    mach_port_deallocate(mach_task_self(), self);
}

static void *cap_main(void *arg)
{
    (void)arg;
    pthread_setname_np("madeira.bg-cpu-cap");
    for (;;) {
        int percent;
        double credit, last_cpu, last_t, t0, cpu0, held = 0;

        pthread_mutex_lock(&cap_lock);
        cap_idle = 1;
        pthread_cond_broadcast(&cap_cond);
        while (!cap_percent) pthread_cond_wait(&cap_cond, &cap_lock);
        cap_idle = 0;
        percent = cap_percent;
        pthread_mutex_unlock(&cap_lock);

        t0 = last_t = cap_now();
        cpu0 = last_cpu = cap_cpu_time();
        credit = 0.5;   /* a little to start with; at most 2 s */
        fprintf(stderr, "[bg-cpu] cap %d%% of one core while Madeira is in the background\n", percent);
        for (;;) {
            double now, cpu, dt;
            int stop;
            usleep(CAP_TICK_US);
            /* the threads held for the last tick run again before anything else */
            if (cap_nheld) { held += CAP_TICK_US / 1e6; cap_resume_all(); }
            pthread_mutex_lock(&cap_lock);
            stop = cap_percent != percent;
            pthread_mutex_unlock(&cap_lock);
            now = cap_now();
            cpu = cap_cpu_time();
            dt = now - last_t;
            credit += dt * percent / 100.0 - (cpu - last_cpu);
            if (credit > 2.0) credit = 2.0;
            last_t = now;
            last_cpu = cpu;
            atomic_store(&cap_wall_s, now - t0);
            atomic_store(&cap_cpu_s, cpu - cpu0);
            atomic_store(&cap_held_s, held);
            if (stop) break;
            if (credit < 0) cap_hold_all();
        }
        {
            double wall = atomic_load(&cap_wall_s), used = atomic_load(&cap_cpu_s);
            fprintf(stderr, "[bg-cpu] off after %.0f s: %.0f%% of one core on average, threads held %.0f%% of the time\n",
                    wall, wall > 0 ? 100.0 * used / wall : 0.0, wall > 0 ? 100.0 * held / wall : 0.0);
        }
    }
    return NULL;
}

/* Start (percent > 0) or end (0) the cap. Ending it returns once every held thread runs again. */
/* The main thread's port, taken while the image loads (constructors run on
 * the main thread): pthread_main_thread_np() is not in the iOS SDK. */
__attribute__((constructor)) static void cap_note_main_thread(void)
{
    cap_main_port = pthread_mach_thread_np(pthread_self());
}

void madeira_bg_cpu_cap(int percent)
{
    pthread_mutex_lock(&cap_lock);
    if (percent > 0 && !cap_started) {
        pthread_t th;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
        if (pthread_create(&th, &attr, cap_main, NULL) == 0) { pthread_detach(th); cap_started = 1; }
        pthread_attr_destroy(&attr);
        if (!cap_started) { pthread_mutex_unlock(&cap_lock); fprintf(stderr, "[bg-cpu] governor thread not started\n"); return; }
    }
    cap_percent = percent > 0 ? (percent > 400 ? 400 : percent) : 0;
    pthread_cond_broadcast(&cap_cond);
    if (!cap_percent && cap_started) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += 500 * 1000000L;
        if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
        while (!cap_idle && pthread_cond_timedwait(&cap_cond, &cap_lock, &until) == 0) {}
    }
    pthread_mutex_unlock(&cap_lock);
}

/* The current (or last) run: CPU seconds, wall seconds and seconds with threads held. */
void madeira_bg_cpu_stats(double *cpu_s, double *wall_s, double *held_s)
{
    *cpu_s = atomic_load(&cap_cpu_s);
    *wall_s = atomic_load(&cap_wall_s);
    *held_s = atomic_load(&cap_held_s);
}
