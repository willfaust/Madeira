#!/usr/bin/env python3
"""Run real iOS Vulkan surface adapter against an external-API fixture.
Catches headless fallback, Metal/Win32 extension leakage, retained-layer leaks,
wrong VkInstance/HWND and invented presentation support. Includes PR #88's
failure-output and repeated-detach checks. Not a UIKit/GPU test.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=root/'build/win32u-unix/vulkan_surface_ios.c'
assert source.exists(), 'iOS Metal surface adapter missing: Wine still uses headless fallback'
pre=r'''
#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winuser.h"
#include "wine/gdi_driver.h"
#include "wine/vulkan_driver.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static int retain_count, released, created, destroyed, missing_layer, allocation_fails;
static VkResult surface_result=VK_SUCCESS, support_result=VK_SUCCESS;
static VkBool32 host_support=VK_FALSE;
static void *layer=(void *)0x1234;
void *madeira_vulkan_layer_acquire(void *hwnd) {
    assert(hwnd==(void *)0x42 || !hwnd);
    if(missing_layer)return NULL;
    retain_count++;return layer;
}
void madeira_vulkan_layer_release(void *p) { assert(p==layer);released++; }
void *client_surface_create(const struct client_surface_funcs *funcs,HWND hwnd,int format,BOOL raw) {
    if(allocation_fails)return NULL;
    struct client_surface *s=calloc(1,funcs->size);s->funcs=funcs;s->hwnd=hwnd;return s;
}
void client_surface_release(struct client_surface *s) { s->funcs->destroy(s);free(s); }
static VkResult VKAPI_CALL metal(VkInstance i,const VkMetalSurfaceCreateInfoEXT *c,const VkAllocationCallbacks *a,VkSurfaceKHR *out) {
    assert(i==(VkInstance)0x11 && !a && c->pLayer==layer && !c->pNext && !c->flags);
    assert(c->sType==VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT);created++;
    *out=(VkSurfaceKHR)0x99;
    return surface_result;
}
static void VKAPI_CALL destroy(VkInstance i,VkSurfaceKHR s,const VkAllocationCallbacks *a) {
    assert(i==(VkInstance)0x11 && s==(VkSurfaceKHR)0x99 && !a);destroyed++;
}
static VkResult VKAPI_CALL support(VkPhysicalDevice p,uint32_t q,VkSurfaceKHR s,VkBool32 *out) {
    assert(p==(VkPhysicalDevice)0x22 && q==3 && s==(VkSurfaceKHR)0x99);*out=host_support;return support_result;
}
'''
driver=(root/'build/win32u-unix/driver_ios.c').read_text()
a=driver.index('static UINT nulldrv_VulkanInit(');b=driver.index('\n}',a)+2
binding=driver[a:b]
main=r'''
int main(void) {
 const struct vulkan_driver_funcs *f=(void *)1;
 assert(nulldrv_VulkanInit(WINE_VULKAN_DRIVER_VERSION+1,NULL,&f)==STATUS_INVALID_PARAMETER && !f);
 assert(!nulldrv_VulkanInit(WINE_VULKAN_DRIVER_VERSION,NULL,&f) && f);
 struct vulkan_instance_extensions e={0};f->p_map_instance_extensions(&e);assert(!e.has_VK_KHR_win32_surface);
 e.has_VK_EXT_metal_surface=1;f->p_map_instance_extensions(&e);assert(e.has_VK_KHR_win32_surface);
 e=(struct vulkan_instance_extensions){.has_VK_KHR_win32_surface=1};f->p_map_instance_extensions(&e);
 assert(e.has_VK_EXT_metal_surface && !e.has_VK_EXT_headless_surface);
 struct vulkan_instance instance={0};instance.host.instance=(VkInstance)0x11;
 instance.p_vkCreateMetalSurfaceEXT=metal;instance.p_vkDestroySurfaceKHR=destroy;
 instance.p_vkGetPhysicalDeviceSurfaceSupportKHR=support;
 allocation_fails=1;assert(!winios_vulkan_client_surface_create((HWND)0x42,0,FALSE));
 allocation_fails=0;
 struct client_surface *client=winios_vulkan_client_surface_create((HWND)0x42,0,FALSE);
 assert(client);VkSurfaceKHR s=(VkSurfaceKHR)1;
 missing_layer=1;assert(f->p_vulkan_surface_create(client,&instance,&s)==VK_ERROR_SURFACE_LOST_KHR && !s);
 assert(!retain_count && !released);
 missing_layer=0;surface_result=VK_ERROR_NATIVE_WINDOW_IN_USE_KHR;s=(VkSurfaceKHR)1;
 assert(f->p_vulkan_surface_create(client,&instance,&s)==VK_ERROR_NATIVE_WINDOW_IN_USE_KHR && !s);
 assert(retain_count==released);
 surface_result=VK_SUCCESS;
 assert(f->p_vulkan_surface_create(client,&instance,&s)==VK_SUCCESS && s==(VkSurfaceKHR)0x99);
 assert(retain_count==released+1);client->funcs->detach(client);client->funcs->detach(client);
 client->funcs->update(client);client->funcs->present(client,NULL);
 assert(retain_count==released+1);
 client_surface_release(client);assert(retain_count==released);
 struct vulkan_physical_device physical={0};physical.instance=&instance;physical.host.physical_device=(VkPhysicalDevice)0x22;
 assert(!f->p_get_physical_device_presentation_support(&physical,3));
 host_support=VK_TRUE;assert(f->p_get_physical_device_presentation_support(&physical,3));
 support_result=VK_ERROR_SURFACE_LOST_KHR;assert(!f->p_get_physical_device_presentation_support(&physical,3));
 assert(destroyed==3 && retain_count==released);
 client=winios_vulkan_client_surface_create((HWND)0x42,0,FALSE);
 instance.p_vkCreateMetalSurfaceEXT=NULL;s=(VkSurfaceKHR)1;
 assert(f->p_vulkan_surface_create(client,&instance,&s)==VK_ERROR_EXTENSION_NOT_PRESENT && !s);
 instance.p_vkCreateMetalSurfaceEXT=metal;instance.host.instance=VK_NULL_HANDLE;
 s=(VkSurfaceKHR)1;
 assert(f->p_vulkan_surface_create(client,&instance,&s)==VK_ERROR_EXTENSION_NOT_PRESENT && !s);
 instance.p_vkCreateMetalSurfaceEXT=NULL;
 assert(!f->p_get_physical_device_presentation_support(&physical,3));
 client_surface_release(client);assert(retain_count==released);
 puts("PASS: real surface adapter maps Metal extensions, propagates failures, balances retains and queries native presentation support (not GPU proof)");
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t)/'test.c';p.write_text(pre+'\n#include "'+str(source)+'"\n'+binding+'\n'+main)
 exe=Path(t)/'test'
 subprocess.run(['cc','-std=gnu11','-Werror=implicit-function-declaration','-fsanitize=address,undefined','-DWINE_UNIX_LIB','-D__WINESRC__','-DMADEIRA_MOLTENVK=1','-I'+str(root/'wine/include'),str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
