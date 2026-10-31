/* Native MoltenVK surface geometry regression; not iPad/FEX proof.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#define VK_USE_PLATFORM_METAL_EXT
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../app/Madeira/Winios/VulkanLayerGeometry.h"
#define CHECK(e) do { VkResult r=(e); if(r!=VK_SUCCESS){fprintf(stderr,"FAIL %s = %d\n",#e,r);exit(2);} }while(0)
int main(void){ @autoreleasepool {
 const char *ie[]={"VK_KHR_surface","VK_EXT_metal_surface"};
 VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};
 VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai,.enabledExtensionCount=2,.ppEnabledExtensionNames=ie};
 VkInstance inst;CHECK(vkCreateInstance(&ici,0,&inst));
 uint32_t count=1;VkPhysicalDevice gpu;CHECK(vkEnumeratePhysicalDevices(inst,&count,&gpu));
 VkPhysicalDeviceProperties prop;vkGetPhysicalDeviceProperties(gpu,&prop);printf("GPU=%s\n",prop.deviceName);
 VkQueueFamilyProperties qp[32];count=32;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,qp);uint32_t family=0;while(family<count && !(qp[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))family++;if(family==count)return 2;
 float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
 const char *de[]={"VK_KHR_swapchain","VK_KHR_portability_subset"};
 VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=2,.ppEnabledExtensionNames=de};
 VkDevice dev;CHECK(vkCreateDevice(gpu,&di,0,&dev));
 for(int fixed=0;fixed<3;fixed++){
 CAMetalLayer *layer=[CAMetalLayer layer];layer.device=MTLCreateSystemDefaultDevice();layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.anchorPoint=CGPointZero;layer.contentsScale=1;
 layer.frame=CGRectMake(10,20,320,180);
 if(fixed){
#ifndef MADEIRA_TEST_LEGACY
 if(!madeira_vulkan_layer_geometry(layer,CGRectMake(10,20,320,180),CGSizeMake(640,360)))return 4;
#endif
 }
 if(fabs(layer.frame.origin.x-10)>.001 || fabs(layer.frame.origin.y-20)>.001 ||
    fabs(layer.frame.size.width-320)>.001 || fabs(layer.frame.size.height-180)>.001)return 5;
 layer.drawableSize=CGSizeMake(640,360);
 VkMetalSurfaceCreateInfoEXT si={.sType=VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,.pLayer=layer};VkSurfaceKHR surf;CHECK(vkCreateMetalSurfaceEXT(inst,&si,0,&surf));
 VkBool32 supports;CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(gpu,family,surf,&supports));if(!supports)return 2;
 VkSurfaceCapabilitiesKHR caps;CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu,surf,&caps));
 count=0;CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu,surf,&count,0));VkSurfaceFormatKHR *fmt=calloc(count,sizeof(*fmt));CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu,surf,&count,fmt));uint32_t f=0;for(uint32_t i=0;i<count;i++)if(fmt[i].format==VK_FORMAT_B8G8R8A8_UNORM){f=i;break;}
 VkSwapchainCreateInfoKHR ci={.sType=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,.surface=surf,.minImageCount=caps.minImageCount,.imageFormat=fmt[f].format,.imageColorSpace=fmt[f].colorSpace,.imageExtent={640,360},.imageArrayLayers=1,.imageUsage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,.imageSharingMode=VK_SHARING_MODE_EXCLUSIVE,.preTransform=caps.currentTransform,.compositeAlpha=VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,.presentMode=VK_PRESENT_MODE_FIFO_KHR,.clipped=VK_TRUE};
 VkSwapchainKHR sc;CHECK(vkCreateSwapchainKHR(dev,&ci,0,&sc));
 /* Real resize must still signal SUBOPTIMAL; no result rewriting. */
 if(fixed==2 && !madeira_vulkan_layer_geometry(layer,CGRectMake(10,20,400,225),CGSizeMake(800,450)))return 6;
 VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence fence;CHECK(vkCreateFence(dev,&fi,0,&fence));uint32_t index=~0u;VkResult r=vkAcquireNextImageKHR(dev,sc,UINT64_MAX,0,fence,&index);
 printf("fixed=%d frame=%.0fx%.0f bounds=%.0fx%.0f drawable=%.0fx%.0f caps=%ux%u acquire=%d index=%u\n",fixed,layer.frame.size.width,layer.frame.size.height,layer.bounds.size.width,layer.bounds.size.height,layer.drawableSize.width,layer.drawableSize.height,caps.currentExtent.width,caps.currentExtent.height,r,index);fflush(stdout);
 if(r==VK_SUCCESS||r==VK_SUBOPTIMAL_KHR)CHECK(vkWaitForFences(dev,1,&fence,VK_TRUE,UINT64_MAX));
 vkDestroyFence(dev,fence,0);vkDestroySwapchainKHR(dev,sc,0);vkDestroySurfaceKHR(inst,surf,0);free(fmt);
 if(r!=(fixed==1?VK_SUCCESS:VK_SUBOPTIMAL_KHR))return 3;
 }
 vkDestroyDevice(dev,0);vkDestroyInstance(inst,0);puts("PASS native acquisition: corrected logical bounds gives SUCCESS; genuine resize remains SUBOPTIMAL");
 }return 0;}
