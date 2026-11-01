/* LGPL-2.1-or-later: part of the Wine unix side (see docs/LICENSING.md). */
/*
 * win32u's Vulkan layer on iOS: upstream dlls/win32u/vulkan.c, plus the winios
 * driver's Vulkan surface (VK_EXT_metal_surface on the window's CAMetalLayer).
 *
 * Off unless the session asks for Vulkan. WineProcessBridge.m sets
 * MADEIRA_VULKAN_LIBRARY to the bundled Vulkan library (madeira.cfg
 * `vulkan = moltenvk|kosmickrisp`, or `d3d12 = vkd3d`); without it the dlopen
 * below returns NULL and win32u behaves exactly as when it was built without
 * Vulkan (no Vulkan GPUs, __wine_get_vulkan_driver() == NULL, winevulkan's init
 * fails). The library is loaded by full path, like the GL driver's Zink
 * (opengl_ios.c), so MoltenVK is the same image Zink uses when both run.
 *
 * Re-entrancy: Vulkan's set-up (vulkan_init_once) loads the display driver,
 * which can update the display devices, which list Vulkan's GPUs through
 * D3DKMT's Vulkan instance, which calls __wine_get_vulkan_driver() again on the
 * same thread, inside its own pthread_once. Apple's pthread_once traps on that.
 * While one of this file's pthread_once calls runs on a thread, D3DKMT's
 * instance is NULL on that thread (d3dkmt_ios.c), and that nested GPU listing
 * goes without Vulkan GPUs. The same idea as NutsEmu's Wine patch 0083
 * (no-vulkan-gpu-listing-inside-vulkan-setup), written for this tree.
 *
 * The library's vkGetInstanceProcAddr and vkGetDeviceProcAddr are wrapped
 * (madeira_vulkan_host_sym), so a few host entry points pass through this file
 * first: each present is counted with DXMT's (madeira_note_vulkan_present),
 * queue work waits while Madeira is in the background (madeira_vulkan_wait_active),
 * and an acquire's host VK_SUBOPTIMAL_KHR is handled like a present's
 * (madeira_vulkan_acquired).
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if MADEIRA_MOLTENVK
extern void *madeira_vulkan_symbol(const char *name);
#endif

int madeira_vulkan_static_available(void)
{
#if MADEIRA_MOLTENVK
    return 1;
#else
    return 0;
#endif
}
static char ios_vulkan_token;
static void *ios_vulkan_open(const char *name, int flags)
{
    if (strcmp(name, "madeira-static-moltenvk")) return dlopen(name, flags);
#if !MADEIRA_MOLTENVK
    return NULL;
#else
    fprintf(stderr, "[vk-win32u] binding statically linked MoltenVK backend\n");
    return &ios_vulkan_token;
#endif
}
static void *ios_vulkan_sym(void *handle, const char *name)
{
    if (handle != &ios_vulkan_token) return dlsym(handle, name);
#if MADEIRA_MOLTENVK
    return madeira_vulkan_symbol(name);
#else
    return NULL;
#endif
}
static int ios_vulkan_close(void *handle)
{
    return handle == &ios_vulkan_token ? 0 : dlclose(handle);
}

static void *madeira_vulkan_dlopen( const char *name, int flags );
static void *madeira_vulkan_host_sym( void *handle, const char *name );
static int madeira_vulkan_pthread_once( pthread_once_t *once, void (*init)(void) );

/* config_ios.h #undefs it for every translation unit; this one loads the library
 * itself (madeira_vulkan_dlopen), so the name is only what the ERR line prints. */
#undef SONAME_LIBVULKAN
#define SONAME_LIBVULKAN "MADEIRA_VULKAN_LIBRARY"
#define dlopen( name, flags ) madeira_vulkan_dlopen( name, flags )
#define dlsym madeira_vulkan_host_sym
#define dlclose ios_vulkan_close
#define pthread_once( once, init ) madeira_vulkan_pthread_once( once, init )
#include "../../wine/dlls/win32u/vulkan.c"
#undef dlsym
#undef dlclose
#undef dlopen
#undef pthread_once

/* nonzero while one of vulkan.c's pthread_once calls runs on this thread */
static __thread int madeira_vulkan_init_depth;

