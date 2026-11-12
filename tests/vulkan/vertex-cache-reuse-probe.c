/* MoltenVK cache-reuse implementation regression (not Vulkan conformance). SPDX-License-Identifier: MIT
 * Intentionally submits two layouts missing the shader's location 3 to exercise
 * native error handling; these primer calls violate VUID-Input-07904 without
 * maintenance9/vertexAttributeRobustness. Their success is NOT required.
 * Checks subsequent correctly specified pipeline creation against a clean-cache
 * control. No game data, native Metal calls or capability overrides.
 */
#ifdef _WIN32
#define VK_NO_PROTOTYPES
#include <windows.h>
#endif
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
static PFN_vkCreateInstance vkCreateInstance;
static PFN_vkDestroyInstance vkDestroyInstance;
static PFN_vkEnumeratePhysicalDevices vkEnumeratePhysicalDevices;
static PFN_vkGetPhysicalDeviceProperties vkGetPhysicalDeviceProperties;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties vkGetPhysicalDeviceQueueFamilyProperties;
static PFN_vkEnumerateDeviceExtensionProperties vkEnumerateDeviceExtensionProperties;
static PFN_vkCreateDevice vkCreateDevice;
static PFN_vkDestroyDevice vkDestroyDevice;
static PFN_vkCreatePipelineLayout vkCreatePipelineLayout;
static PFN_vkDestroyPipelineLayout vkDestroyPipelineLayout;
static PFN_vkCreateRenderPass vkCreateRenderPass;
static PFN_vkDestroyRenderPass vkDestroyRenderPass;
static PFN_vkCreateShaderModule vkCreateShaderModule;
static PFN_vkDestroyShaderModule vkDestroyShaderModule;
static PFN_vkCreatePipelineCache vkCreatePipelineCache;
static PFN_vkDestroyPipelineCache vkDestroyPipelineCache;
static PFN_vkCreateGraphicsPipelines vkCreateGraphicsPipelines;
static PFN_vkDestroyPipeline vkDestroyPipeline;
static PFN_vkGetPipelineCacheData vkGetPipelineCacheData;
#endif
#define CHECK(expr) do{VkResult r=(expr);if(r!=VK_SUCCESS){fprintf(stderr,"FAIL %s = %d\n",#expr,r);exit(2);}}while(0)
static const uint32_t vs[]={0x07230203,0x00010000,0,13,0,
 (2<<16)|17,1, (3<<16)|14,0,1,
 (7<<16)|15,0,10,0x6e69616d,0,7,8,
 (4<<16)|71,7,30,3, (4<<16)|71,8,11,0,
 (2<<16)|19,1, (3<<16)|22,2,32, (4<<16)|23,3,2,4,
 (4<<16)|32,4,1,3, (4<<16)|32,5,3,3, (3<<16)|33,6,1,
 (4<<16)|59,4,7,1, (4<<16)|59,5,8,3,
 (5<<16)|54,1,10,0,6, (2<<16)|248,11,
 (4<<16)|61,3,12,7, (3<<16)|62,8,12, (1<<16)|253, (1<<16)|56};
