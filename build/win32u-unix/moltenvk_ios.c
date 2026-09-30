/* iOS Vulkan WSI, adapted from Madeira's retained MoltenVK bridge.
 * SPDX-License-Identifier: GPL-3.0-or-later
 * With the additional permission in LICENSE-EXCEPTION.md.
 * Included by driver_ios.c only for a MoltenVK-enabled build.
 * Keep Wine's current driver ABI; no private Wine or MoltenVK extensions.
 */
#include <dlfcn.h>

extern void *madeira_vulkan_layer_lease_create( void *hwnd );
extern void madeira_vulkan_layer_lease_release( void *lease );

struct winios_vk_surface
{
    struct client_surface client;
    void *lease;
};

static void winios_vk_surface_destroy( struct client_surface *client )
{
    struct winios_vk_surface *surface = CONTAINING_RECORD( client, struct winios_vk_surface, client );
    madeira_vulkan_layer_lease_release( surface->lease );
}

/* Wine detaches the client from its HWND. Keep the retained layer alive until
 * the Vulkan surface is destroyed; it must not become a dangling Metal object. */
static void winios_vk_surface_noop( struct client_surface *client ) { (void)client; }
static void winios_vk_surface_present( struct client_surface *client, HDC hdc )
{
    (void)client;
    (void)hdc;
}

static const struct client_surface_funcs winios_vk_surface_funcs =
{
    .destroy = winios_vk_surface_destroy,
    .detach = winios_vk_surface_noop,
    .update = winios_vk_surface_noop,
    .present = winios_vk_surface_present,
};

static VkResult winios_vk_surface_create( HWND hwnd, const struct vulkan_instance *instance,
                                         VkSurfaceKHR *handle, struct client_surface **client )
{
    struct winios_vk_surface *surface;
    VkMetalSurfaceCreateInfoEXT info = {.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
    VkResult result;

    *client = NULL;
    *handle = VK_NULL_HANDLE;
    if (!instance->p_vkCreateMetalSurfaceEXT) return VK_ERROR_EXTENSION_NOT_PRESENT;
    if (!(surface = client_surface_create( sizeof(*surface), &winios_vk_surface_funcs, hwnd )))
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    surface->lease = madeira_vulkan_layer_lease_create( hwnd );
    if (!surface->lease)
    {
        client_surface_release( &surface->client );
        return VK_ERROR_SURFACE_LOST_KHR;
    }
    info.pLayer = surface->lease;
    result = instance->p_vkCreateMetalSurfaceEXT( instance->host.instance, &info, NULL, handle );
    if (result)
    {
        client_surface_release( &surface->client );
        *handle = VK_NULL_HANDLE;
        return result;
    }
    *client = &surface->client;
    return VK_SUCCESS;
}

static VkBool32 winios_vk_presentation_support( struct vulkan_physical_device *physical_device,
                                              uint32_t queue )
{
    (void)physical_device;
    (void)queue;
    return VK_TRUE;
}

static void winios_vk_map_instance_extensions( struct vulkan_instance_extensions *extensions )
{
    if (extensions->has_VK_KHR_win32_surface) extensions->has_VK_EXT_metal_surface = 1;
    if (extensions->has_VK_EXT_metal_surface) extensions->has_VK_KHR_win32_surface = 1;
}

static void winios_vk_map_device_extensions( struct vulkan_device_extensions *extensions )
{
    (void)extensions;
}

static const struct vulkan_driver_funcs winios_vk_driver_funcs =
{
    .p_vulkan_surface_create = winios_vk_surface_create,
    .p_get_physical_device_presentation_support = winios_vk_presentation_support,
    .p_map_instance_extensions = winios_vk_map_instance_extensions,
    .p_map_device_extensions = winios_vk_map_device_extensions,
};

static UINT winios_VulkanInit( UINT version, void *vulkan_handle,
                              const struct vulkan_driver_funcs **driver_funcs )
{
    /* Returning NOT_IMPLEMENTED is required on failure: Wine replaces its
     * lazy driver then, avoiding recursion through the lazy trampoline. */
    if (version != WINE_VULKAN_DRIVER_VERSION || !vulkan_handle ||
        !dlsym( vulkan_handle, "vkGetInstanceProcAddr" ) ||
        !dlsym( vulkan_handle, "vkGetDeviceProcAddr" ))
        return STATUS_NOT_IMPLEMENTED;
    *driver_funcs = &winios_vk_driver_funcs;
    return STATUS_SUCCESS;
}