int madeira_vulkan_init_on_this_thread( void )
{
    return madeira_vulkan_init_depth != 0;
}

static int madeira_vulkan_pthread_once( pthread_once_t *once, void (*init)(void) )
{
    int ret;

    madeira_vulkan_init_depth++;
    ret = pthread_once( once, init );
    madeira_vulkan_init_depth--;
    return ret;
}

static void *madeira_vulkan_dlopen( const char *name, int flags )
{
    const char *path = getenv( "MADEIRA_VULKAN_LIBRARY" );
    void *handle;

    if (!path || !*path)
    {
        dprintf( 2, "[winios-vk] Vulkan is off for this session (madeira.cfg vulkan / d3d12 = vkd3d "
                    "not set, or the library is not bundled)\n" );
        return NULL;
    }
    /* MoltenVK: errors only, as for Zink (opengl_ios.c); madeira.cfg env.MVK_* wins */
    setenv( "MVK_CONFIG_LOG_LEVEL", "1", 0 );
    if (!(handle = ios_vulkan_open( path, flags )))
        dprintf( 2, "[winios-vk] cannot load %s: %s\n", path, dlerror() );
    else
        dprintf( 2, "[winios-vk] Vulkan library %s loaded\n", path );
    return handle;
}

/* IOSDisplayShim.m: 0 from UIApplicationWillResignActive until DidBecomeActive.
 * WiniosGL.m: one Vulkan present, counted into madeira_frame_count with DXMT's and
 * GL's, so launch detection, the layout after the first frame and the FPS overlay
 * see Vulkan games too. */
extern int madeira_app_active( void );
extern void madeira_note_vulkan_present( void );

/* iOS refuses GPU work from an app that is not in front, and MoltenVK then loses
 * its device for good (VK_ERROR_DEVICE_LOST, "Insufficient Permission (to submit
 * GPU work from background)"): DOOM Eternal died that way when the player switched
 * to another app. Submits and presents wait here instead; the game pauses and
 * carries on when Madeira is active again. */
static void madeira_vulkan_wait_active( const char *what )
{
    unsigned waited = 0;

    while (!madeira_app_active())
    {
        if (!waited++)
            dprintf( 2, "[winios-vk] %s waits: Madeira is not active, and iOS refuses GPU work then\n", what );
        usleep( 16000 );
    }
    if (waited) dprintf( 2, "[winios-vk] %s resumed after about %u ms\n", what, waited * 16 );
}

static PFN_vkGetInstanceProcAddr host_vkGetInstanceProcAddr;
static PFN_vkGetDeviceProcAddr host_vkGetDeviceProcAddr;
static PFN_vkQueueSubmit host_vkQueueSubmit;
static PFN_vkQueueSubmit2 host_vkQueueSubmit2;
static PFN_vkQueueSubmit2KHR host_vkQueueSubmit2KHR;
static PFN_vkQueueBindSparse host_vkQueueBindSparse;
static PFN_vkQueuePresentKHR host_vkQueuePresentKHR;
static PFN_vkAcquireNextImageKHR host_vkAcquireNextImageKHR;
static PFN_vkAcquireNextImage2KHR host_vkAcquireNextImage2KHR;

static VkResult VKAPI_CALL madeira_vkQueueSubmit( VkQueue queue, uint32_t count, const VkSubmitInfo *submits,
                                                  VkFence fence )
{
    madeira_vulkan_wait_active( "vkQueueSubmit" );
    return host_vkQueueSubmit( queue, count, submits, fence );
}

static VkResult VKAPI_CALL madeira_vkQueueSubmit2( VkQueue queue, uint32_t count, const VkSubmitInfo2 *submits,
                                                   VkFence fence )
{
    madeira_vulkan_wait_active( "vkQueueSubmit2" );
    return host_vkQueueSubmit2( queue, count, submits, fence );
}

static VkResult VKAPI_CALL madeira_vkQueueSubmit2KHR( VkQueue queue, uint32_t count, const VkSubmitInfo2 *submits,
                                                      VkFence fence )
{
    madeira_vulkan_wait_active( "vkQueueSubmit2KHR" );
    return host_vkQueueSubmit2KHR( queue, count, submits, fence );
}

