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

static void *madeira_vulkan_dlopen( const char *name, int flags );
static int madeira_vulkan_pthread_once( pthread_once_t *once, void (*init)(void) );

/* config_ios.h #undefs it for every translation unit; this one loads the library
 * itself (madeira_vulkan_dlopen), so the name is only what the ERR line prints. */
#undef SONAME_LIBVULKAN
#define SONAME_LIBVULKAN "MADEIRA_VULKAN_LIBRARY"
#define dlopen( name, flags ) madeira_vulkan_dlopen( name, flags )
#define pthread_once( once, init ) madeira_vulkan_pthread_once( once, init )
#include "../../wine/dlls/win32u/vulkan.c"
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
    if (!(handle = dlopen( path, flags )))
        dprintf( 2, "[winios-vk] cannot load %s: %s\n", path, dlerror() );
    else
        dprintf( 2, "[winios-vk] Vulkan library %s loaded\n", path );
    return handle;
}


/***********************************************************************
 * winios Vulkan driver: VK_KHR_win32_surface on VK_EXT_metal_surface
 *
 * Mirrors winemac.drv's vulkan.c. The surface's layer is the CAMetalLayer a
 * D3D swapchain on the same window would present to (IOSDisplayShim.m); the
 * window is marked as presenting through Metal, like a DXMT swapchain's. Without
 * a layer (or without VK_EXT_metal_surface) it falls back to win32u's own
 * headless surface, which renders but shows nothing.
 */

/* app/Madeira/IOSDisplayShim.m; weak so a build without it still links */
extern void *madeira_vulkan_layer_for_hwnd( void *hwnd ) __attribute__((weak));

static BOOL winios_vk_metal_surface;

static VkResult winios_vulkan_surface_create( HWND hwnd, const struct vulkan_instance *instance,
                                              VkSurfaceKHR *surface, struct client_surface **client )
{
    VkMetalSurfaceCreateInfoEXT info = {.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
    VkResult res;

    if (!(*client = nulldrv_client_surface_create( hwnd ))) return VK_ERROR_OUT_OF_HOST_MEMORY;

    if (winios_vk_metal_surface && instance->p_vkCreateMetalSurfaceEXT && madeira_vulkan_layer_for_hwnd)
        info.pLayer = madeira_vulkan_layer_for_hwnd( hwnd );

    if (info.pLayer)
    {
        res = instance->p_vkCreateMetalSurfaceEXT( instance->host.instance, &info, NULL, surface );
        dprintf( 2, "[winios-vk] metal surface for hwnd %p (layer %p): %d\n", hwnd, info.pLayer, res );
    }
    else if (instance->p_vkCreateHeadlessSurfaceEXT)
    {
        VkHeadlessSurfaceCreateInfoEXT headless = {.sType = VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT};
        res = instance->p_vkCreateHeadlessSurfaceEXT( instance->host.instance, &headless, NULL, surface );
        dprintf( 2, "[winios-vk] no CAMetalLayer for hwnd %p: headless surface (nothing is shown): %d\n",
                 hwnd, res );
    }
    else res = VK_ERROR_INCOMPATIBLE_DRIVER;

    if (res)
    {
        client_surface_release( *client );
        *client = NULL;
    }
    return res;
}

static VkBool32 winios_get_physical_device_presentation_support( struct vulkan_physical_device *physical_device,
                                                                 uint32_t queue )
{
    return VK_TRUE;
}

static void winios_map_instance_extensions( struct vulkan_instance_extensions *extensions )
{
    if (winios_vk_metal_surface)
    {
        if (extensions->has_VK_KHR_win32_surface) extensions->has_VK_EXT_metal_surface = 1;
        if (extensions->has_VK_EXT_metal_surface) extensions->has_VK_KHR_win32_surface = 1;
    }
    else
    {
        if (extensions->has_VK_KHR_win32_surface) extensions->has_VK_EXT_headless_surface = 1;
        if (extensions->has_VK_EXT_headless_surface) extensions->has_VK_KHR_win32_surface = 1;
    }
}

static void winios_map_device_extensions( struct vulkan_device_extensions *extensions )
{
}

static const struct vulkan_driver_funcs winios_vulkan_driver_funcs =
{
    .p_vulkan_surface_create = winios_vulkan_surface_create,
    .p_get_physical_device_presentation_support = winios_get_physical_device_presentation_support,
    .p_map_instance_extensions = winios_map_instance_extensions,
    .p_map_device_extensions = winios_map_device_extensions,
};

UINT winios_VulkanInit( UINT version, void *vulkan_handle, const struct vulkan_driver_funcs **driver_funcs )
{
    if (version != WINE_VULKAN_DRIVER_VERSION)
    {
        ERR( "version mismatch, win32u wants %u but driver has %u\n", version, WINE_VULKAN_DRIVER_VERSION );
        return STATUS_INVALID_PARAMETER;
    }
    winios_vk_metal_surface = vulkan_handle && dlsym( vulkan_handle, "vkCreateMetalSurfaceEXT" );
    dprintf( 2, "[winios-vk] driver ready (%s surfaces)\n",
             winios_vk_metal_surface ? "VK_EXT_metal_surface" : "headless" );
    *driver_funcs = &winios_vulkan_driver_funcs;
    return STATUS_SUCCESS;
}