static VkDevice device;
static VkPipelineLayout layout;
static VkRenderPass pass;
static VkShaderModule shader;
static VkResult attempt(VkPipelineCache cache,unsigned location,int attributes,const char *name){
 VkVertexInputBindingDescription binding={0,16,VK_VERTEX_INPUT_RATE_VERTEX};
 VkVertexInputAttributeDescription attr[2]={{location,0,VK_FORMAT_R32G32B32A32_SFLOAT,0},{0,0,VK_FORMAT_R32G32B32A32_SFLOAT,0}};
 VkPipelineVertexInputStateCreateInfo vi={.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
 .vertexBindingDescriptionCount=attributes ? 1 : 0,.pVertexBindingDescriptions=&binding,
 .vertexAttributeDescriptionCount=attributes,.pVertexAttributeDescriptions=attr};
 VkPipelineShaderStageCreateInfo stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_VERTEX_BIT,.module=shader,.pName="main"};
 VkPipelineInputAssemblyStateCreateInfo ia={.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
 VkViewport vp={0,0,16,16,0,1};VkRect2D sc={{0,0},{16,16}};
 VkPipelineViewportStateCreateInfo viewport={.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,.viewportCount=1,.pViewports=&vp,.scissorCount=1,.pScissors=&sc};
 VkPipelineRasterizationStateCreateInfo raster={.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,.polygonMode=VK_POLYGON_MODE_FILL,.lineWidth=1};
 VkPipelineMultisampleStateCreateInfo ms={.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT};
 VkPipelineColorBlendAttachmentState attachment={.colorWriteMask=15};
 VkPipelineColorBlendStateCreateInfo blend={.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,.attachmentCount=1,.pAttachments=&attachment};
 VkGraphicsPipelineCreateInfo info={.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,.stageCount=1,.pStages=&stage,
 .pVertexInputState=&vi,.pInputAssemblyState=&ia,.pViewportState=&viewport,.pRasterizationState=&raster,.pMultisampleState=&ms,.pColorBlendState=&blend,.layout=layout,.renderPass=pass};
 VkPipeline pipeline=VK_NULL_HANDLE;VkResult r=vkCreateGraphicsPipelines(device,cache,1,&info,NULL,&pipeline);
 printf("%s location=%u attributes=%d result=%d pipeline=%p\n",name,location,attributes,r,(void*)pipeline);fflush(stdout);
 if(pipeline)vkDestroyPipeline(device,pipeline,NULL);return r;
}
int main(void){
#ifdef _WIN32
 HMODULE module=LoadLibraryA("vulkan-1.dll");if(!module){puts("FAIL vulkan-1.dll missing");return 2;}
 vkGetPipelineCacheData=(PFN_vkGetPipelineCacheData)GetProcAddress(module,"vkGetPipelineCacheData");if(!vkGetPipelineCacheData)return 2;
 vkCreateInstance=(PFN_vkCreateInstance)GetProcAddress(module,"vkCreateInstance");if(!vkCreateInstance){puts("FAIL vkCreateInstance missing");return 2;}
 vkDestroyInstance=(PFN_vkDestroyInstance)GetProcAddress(module,"vkDestroyInstance");if(!vkDestroyInstance){puts("FAIL vkDestroyInstance missing");return 2;}
 vkEnumeratePhysicalDevices=(PFN_vkEnumeratePhysicalDevices)GetProcAddress(module,"vkEnumeratePhysicalDevices");if(!vkEnumeratePhysicalDevices){puts("FAIL vkEnumeratePhysicalDevices missing");return 2;}
 vkGetPhysicalDeviceProperties=(PFN_vkGetPhysicalDeviceProperties)GetProcAddress(module,"vkGetPhysicalDeviceProperties");if(!vkGetPhysicalDeviceProperties){puts("FAIL vkGetPhysicalDeviceProperties missing");return 2;}
 vkGetPhysicalDeviceQueueFamilyProperties=(PFN_vkGetPhysicalDeviceQueueFamilyProperties)GetProcAddress(module,"vkGetPhysicalDeviceQueueFamilyProperties");if(!vkGetPhysicalDeviceQueueFamilyProperties){puts("FAIL vkGetPhysicalDeviceQueueFamilyProperties missing");return 2;}
 vkEnumerateDeviceExtensionProperties=(PFN_vkEnumerateDeviceExtensionProperties)GetProcAddress(module,"vkEnumerateDeviceExtensionProperties");if(!vkEnumerateDeviceExtensionProperties){puts("FAIL vkEnumerateDeviceExtensionProperties missing");return 2;}
 vkCreateDevice=(PFN_vkCreateDevice)GetProcAddress(module,"vkCreateDevice");if(!vkCreateDevice){puts("FAIL vkCreateDevice missing");return 2;}
 vkDestroyDevice=(PFN_vkDestroyDevice)GetProcAddress(module,"vkDestroyDevice");if(!vkDestroyDevice){puts("FAIL vkDestroyDevice missing");return 2;}
 vkCreatePipelineLayout=(PFN_vkCreatePipelineLayout)GetProcAddress(module,"vkCreatePipelineLayout");if(!vkCreatePipelineLayout){puts("FAIL vkCreatePipelineLayout missing");return 2;}
 vkDestroyPipelineLayout=(PFN_vkDestroyPipelineLayout)GetProcAddress(module,"vkDestroyPipelineLayout");if(!vkDestroyPipelineLayout){puts("FAIL vkDestroyPipelineLayout missing");return 2;}
 vkCreateRenderPass=(PFN_vkCreateRenderPass)GetProcAddress(module,"vkCreateRenderPass");if(!vkCreateRenderPass){puts("FAIL vkCreateRenderPass missing");return 2;}
 vkDestroyRenderPass=(PFN_vkDestroyRenderPass)GetProcAddress(module,"vkDestroyRenderPass");if(!vkDestroyRenderPass){puts("FAIL vkDestroyRenderPass missing");return 2;}
 vkCreateShaderModule=(PFN_vkCreateShaderModule)GetProcAddress(module,"vkCreateShaderModule");if(!vkCreateShaderModule){puts("FAIL vkCreateShaderModule missing");return 2;}
 vkDestroyShaderModule=(PFN_vkDestroyShaderModule)GetProcAddress(module,"vkDestroyShaderModule");if(!vkDestroyShaderModule){puts("FAIL vkDestroyShaderModule missing");return 2;}
 vkCreatePipelineCache=(PFN_vkCreatePipelineCache)GetProcAddress(module,"vkCreatePipelineCache");if(!vkCreatePipelineCache){puts("FAIL vkCreatePipelineCache missing");return 2;}
 vkDestroyPipelineCache=(PFN_vkDestroyPipelineCache)GetProcAddress(module,"vkDestroyPipelineCache");if(!vkDestroyPipelineCache){puts("FAIL vkDestroyPipelineCache missing");return 2;}
 vkCreateGraphicsPipelines=(PFN_vkCreateGraphicsPipelines)GetProcAddress(module,"vkCreateGraphicsPipelines");if(!vkCreateGraphicsPipelines){puts("FAIL vkCreateGraphicsPipelines missing");return 2;}
 vkDestroyPipeline=(PFN_vkDestroyPipeline)GetProcAddress(module,"vkDestroyPipeline");if(!vkDestroyPipeline){puts("FAIL vkDestroyPipeline missing");return 2;}
#endif


 VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Generic vertex layout cache regression",.apiVersion=VK_API_VERSION_1_1};
 VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
 VkInstance instance;CHECK(vkCreateInstance(&ici,NULL,&instance));uint32_t n=1;VkPhysicalDevice physical;CHECK(vkEnumeratePhysicalDevices(instance,&n,&physical));
 VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(physical,&props);printf("GPU=%s\n",props.deviceName);
 VkQueueFamilyProperties families[32];n=32;vkGetPhysicalDeviceQueueFamilyProperties(physical,&n,families);uint32_t q=0;while(q<n && !(families[q].queueFlags&VK_QUEUE_GRAPHICS_BIT))q++;if(q==n)return 2;
 float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=q,.queueCount=1,.pQueuePriorities=&priority};
 const char *deviceExt="VK_KHR_portability_subset";
 uint32_t ec=0;CHECK(vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,NULL));
 VkExtensionProperties *extensions=calloc(ec,sizeof(*extensions));if(ec && !extensions)return 2;
 CHECK(vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,extensions));uint32_t hasSubset=0;
 for(uint32_t i=0;i<ec;i++)if(!strcmp(extensions[i].extensionName,deviceExt))hasSubset=1;
 free(extensions);
 VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=hasSubset,.ppEnabledExtensionNames=&deviceExt};CHECK(vkCreateDevice(physical,&di,NULL,&device));
 VkPipelineLayoutCreateInfo li={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};CHECK(vkCreatePipelineLayout(device,&li,NULL,&layout));
 VkAttachmentDescription ad={.format=VK_FORMAT_R8G8B8A8_UNORM,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE,.storeOp=VK_ATTACHMENT_STORE_OP_DONT_CARE,.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED,.finalLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
 VkAttachmentReference ref={0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription sub={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS,.colorAttachmentCount=1,.pColorAttachments=&ref};
 VkRenderPassCreateInfo ri={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.attachmentCount=1,.pAttachments=&ad,.subpassCount=1,.pSubpasses=&sub};CHECK(vkCreateRenderPass(device,&ri,NULL,&pass));
 VkShaderModuleCreateInfo si={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=sizeof(vs),.pCode=vs};CHECK(vkCreateShaderModule(device,&si,NULL,&shader));
 VkPipelineCacheCreateInfo ci={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};VkPipelineCache clean,bad,empty;CHECK(vkCreatePipelineCache(device,&ci,NULL,&clean));CHECK(vkCreatePipelineCache(device,&ci,NULL,&bad));CHECK(vkCreatePipelineCache(device,&ci,NULL,&empty));
 VkResult control=attempt(clean,3,1,"CONTROL fresh-cache valid");
 size_t before=0,afterSize=0;CHECK(vkGetPipelineCacheData(device,clean,&before,NULL));
 VkResult unused=attempt(clean,3,2,"REGRESSION valid plus unused location 0");
 CHECK(vkGetPipelineCacheData(device,clean,&afterSize,NULL));
 printf("[vk-vertex-reuse] before=%zu after=%zu unused-result=%d\n",before,afterSize,unused);
 int reused=unused==VK_SUCCESS && before==afterSize;

 attempt(bad,0,1,"PRIME mismatched-layout");VkResult after=attempt(bad,3,1,"REGRESSION same-cache valid");
 attempt(empty,0,0,"PRIME empty-layout");VkResult afterEmpty=attempt(empty,3,1,"REGRESSION same-cache valid after empty");
 vkDestroyPipelineCache(device,clean,NULL);vkDestroyPipelineCache(device,bad,NULL);vkDestroyPipelineCache(device,empty,NULL);
 vkDestroyShaderModule(device,shader,NULL);vkDestroyRenderPass(device,pass,NULL);vkDestroyPipelineLayout(device,layout,NULL);vkDestroyDevice(device,NULL);vkDestroyInstance(instance,NULL);
 printf("[vk-vertex-cache-test] %s control=%d after-mismatch=%d after-empty=%d\n",control==VK_SUCCESS && after==VK_SUCCESS && afterEmpty==VK_SUCCESS ? "PASS" : "FAIL",control,after,afterEmpty);
 printf("[vk-vertex-reuse-test] %s cache-before=%zu cache-after=%zu\n",control==VK_SUCCESS && after==VK_SUCCESS && afterEmpty==VK_SUCCESS && reused ? "PASS" : "FAIL",before,afterSize);
 return control!=VK_SUCCESS || after!=VK_SUCCESS || afterEmpty!=VK_SUCCESS || !reused;
}
