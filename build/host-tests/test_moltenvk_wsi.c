/* Exercise the actual bridge against the pinned Wine headers, with mock
 * allocation, Metal-layer ownership and Vulkan surface creation.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * With the additional permission in LICENSE-EXCEPTION.md.
 */
#define WINE_UNIX_LIB
#define __WINESRC__
#include <assert.h>
#include <stdlib.h>
#include "ntstatus.h"
#include "wine/vulkan_driver.h"
#include "wine/gdi_driver.h"

static int allocation_failed, layer_failed, live_clients, live_leases, calls;
static VkResult surface_result;
static int fake_layer;

void *client_surface_create( UINT size, const struct client_surface_funcs *funcs, HWND hwnd )
{
    struct client_surface *client;
    if (allocation_failed) return NULL;
    client = calloc( 1, size );
    assert( client );
    client->funcs = funcs;
    client->hwnd = hwnd;
    live_clients++;
    return client;
}

void client_surface_release( struct client_surface *client )
{
    assert( client && live_clients > 0 );
    client->funcs->destroy( client );
    live_clients--;
    free( client );
}

void *madeira_vulkan_layer_lease_create( void *hwnd )
{
    assert( hwnd );
    if (layer_failed) return NULL;
    live_leases++;
    return &fake_layer;
}

void madeira_vulkan_layer_lease_release( void *lease )
{
    if (!lease) return;
    assert( lease == &fake_layer && live_leases > 0 );
    live_leases--;
}

static VkResult mock_create( VkInstance instance, const VkMetalSurfaceCreateInfoEXT *info,
                             const VkAllocationCallbacks *allocator, VkSurfaceKHR *surface )
{
    assert( instance && !allocator );
    assert( info->sType == VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT );
    assert( info->pLayer == &fake_layer && live_leases == 1 );
    calls++;
    *surface = (VkSurfaceKHR)0x1234;
    return surface_result;
}

/* Exported solely for the bridge's real dlsym checks. */
void vkGetInstanceProcAddr(void) { }
void vkGetDeviceProcAddr(void) { }

#include "../win32u-unix/moltenvk_ios.c"

int main(void)
{
    struct vulkan_instance instance = {0};
    struct vulkan_instance_extensions extensions = {0};
    struct client_surface *client = (void *)1;
    const struct vulkan_driver_funcs *driver = NULL;
    VkSurfaceKHR surface = (VkSurfaceKHR)1;
    void *self = dlopen( NULL, RTLD_NOW );
    void *missing = dlopen( "libc.so.6", RTLD_NOW );
    HWND hwnd = (HWND)0x100;

    assert( self && missing );
    assert( winios_VulkanInit( WINE_VULKAN_DRIVER_VERSION + 1, self, &driver ) == (UINT)STATUS_NOT_IMPLEMENTED );
    assert( winios_VulkanInit( WINE_VULKAN_DRIVER_VERSION, NULL, &driver ) == (UINT)STATUS_NOT_IMPLEMENTED );
    assert( winios_VulkanInit( WINE_VULKAN_DRIVER_VERSION, missing, &driver ) == (UINT)STATUS_NOT_IMPLEMENTED );
    assert( !driver );
    assert( winios_VulkanInit( WINE_VULKAN_DRIVER_VERSION, self, &driver ) == STATUS_SUCCESS );
    assert( driver == &winios_vk_driver_funcs );
    assert( winios_vk_surface_create( hwnd, &instance, &surface, &client ) == VK_ERROR_EXTENSION_NOT_PRESENT );
    assert( !client && !surface && !live_clients && !live_leases && !calls );

    instance.host.instance = (VkInstance)0x1;
    instance.p_vkCreateMetalSurfaceEXT = mock_create;
    allocation_failed = 1;
    assert( winios_vk_surface_create( hwnd, &instance, &surface, &client ) == VK_ERROR_OUT_OF_HOST_MEMORY );
    allocation_failed = 0;
    layer_failed = 1;
    assert( winios_vk_surface_create( hwnd, &instance, &surface, &client ) == VK_ERROR_SURFACE_LOST_KHR );
    assert( !client && !surface && !live_clients && !live_leases && !calls );
    layer_failed = 0;
    surface_result = VK_ERROR_INITIALIZATION_FAILED;
    assert( winios_vk_surface_create( hwnd, &instance, &surface, &client ) == surface_result );
    assert( !client && !surface && !live_clients && !live_leases && calls == 1 );

    surface_result = VK_SUCCESS;
    assert( winios_vk_surface_create( hwnd, &instance, &surface, &client ) == VK_SUCCESS );
    assert( client && surface && live_clients == 1 && live_leases == 1 && calls == 2 );
    client->funcs->detach( client );
    client->funcs->detach( client );
    client->funcs->update( client );
    client->funcs->present( client, NULL );
    assert( live_leases == 1 );
    client_surface_release( client );
    assert( !live_clients && !live_leases );

    winios_vk_map_instance_extensions( &extensions );
    assert( !extensions.has_VK_KHR_win32_surface && !extensions.has_VK_EXT_metal_surface );
    extensions.has_VK_KHR_win32_surface = 1;
    winios_vk_map_instance_extensions( &extensions );
    assert( extensions.has_VK_EXT_metal_surface );
    extensions.has_VK_KHR_win32_surface = 0;
    winios_vk_map_instance_extensions( &extensions );
    assert( extensions.has_VK_KHR_win32_surface );
    dlclose( self );
    dlclose( missing );
    return 0;
}