static VkResult VKAPI_CALL madeira_vkQueueBindSparse( VkQueue queue, uint32_t count, const VkBindSparseInfo *binds,
                                                      VkFence fence )
{
    madeira_vulkan_wait_active( "vkQueueBindSparse" );
    return host_vkQueueBindSparse( queue, count, binds, fence );
}

static VkResult VKAPI_CALL madeira_vkQueuePresentKHR( VkQueue queue, const VkPresentInfoKHR *present_info )
{
    VkResult res;

    madeira_vulkan_wait_active( "vkQueuePresentKHR" );
    res = host_vkQueuePresentKHR( queue, present_info );
    if (res >= VK_SUCCESS) madeira_note_vulkan_present();
    return res;
}

/* MoltenVK calls a swapchain suboptimal while the layer's bounds times its
 * contentsScale differ from the swapchain extent. Desktop compositor layers are
 * sized in client pixels (VulkanLayerGeometry.h), but a game session presents to
 * MetalHostView's layer (ContentView.swift), which the app lays out in points at
 * the screen's scale, so there MoltenVK calls nearly every swapchain suboptimal.
 * DOOM Eternal recreates its swapchain on that result: on a device it did so on
 * every frame (about 1 fps) until acquires and presents both passed it as success.
 * vulkan.c already does that for a present whose swapchain matches its client rect
 * (ignore_host_suboptimal); acquires get the same here. vulkan.c's check against
 * the client rect, after this call, still reports real resizes, and
 * MADEIRA_VK_HOST_SUBOPTIMAL=1 passes the host result through. */
static VkResult madeira_vulkan_acquired( VkResult res )
{
    return res == VK_SUBOPTIMAL_KHR && ignore_host_suboptimal() ? VK_SUCCESS : res;
}

static VkResult VKAPI_CALL madeira_vkAcquireNextImageKHR( VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
                                                          VkSemaphore semaphore, VkFence fence, uint32_t *index )
{
    return madeira_vulkan_acquired( host_vkAcquireNextImageKHR( device, swapchain, timeout, semaphore, fence, index ) );
}

static VkResult VKAPI_CALL madeira_vkAcquireNextImage2KHR( VkDevice device, const VkAcquireNextImageInfoKHR *info,
                                                           uint32_t *index )
{
    return madeira_vulkan_acquired( host_vkAcquireNextImage2KHR( device, info, index ) );
}

/* One saved host pointer per name: the drivers Madeira bundles (MoltenVK,
 * KosmicKrisp) return the same entry point for every instance and device. */
static PFN_vkVoidFunction madeira_vulkan_wrap( const char *name, PFN_vkVoidFunction fn )
{
    if (!fn || !name) return fn;
#define WRAP( f ) if (!strcmp( name, #f )) { host_##f = (PFN_##f)fn; return (PFN_vkVoidFunction)madeira_##f; }
    WRAP( vkQueueSubmit )
    WRAP( vkQueueSubmit2 )
    WRAP( vkQueueSubmit2KHR )
    WRAP( vkQueueBindSparse )
    WRAP( vkQueuePresentKHR )
    WRAP( vkAcquireNextImageKHR )
    WRAP( vkAcquireNextImage2KHR )
#undef WRAP
    return fn;
}

static PFN_vkVoidFunction VKAPI_CALL madeira_vkGetInstanceProcAddr( VkInstance instance, const char *name )
{
    return madeira_vulkan_wrap( name, host_vkGetInstanceProcAddr( instance, name ) );
}

static PFN_vkVoidFunction VKAPI_CALL madeira_vkGetDeviceProcAddr( VkDevice device, const char *name )
{
    return madeira_vulkan_wrap( name, host_vkGetDeviceProcAddr( device, name ) );
}

/* vulkan.c's dlsym: the library's symbol, with the two lookups above in place of
 * its own. */
static void *madeira_vulkan_host_sym( void *handle, const char *name )
{
    void *fn = ios_vulkan_sym( handle, name );

    if (fn && !strcmp( name, "vkGetInstanceProcAddr" ))
    {
        host_vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)fn;
        return (void *)madeira_vkGetInstanceProcAddr;
    }
    if (fn && !strcmp( name, "vkGetDeviceProcAddr" ))
    {
        host_vkGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)fn;
        return (void *)madeira_vkGetDeviceProcAddr;
    }
    return fn;
}

#include "vulkan_surface_ios.c"
