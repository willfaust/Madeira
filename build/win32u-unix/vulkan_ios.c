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
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
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
static int madeira_vulkan_pthread_once( pthread_once_t *once, void (*init)(void) );

/* config_ios.h #undefs it for every translation unit; this one loads the library
 * itself (madeira_vulkan_dlopen), so the name is only what the ERR line prints. */
#undef SONAME_LIBVULKAN
#define SONAME_LIBVULKAN "MADEIRA_VULKAN_LIBRARY"
#define dlopen( name, flags ) madeira_vulkan_dlopen( name, flags )
#define dlsym ios_vulkan_sym
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



#include "vulkan_surface_ios.c"
