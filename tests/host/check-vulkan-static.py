#!/usr/bin/env python3
"""Exercise the real static backend adapter with a simulated Vulkan driver.

This proves forwarding and failure propagation, never GPU/device availability.
VULKAN_INCLUDE points at the pinned MoltenVK package's include directory.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'build/vulkan-ios/backend.c'
assert source.is_file(), 'Static Vulkan backend adapter is not implemented'
headers = os.environ.get('VULKAN_INCLUDE', str(root / 'toolchains/moltenvk/MoltenVK/include'))
assert (Path(headers) / 'vulkan/vulkan.h').is_file(), \
    f'Vulkan headers missing at {headers}; run build/vulkan-ios/fetch.sh (or set VULKAN_INCLUDE)'
fixture = r'''
#include <vulkan/vulkan.h>
#include <assert.h>
#include <string.h>
extern void *madeira_vulkan_symbol(const char *name);
static unsigned creates, enumerates, submits, waits;
static int host_subset;
static VkResult wsi_result;
static const VkSwapchainCreateInfoKHR *expected_ci;
static const VkAcquireNextImageInfoKHR *expected_ai;
static const VkAllocationCallbacks *expected_allocator;
VKAPI_ATTR VkResult VKAPI_CALL vkCreateSwapchainKHR(VkDevice d,const VkSwapchainCreateInfoKHR *i,const VkAllocationCallbacks *a,VkSwapchainKHR *s)
{ assert(d==(VkDevice)0x42 && i==expected_ci && a==expected_allocator); *s=(VkSwapchainKHR)0x55; return wsi_result; }
VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImageKHR(VkDevice d,VkSwapchainKHR s,uint64_t t,VkSemaphore sem,VkFence f,uint32_t *idx)
{ assert(d==(VkDevice)0x42 && s==(VkSwapchainKHR)0x55 && t==123 && sem==(VkSemaphore)0x66 && f==(VkFence)0x77); *idx=2; return wsi_result; }
VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImage2KHR(VkDevice d,const VkAcquireNextImageInfoKHR *i,uint32_t *idx)
{ assert(d==(VkDevice)0x42 && i==expected_ai); *idx=3; return wsi_result; }

static void other(void) {}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateShaderModule(VkDevice d,const VkShaderModuleCreateInfo *i,const VkAllocationCallbacks *a,VkShaderModule *m){return VK_ERROR_INITIALIZATION_FAILED;}
VKAPI_ATTR void VKAPI_CALL vkDestroyShaderModule(VkDevice d,VkShaderModule m,const VkAllocationCallbacks *a){}
VKAPI_ATTR void VKAPI_CALL vkDestroyDevice(VkDevice d,const VkAllocationCallbacks *a){}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateGraphicsPipelines(VkDevice d,VkPipelineCache c,uint32_t n,const VkGraphicsPipelineCreateInfo *i,const VkAllocationCallbacks *a,VkPipeline *p){return VK_ERROR_INITIALIZATION_FAILED;}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *c, const VkAllocationCallbacks *a, VkInstance *i)
{ creates++; return VK_ERROR_INITIALIZATION_FAILED; }
VKAPI_ATTR VkResult VKAPI_CALL vkEnumeratePhysicalDevices(VkInstance i, uint32_t *n, VkPhysicalDevice *d)
{ enumerates++; *n=0; return VK_ERROR_DEVICE_LOST; }
VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice p, const VkDeviceCreateInfo *c, const VkAllocationCallbacks *a, VkDevice *d)
{ assert(c->enabledExtensionCount == (unsigned)host_subset);
  if (host_subset) assert(!strcmp(c->ppEnabledExtensionNames[0], "VK_KHR_portability_subset"));
  return VK_ERROR_FEATURE_NOT_PRESENT; }
VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(VkPhysicalDevice p, const char *l, uint32_t *n, VkExtensionProperties *e)
{ *n=host_subset; if (e && host_subset) strcpy(e[0].extensionName,"VK_KHR_portability_subset"); return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue q, const VkPresentInfoKHR *i)
{ return VK_ERROR_SURFACE_LOST_KHR; }
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *s, VkFence f)
{ submits++; return VK_ERROR_DEVICE_LOST; }
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d, uint32_t n, const VkFence *f, VkBool32 a, uint64_t t)
{ waits++; return VK_TIMEOUT; }
VKAPI_ATTR void VKAPI_CALL vkCmdClearColorImage(VkCommandBuffer b, VkImage i, VkImageLayout l, const VkClearColorValue *c, uint32_t n, const VkImageSubresourceRange *r) {}
VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceProperties(VkPhysicalDevice p, VkPhysicalDeviceProperties *r) {}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance i,const char *n)
{
    if (!strcmp(n,"vkCreateInstance")) return (PFN_vkVoidFunction)vkCreateInstance;
    if (!strcmp(n,"vkEnumeratePhysicalDevices")) return (PFN_vkVoidFunction)vkEnumeratePhysicalDevices;
    if (!strcmp(n,"vkCreateDevice")) return (PFN_vkVoidFunction)vkCreateDevice;
    if (!strcmp(n,"other")) return other;
    return 0;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice d,const char *n)
{
    if (!strcmp(n,"vkCreateShaderModule")) return (PFN_vkVoidFunction)vkCreateShaderModule;
    if (!strcmp(n,"vkDestroyShaderModule")) return (PFN_vkVoidFunction)vkDestroyShaderModule;
    if (!strcmp(n,"vkCreateGraphicsPipelines")) return (PFN_vkVoidFunction)vkCreateGraphicsPipelines;
    if (!strcmp(n,"vkDestroyDevice")) return (PFN_vkVoidFunction)vkDestroyDevice;
    if (!strcmp(n,"vkQueuePresentKHR")) return (PFN_vkVoidFunction)vkQueuePresentKHR;
    if (!strcmp(n,"vkCreateSwapchainKHR")) return (PFN_vkVoidFunction)vkCreateSwapchainKHR;
    if (!strcmp(n,"vkAcquireNextImageKHR")) return (PFN_vkVoidFunction)vkAcquireNextImageKHR;
    if (!strcmp(n,"vkAcquireNextImage2KHR")) return (PFN_vkVoidFunction)vkAcquireNextImage2KHR;

    if (!strcmp(n,"vkQueueSubmit")) return (PFN_vkVoidFunction)vkQueueSubmit;
    if (!strcmp(n,"vkWaitForFences")) return (PFN_vkVoidFunction)vkWaitForFences;
    if (!strcmp(n,"other")) return other;
    return 0;
}
int main(void)
{
    PFN_vkGetInstanceProcAddr gi=(PFN_vkGetInstanceProcAddr)madeira_vulkan_symbol("vkGetInstanceProcAddr");
    PFN_vkGetDeviceProcAddr gd=(PFN_vkGetDeviceProcAddr)madeira_vulkan_symbol("vkGetDeviceProcAddr");
    assert(gi && gd && !madeira_vulkan_symbol("unknown"));
    assert(!gi(0,"missing") && gi(0,"other")==other);
    assert(!gd(0,"missing") && gd(0,"other")==other);
    PFN_vkCreateShaderModule sm=(PFN_vkCreateShaderModule)gd(0,"vkCreateShaderModule");
    PFN_vkCreateGraphicsPipelines gp=(PFN_vkCreateGraphicsPipelines)gd(0,"vkCreateGraphicsPipelines");
    assert(sm && sm==vkCreateShaderModule && sm(0,0,0,0)==VK_ERROR_INITIALIZATION_FAILED);
    assert(gp && gp==vkCreateGraphicsPipelines && gp(0,0,0,0,0,0)==VK_ERROR_INITIALIZATION_FAILED);
    ((PFN_vkDestroyShaderModule)gd(0,"vkDestroyShaderModule"))(0,0,0);
    ((PFN_vkDestroyDevice)gd(0,"vkDestroyDevice"))(0,0);

    VkInstanceCreateInfo c={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; VkInstance i=0;
    assert(((PFN_vkCreateInstance)gi(0,"vkCreateInstance"))(&c,0,&i)==VK_ERROR_INITIALIZATION_FAILED);
    uint32_t n=7;
    assert(((PFN_vkEnumeratePhysicalDevices)gi(i,"vkEnumeratePhysicalDevices"))(i,&n,0)==VK_ERROR_DEVICE_LOST);
    assert(!n && creates==1 && enumerates==1);
    assert(((PFN_vkQueueSubmit)gd(0,"vkQueueSubmit"))(0,0,0,0)==VK_ERROR_DEVICE_LOST);
    assert(((PFN_vkWaitForFences)gd(0,"vkWaitForFences"))(0,0,0,0,0)==VK_TIMEOUT);
    assert(submits==1 && waits==1);

    VkSwapchainCreateInfoKHR sci={.sType=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,.imageExtent={2560,1440}};
    VkAcquireNextImageInfoKHR aci={.sType=VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR};
    VkAllocationCallbacks alloc={0};expected_ci=&sci;expected_ai=&aci;expected_allocator=&alloc;
    VkResult results[]={VK_SUCCESS,VK_SUBOPTIMAL_KHR,VK_ERROR_OUT_OF_DATE_KHR,VK_TIMEOUT};
    for(unsigned r=0;r<sizeof(results)/sizeof(results[0]);r++) {
        wsi_result=results[r];VkSwapchainKHR sc=0;uint32_t index=0;
        assert(((PFN_vkCreateSwapchainKHR)gd(0,"vkCreateSwapchainKHR"))((VkDevice)0x42,&sci,&alloc,&sc)==wsi_result && sc==(VkSwapchainKHR)0x55);
        assert(((PFN_vkAcquireNextImageKHR)gd(0,"vkAcquireNextImageKHR"))((VkDevice)0x42,sc,123,(VkSemaphore)0x66,(VkFence)0x77,&index)==wsi_result && index==2);
        assert(((PFN_vkAcquireNextImage2KHR)gd(0,"vkAcquireNextImage2KHR"))((VkDevice)0x42,&aci,&index)==wsi_result && index==3);
    }
    VkPresentInfoKHR pi={.sType=VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    assert(((PFN_vkQueuePresentKHR)gd(0,"vkQueuePresentKHR"))(0,&pi)==VK_ERROR_SURFACE_LOST_KHR);
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; VkDevice dev=0;
    PFN_vkCreateDevice cd=(PFN_vkCreateDevice)gi(0,"vkCreateDevice");
    assert(cd(0,&di,0,&dev)==VK_ERROR_FEATURE_NOT_PRESENT);
    host_subset=1;
    assert(cd(0,&di,0,&dev)==VK_ERROR_FEATURE_NOT_PRESENT);
    const char *ext="VK_KHR_portability_subset";
    di.enabledExtensionCount=1; di.ppEnabledExtensionNames=&ext;
    assert(cd(0,&di,0,&dev)==VK_ERROR_FEATURE_NOT_PRESENT);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    c=Path(tmp)/'test.c'; exe=Path(tmp)/'test'; c.write_text(fixture)
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-I'+headers,str(source),str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
print('PASS: backend forwards calls/errors and preserves missing entry points (not a GPU test)')
