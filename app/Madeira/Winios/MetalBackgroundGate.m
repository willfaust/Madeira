/* GPL-3.0-or-later WITH the Madeira Converter Exception, version 1. */
/* Copyright 2026 ft7t8drgwf-wq */
// MetalBackgroundGate.m -- no Metal command buffer is committed while Madeira
// is not the active app (BackgroundRun.swift installs it; madeira.cfg
// background-gpu-gate = 0 leaves it out).
//
// iOS refuses GPU work from an app in the background: the command buffer
// fails ("Insufficient Permission (to submit GPU work from background)") and
// MoltenVK then marks its VkDevice lost, so a Zink OpenGL game (Project
// Zomboid) never draws again. While Madeira kept running in the background
// only for its few seconds of grace, little could reach the GPU; now that it
// keeps running (BackgroundRun.swift), a game that loads in the background
// uploads textures, and Zink submits them without presenting -- past the
// present gates (madeira_gl_wait_active in WiniosGL.m, winemetal's
// background-pause).
//
// So every -[MTLCommandBuffer commit] made off the main thread waits here from
// WillResignActive until DidBecomeActive: that thread stands still, the
// others (CPU loading) carry on. The main thread never waits: it delivers the
// notification that ends the wait, and Madeira's own UI commits there. The
// concrete command buffer classes the device hands out are found once, at
// install, and their -commit is wrapped. Metal 4 queues (KosmicKrisp) are not
// covered.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#include <pthread.h>
#include <stdio.h>
#include <time.h>

#define MBG_CLASSES 4

static pthread_mutex_t mbg_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t mbg_cond = PTHREAD_COND_INITIALIZER;
static int mbg_inactive;
static unsigned mbg_logged;

static Class mbg_class[MBG_CLASSES];
static IMP mbg_orig[MBG_CLASSES];
static int mbg_count;

static void mbg_set(int inactive) {
    pthread_mutex_lock(&mbg_lock);
    mbg_inactive = inactive;
    pthread_cond_broadcast(&mbg_cond);
    pthread_mutex_unlock(&mbg_lock);
}

static void mbg_wait(void) {
    pthread_mutex_lock(&mbg_lock);
    if (mbg_inactive) {
        struct timespec t0, t1;
        int log = mbg_logged < 32;
        if (log) mbg_logged++;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        if (log) fprintf(stderr, "[metal-bg] app inactive: a command buffer waits until Madeira is active again\n");
        while (mbg_inactive) pthread_cond_wait(&mbg_cond, &mbg_lock);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        if (log) fprintf(stderr, "[metal-bg] app active: committed after %.1f s\n",
                         (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
    }
    pthread_mutex_unlock(&mbg_lock);
}

/* The wrapped -commit: the original of the nearest wrapped class. */
static void mbg_commit(id self, SEL cmd) {
    IMP orig = NULL;
    for (Class c = object_getClass(self); c && !orig; c = class_getSuperclass(c))
        for (int i = 0; i < mbg_count; i++)
            if (mbg_class[i] == c) { orig = mbg_orig[i]; break; }
    if (![NSThread isMainThread]) mbg_wait();
    if (orig) ((void (*)(id, SEL))orig)(self, cmd);
}

static void mbg_wrap(Class cls) {
    if (!cls || mbg_count >= MBG_CLASSES) return;
    for (int i = 0; i < mbg_count; i++)
        if (mbg_class[i] == cls) return;
    Method m = class_getInstanceMethod(cls, @selector(commit));
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (orig == (IMP)mbg_commit) return;
    /* An inherited -commit gets an override on this class only; its own is replaced. */
    if (!class_addMethod(cls, @selector(commit), (IMP)mbg_commit, method_getTypeEncoding(m)))
        orig = method_setImplementation(m, (IMP)mbg_commit);
    mbg_class[mbg_count] = cls;
    mbg_orig[mbg_count] = orig;
    mbg_count++;
    fprintf(stderr, "[metal-bg] command buffers of %s wait while Madeira is in the background\n",
            class_getName(cls));
}

/* Called once on the main thread, before a game starts. Returns the number of classes wrapped. */
int madeira_metal_gate_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            id<MTLCommandQueue> queue = [device newCommandQueue];
            if (!queue) return;
            /* the kinds DXMT, MoltenVK and Mesa ask for; none is committed */
            mbg_wrap(object_getClass([queue commandBuffer]));
            mbg_wrap(object_getClass([queue commandBufferWithUnretainedReferences]));
            MTLCommandBufferDescriptor *d = [MTLCommandBufferDescriptor new];
            d.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
            mbg_wrap(object_getClass([queue commandBufferWithDescriptor:d]));
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:@"UIApplicationWillResignActiveNotification" object:nil queue:nil
                        usingBlock:^(NSNotification *n) { (void)n; mbg_set(1); }];
            [nc addObserverForName:@"UIApplicationDidBecomeActiveNotification" object:nil queue:nil
                        usingBlock:^(NSNotification *n) { (void)n; mbg_set(0); }];
        }
    });
    return mbg_count;
}
