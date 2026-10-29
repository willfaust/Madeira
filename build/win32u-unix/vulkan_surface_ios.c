/* iOS user-driver Vulkan surface adapter, included by vulkan_ios.c.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * Wine owns VkSurfaceKHR and client_surface references; the bridge retains
 * the existing compositor's CAMetalLayer until that client is destroyed.
 */
extern void *madeira_vulkan_layer_acquire(void *hwnd);
extern void madeira_vulkan_layer_release(void *layer);

struct ios_vulkan_client_surface
{
    struct client_surface client;
    void *layer;
};

static void ios_vulkan_surface_destroy(struct client_surface *client)
{
    struct ios_vulkan_client_surface *surface = (void *)client;
    if (surface->layer) madeira_vulkan_layer_release(surface->layer);
}

static void ios_vulkan_surface_detach(struct client_surface *client)
{
    /* Winios owns the window/layer tree and removes it on HWND destruction.
     * Keep our retain until Wine destroys the native surface, including when
     * a window is destroyed before its Vulkan swapchain/surface. */
    (void)client;
}

static void ios_vulkan_surface_update(struct client_surface *client)
{
    /* Existing Winios WindowPosChanged / MetalHostView layout update the
     * desktop per-window / fullscreen layer geometry on the main queue. */
    (void)client;
}

static void ios_vulkan_surface_present(struct client_surface *client, HDC hdc)
{
    /* MoltenVK presents to the native layer; no CPU/GDI copy or fake present. */
    (void)client;
    (void)hdc;
}

static const struct client_surface_funcs ios_vulkan_client_funcs =
{
    .size = sizeof(struct ios_vulkan_client_surface),
    .destroy = ios_vulkan_surface_destroy,
    .detach = ios_vulkan_surface_detach,
    .update = ios_vulkan_surface_update,
    .present = ios_vulkan_surface_present,
};

struct client_surface *winios_vulkan_client_surface_create( HWND hwnd, int format, BOOL raw )
{
    return client_surface_create( &ios_vulkan_client_funcs, hwnd, format, raw );
}

static VkResult ios_vulkan_surface_create( struct client_surface *client,
        const struct vulkan_instance *instance, VkSurfaceKHR *handle )
{
    struct ios_vulkan_client_surface *surface;
    VkResult result;
    VkMetalSurfaceCreateInfoEXT info = {.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};

    *handle = VK_NULL_HANDLE;
    if (client->funcs != &ios_vulkan_client_funcs) return VK_ERROR_SURFACE_LOST_KHR;
    if (!instance->host.instance || !instance->p_vkCreateMetalSurfaceEXT) return VK_ERROR_EXTENSION_NOT_PRESENT;
    surface = CONTAINING_RECORD( client, struct ios_vulkan_client_surface, client );
    if (!surface->layer) surface->layer = madeira_vulkan_layer_acquire( client->hwnd );
    if (!surface->layer) return VK_ERROR_SURFACE_LOST_KHR;
    info.pLayer = surface->layer;
    result = instance->p_vkCreateMetalSurfaceEXT( instance->host.instance, &info, NULL, handle );
    fprintf( stderr, "[vk-surface] HWND=%p layer=%p -> vkCreateMetalSurfaceEXT result=%d\n",
             client->hwnd, surface->layer, result );
    if (result != VK_SUCCESS)
    {
        *handle = VK_NULL_HANDLE;
        madeira_vulkan_layer_release( surface->layer );
        surface->layer = NULL;
    }
    return result;
}

static VkBool32 ios_vulkan_presentation_support(struct vulkan_physical_device *physical, uint32_t queue)
{
    struct vulkan_instance *instance = physical->instance;
    VkSurfaceKHR surface;
    VkBool32 supported = VK_FALSE;
    VkResult result;
    void *layer;
    if (!instance->p_vkCreateMetalSurfaceEXT || !instance->p_vkGetPhysicalDeviceSurfaceSupportKHR ||
        !instance->p_vkDestroySurfaceKHR) return VK_FALSE;
    if (!(layer = madeira_vulkan_layer_acquire(NULL))) return VK_FALSE;
    VkMetalSurfaceCreateInfoEXT info = {.sType=VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, .pLayer=layer};
    result = instance->p_vkCreateMetalSurfaceEXT(instance->host.instance, &info, NULL, &surface);
    if (result == VK_SUCCESS)
    {
        result = instance->p_vkGetPhysicalDeviceSurfaceSupportKHR(physical->host.physical_device, queue, surface, &supported);
        instance->p_vkDestroySurfaceKHR(instance->host.instance, surface, NULL);
    }
    madeira_vulkan_layer_release(layer);
    return result == VK_SUCCESS ? supported : VK_FALSE;
}

static void ios_vulkan_map_instance_extensions(struct vulkan_instance_extensions *extensions)
{
    /* Same bidirectional native/client mapping as Wine's macOS Metal driver.
     * Only a real advertised Metal surface exposes Win32 surface support. */
    if (extensions->has_VK_EXT_metal_surface) extensions->has_VK_KHR_win32_surface = 1;
    if (extensions->has_VK_KHR_win32_surface) extensions->has_VK_EXT_metal_surface = 1;
}

static void ios_vulkan_map_device_extensions(struct vulkan_device_extensions *extensions)
{
    (void)extensions;
}

static const struct vulkan_driver_funcs ios_vulkan_driver_funcs =
{
    .p_vulkan_surface_create = ios_vulkan_surface_create,
    .p_get_physical_device_presentation_support = ios_vulkan_presentation_support,
    .p_map_instance_extensions = ios_vulkan_map_instance_extensions,
    .p_map_device_extensions = ios_vulkan_map_device_extensions,
};

UINT madeira_ios_VulkanInit(UINT version, void *handle, const struct vulkan_driver_funcs **funcs)
{
    (void)handle;
    *funcs = NULL;
    if (version != WINE_VULKAN_DRIVER_VERSION) return STATUS_INVALID_PARAMETER;
    *funcs = &ios_vulkan_driver_funcs;
    fprintf(stderr, "[vk-surface] iOS Metal window surface driver selected ABI=%u\n", version);
    return STATUS_SUCCESS;
}
