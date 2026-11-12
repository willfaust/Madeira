/* Generic bounded MoltenVK pipeline-cache regression. SPDX-License-Identifier: MIT
 * Real Vulkan compute dispatch and readback, including a pipeline retained while
 * its source library is evicted from the optional cache. No game data or bypass.
 * Cache-size expectations are implementation-specific, not Vulkan conformance.
 */
#ifdef _WIN32
#define VK_NO_PROTOTYPES
#include <windows.h>
#else
#include <pthread.h>
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
static PFN_vkCreateDescriptorSetLayout vkCreateDescriptorSetLayout;
static PFN_vkDestroyDescriptorSetLayout vkDestroyDescriptorSetLayout;
static PFN_vkCreatePipelineLayout vkCreatePipelineLayout;
static PFN_vkDestroyPipelineLayout vkDestroyPipelineLayout;
static PFN_vkCreateShaderModule vkCreateShaderModule;
static PFN_vkDestroyShaderModule vkDestroyShaderModule;
static PFN_vkCreatePipelineCache vkCreatePipelineCache;
static PFN_vkDestroyPipelineCache vkDestroyPipelineCache;
static PFN_vkGetPipelineCacheData vkGetPipelineCacheData;
static PFN_vkMergePipelineCaches vkMergePipelineCaches;
static PFN_vkCreateComputePipelines vkCreateComputePipelines;
static PFN_vkDestroyPipeline vkDestroyPipeline;
static PFN_vkCreateBuffer vkCreateBuffer;
static PFN_vkDestroyBuffer vkDestroyBuffer;
static PFN_vkGetBufferMemoryRequirements vkGetBufferMemoryRequirements;
static PFN_vkAllocateMemory vkAllocateMemory;
static PFN_vkFreeMemory vkFreeMemory;
static PFN_vkBindBufferMemory vkBindBufferMemory;
static PFN_vkMapMemory vkMapMemory;
static PFN_vkUnmapMemory vkUnmapMemory;
static PFN_vkInvalidateMappedMemoryRanges vkInvalidateMappedMemoryRanges;
static PFN_vkCreateDescriptorPool vkCreateDescriptorPool;
static PFN_vkDestroyDescriptorPool vkDestroyDescriptorPool;
static PFN_vkAllocateDescriptorSets vkAllocateDescriptorSets;
static PFN_vkUpdateDescriptorSets vkUpdateDescriptorSets;
static PFN_vkGetDeviceQueue vkGetDeviceQueue;
static PFN_vkCreateCommandPool vkCreateCommandPool;
static PFN_vkDestroyCommandPool vkDestroyCommandPool;
static PFN_vkAllocateCommandBuffers vkAllocateCommandBuffers;
static PFN_vkBeginCommandBuffer vkBeginCommandBuffer;
static PFN_vkEndCommandBuffer vkEndCommandBuffer;
static PFN_vkCmdBindPipeline vkCmdBindPipeline;
static PFN_vkCmdBindDescriptorSets vkCmdBindDescriptorSets;
static PFN_vkCmdDispatch vkCmdDispatch;
static PFN_vkCmdPipelineBarrier vkCmdPipelineBarrier;
static PFN_vkQueueSubmit vkQueueSubmit;
static PFN_vkQueueWaitIdle vkQueueWaitIdle;
static PFN_vkResetCommandBuffer vkResetCommandBuffer;
#endif
#define CHECK(x) do { VkResult rc=(x); if(rc!=VK_SUCCESS){fprintf(stderr,"[vk-cache-budget] FAIL %s result=%d\n",#x,rc);return 2;} }while(0)
/* SPIR-V 1.0: set=0,binding=0 storage buffer uint; main writes a literal. */
static const uint32_t code[]={0x07230203,0x00010000,0,13,0,
 (2<<16)|17,1, (3<<16)|14,0,1,
 (5<<16)|15,5,10,0x6e69616d,0, (6<<16)|16,10,17,1,1,1,
 (3<<16)|71,6,3, (5<<16)|72,6,0,35,0,
 (4<<16)|71,8,34,0, (4<<16)|71,8,33,0,
 (2<<16)|19,1, (3<<16)|33,2,1, (4<<16)|21,3,32,0,
 (4<<16)|43,3,4,0, (4<<16)|43,3,5,0x12340000,
 (3<<16)|30,6,3, (4<<16)|32,7,2,6, (4<<16)|59,7,8,2,
 (4<<16)|32,9,2,3, (5<<16)|54,1,10,0,2, (2<<16)|248,11,
 (5<<16)|65,9,12,8,4, (3<<16)|62,12,5, (1<<16)|253, (1<<16)|56};
static int build(VkDevice dev,VkPipelineCache cache,VkPipelineLayout layout,unsigned value,VkPipeline *pipeline){
 uint32_t words[sizeof(code)/4];memcpy(words,code,sizeof(code));
 for(unsigned i=0;i<sizeof(words)/4;i++)if(words[i]==0x12340000){words[i]+=value;break;}
 VkShaderModuleCreateInfo si={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=sizeof(words),.pCode=words};VkShaderModule module;CHECK(vkCreateShaderModule(dev,&si,NULL,&module));
 VkComputePipelineCreateInfo ci={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=module,.pName="main"},.layout=layout};
 VkResult result=vkCreateComputePipelines(dev,cache,1,&ci,NULL,pipeline);vkDestroyShaderModule(dev,module,NULL);CHECK(result);return 0;
}
struct cache_worker {VkDevice dev;VkPipelineCache cache;VkPipelineLayout layout;unsigned first,count;int result;};
#ifdef _WIN32
static DWORD WINAPI cache_worker_run(void *data)
#else
static void *cache_worker_run(void *data)
#endif
{
 struct cache_worker *worker=data;
 for(unsigned i=0;i<worker->count;i++){VkPipeline pipeline;worker->result=build(worker->dev,worker->cache,worker->layout,worker->first+i,&pipeline);if(worker->result)break;vkDestroyPipeline(worker->dev,pipeline,NULL);}
 return 0;
}
static int readback(VkDevice dev,VkQueue queue,VkCommandBuffer cmd,VkPipeline pipeline,VkPipelineLayout layout,VkDescriptorSet set,VkDeviceMemory memory,void *mapped,unsigned expected){
 *(volatile uint32_t*)mapped=0;
 CHECK(vkResetCommandBuffer(cmd,0));VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};CHECK(vkBeginCommandBuffer(cmd,&begin));
 vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,layout,0,1,&set,0,NULL);vkCmdDispatch(cmd,1,1,1);
 VkMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,.dstAccessMask=VK_ACCESS_HOST_READ_BIT};vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,NULL,0,NULL);
 CHECK(vkEndCommandBuffer(cmd));VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE));CHECK(vkQueueWaitIdle(queue));
 VkMappedMemoryRange range={.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,.memory=memory,.size=VK_WHOLE_SIZE};CHECK(vkInvalidateMappedMemoryRanges(dev,1,&range));
 unsigned actual=*(volatile uint32_t*)mapped;printf("[vk-cache-budget] readback expected=%08x actual=%08x\n",expected,actual);return actual!=expected;
}
int main(int argc,char **argv){
#ifdef _WIN32
 HMODULE dll=LoadLibraryA("vulkan-1.dll");if(!dll){puts("[vk-cache-budget] FAIL missing vulkan-1.dll");return 2;}
 vkCreateInstance=(PFN_vkCreateInstance)GetProcAddress(dll,"vkCreateInstance");if(!vkCreateInstance)return 2;
 vkDestroyInstance=(PFN_vkDestroyInstance)GetProcAddress(dll,"vkDestroyInstance");if(!vkDestroyInstance)return 2;
 vkEnumeratePhysicalDevices=(PFN_vkEnumeratePhysicalDevices)GetProcAddress(dll,"vkEnumeratePhysicalDevices");if(!vkEnumeratePhysicalDevices)return 2;
 vkGetPhysicalDeviceProperties=(PFN_vkGetPhysicalDeviceProperties)GetProcAddress(dll,"vkGetPhysicalDeviceProperties");if(!vkGetPhysicalDeviceProperties)return 2;
 vkGetPhysicalDeviceQueueFamilyProperties=(PFN_vkGetPhysicalDeviceQueueFamilyProperties)GetProcAddress(dll,"vkGetPhysicalDeviceQueueFamilyProperties");if(!vkGetPhysicalDeviceQueueFamilyProperties)return 2;
 vkEnumerateDeviceExtensionProperties=(PFN_vkEnumerateDeviceExtensionProperties)GetProcAddress(dll,"vkEnumerateDeviceExtensionProperties");if(!vkEnumerateDeviceExtensionProperties)return 2;
 vkCreateDevice=(PFN_vkCreateDevice)GetProcAddress(dll,"vkCreateDevice");if(!vkCreateDevice)return 2;
 vkDestroyDevice=(PFN_vkDestroyDevice)GetProcAddress(dll,"vkDestroyDevice");if(!vkDestroyDevice)return 2;
 vkCreateDescriptorSetLayout=(PFN_vkCreateDescriptorSetLayout)GetProcAddress(dll,"vkCreateDescriptorSetLayout");if(!vkCreateDescriptorSetLayout)return 2;
 vkDestroyDescriptorSetLayout=(PFN_vkDestroyDescriptorSetLayout)GetProcAddress(dll,"vkDestroyDescriptorSetLayout");if(!vkDestroyDescriptorSetLayout)return 2;
 vkCreatePipelineLayout=(PFN_vkCreatePipelineLayout)GetProcAddress(dll,"vkCreatePipelineLayout");if(!vkCreatePipelineLayout)return 2;
 vkDestroyPipelineLayout=(PFN_vkDestroyPipelineLayout)GetProcAddress(dll,"vkDestroyPipelineLayout");if(!vkDestroyPipelineLayout)return 2;
 vkCreateShaderModule=(PFN_vkCreateShaderModule)GetProcAddress(dll,"vkCreateShaderModule");if(!vkCreateShaderModule)return 2;
 vkDestroyShaderModule=(PFN_vkDestroyShaderModule)GetProcAddress(dll,"vkDestroyShaderModule");if(!vkDestroyShaderModule)return 2;
 vkCreatePipelineCache=(PFN_vkCreatePipelineCache)GetProcAddress(dll,"vkCreatePipelineCache");if(!vkCreatePipelineCache)return 2;
 vkDestroyPipelineCache=(PFN_vkDestroyPipelineCache)GetProcAddress(dll,"vkDestroyPipelineCache");if(!vkDestroyPipelineCache)return 2;
 vkGetPipelineCacheData=(PFN_vkGetPipelineCacheData)GetProcAddress(dll,"vkGetPipelineCacheData");if(!vkGetPipelineCacheData)return 2;
 vkMergePipelineCaches=(PFN_vkMergePipelineCaches)GetProcAddress(dll,"vkMergePipelineCaches");if(!vkMergePipelineCaches)return 2;
 vkCreateComputePipelines=(PFN_vkCreateComputePipelines)GetProcAddress(dll,"vkCreateComputePipelines");if(!vkCreateComputePipelines)return 2;
 vkDestroyPipeline=(PFN_vkDestroyPipeline)GetProcAddress(dll,"vkDestroyPipeline");if(!vkDestroyPipeline)return 2;
 vkCreateBuffer=(PFN_vkCreateBuffer)GetProcAddress(dll,"vkCreateBuffer");if(!vkCreateBuffer)return 2;
 vkDestroyBuffer=(PFN_vkDestroyBuffer)GetProcAddress(dll,"vkDestroyBuffer");if(!vkDestroyBuffer)return 2;
 vkGetBufferMemoryRequirements=(PFN_vkGetBufferMemoryRequirements)GetProcAddress(dll,"vkGetBufferMemoryRequirements");if(!vkGetBufferMemoryRequirements)return 2;
 vkAllocateMemory=(PFN_vkAllocateMemory)GetProcAddress(dll,"vkAllocateMemory");if(!vkAllocateMemory)return 2;
 vkFreeMemory=(PFN_vkFreeMemory)GetProcAddress(dll,"vkFreeMemory");if(!vkFreeMemory)return 2;
 vkBindBufferMemory=(PFN_vkBindBufferMemory)GetProcAddress(dll,"vkBindBufferMemory");if(!vkBindBufferMemory)return 2;
 vkMapMemory=(PFN_vkMapMemory)GetProcAddress(dll,"vkMapMemory");if(!vkMapMemory)return 2;
 vkUnmapMemory=(PFN_vkUnmapMemory)GetProcAddress(dll,"vkUnmapMemory");if(!vkUnmapMemory)return 2;
 vkInvalidateMappedMemoryRanges=(PFN_vkInvalidateMappedMemoryRanges)GetProcAddress(dll,"vkInvalidateMappedMemoryRanges");if(!vkInvalidateMappedMemoryRanges)return 2;
 vkCreateDescriptorPool=(PFN_vkCreateDescriptorPool)GetProcAddress(dll,"vkCreateDescriptorPool");if(!vkCreateDescriptorPool)return 2;
 vkDestroyDescriptorPool=(PFN_vkDestroyDescriptorPool)GetProcAddress(dll,"vkDestroyDescriptorPool");if(!vkDestroyDescriptorPool)return 2;
 vkAllocateDescriptorSets=(PFN_vkAllocateDescriptorSets)GetProcAddress(dll,"vkAllocateDescriptorSets");if(!vkAllocateDescriptorSets)return 2;
 vkUpdateDescriptorSets=(PFN_vkUpdateDescriptorSets)GetProcAddress(dll,"vkUpdateDescriptorSets");if(!vkUpdateDescriptorSets)return 2;
 vkGetDeviceQueue=(PFN_vkGetDeviceQueue)GetProcAddress(dll,"vkGetDeviceQueue");if(!vkGetDeviceQueue)return 2;
 vkCreateCommandPool=(PFN_vkCreateCommandPool)GetProcAddress(dll,"vkCreateCommandPool");if(!vkCreateCommandPool)return 2;
 vkDestroyCommandPool=(PFN_vkDestroyCommandPool)GetProcAddress(dll,"vkDestroyCommandPool");if(!vkDestroyCommandPool)return 2;
 vkAllocateCommandBuffers=(PFN_vkAllocateCommandBuffers)GetProcAddress(dll,"vkAllocateCommandBuffers");if(!vkAllocateCommandBuffers)return 2;
 vkBeginCommandBuffer=(PFN_vkBeginCommandBuffer)GetProcAddress(dll,"vkBeginCommandBuffer");if(!vkBeginCommandBuffer)return 2;
 vkEndCommandBuffer=(PFN_vkEndCommandBuffer)GetProcAddress(dll,"vkEndCommandBuffer");if(!vkEndCommandBuffer)return 2;
 vkCmdBindPipeline=(PFN_vkCmdBindPipeline)GetProcAddress(dll,"vkCmdBindPipeline");if(!vkCmdBindPipeline)return 2;
 vkCmdBindDescriptorSets=(PFN_vkCmdBindDescriptorSets)GetProcAddress(dll,"vkCmdBindDescriptorSets");if(!vkCmdBindDescriptorSets)return 2;
 vkCmdDispatch=(PFN_vkCmdDispatch)GetProcAddress(dll,"vkCmdDispatch");if(!vkCmdDispatch)return 2;
 vkCmdPipelineBarrier=(PFN_vkCmdPipelineBarrier)GetProcAddress(dll,"vkCmdPipelineBarrier");if(!vkCmdPipelineBarrier)return 2;
 vkQueueSubmit=(PFN_vkQueueSubmit)GetProcAddress(dll,"vkQueueSubmit");if(!vkQueueSubmit)return 2;
 vkQueueWaitIdle=(PFN_vkQueueWaitIdle)GetProcAddress(dll,"vkQueueWaitIdle");if(!vkQueueWaitIdle)return 2;
 vkResetCommandBuffer=(PFN_vkResetCommandBuffer)GetProcAddress(dll,"vkResetCommandBuffer");if(!vkResetCommandBuffer)return 2;
#endif
 unsigned limit=argc>1?(unsigned)strtoul(argv[1],NULL,10):256;if(limit<4 || limit>2048)return 2;
 VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Vulkan bounded cache and retained pipeline readback",.apiVersion=VK_API_VERSION_1_1};VkInstanceCreateInfo ii={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};VkInstance instance;CHECK(vkCreateInstance(&ii,NULL,&instance));
 uint32_t n=1;VkPhysicalDevice physical;CHECK(vkEnumeratePhysicalDevices(instance,&n,&physical));VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(physical,&props);printf("[vk-cache-budget] GPU=%s limit=%u\n",props.deviceName,limit);
 VkQueueFamilyProperties families[32];n=32;vkGetPhysicalDeviceQueueFamilyProperties(physical,&n,families);unsigned family=0;while(family<n && !(families[family].queueFlags&VK_QUEUE_COMPUTE_BIT))family++;if(family==n)return 2;
 uint32_t ec=0;CHECK(vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,NULL));VkExtensionProperties *exts=calloc(ec,sizeof(*exts));if(ec && !exts)return 2;CHECK(vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,exts));unsigned portability=0;for(unsigned i=0;i<ec;i++)if(!strcmp(exts[i].extensionName,"VK_KHR_portability_subset"))portability=1;free(exts);const char *subset="VK_KHR_portability_subset";
 float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=portability,.ppEnabledExtensionNames=&subset};VkDevice dev;CHECK(vkCreateDevice(physical,&di,NULL,&dev));VkQueue queue;vkGetDeviceQueue(dev,family,0,&queue);
 VkDescriptorSetLayoutBinding binding={0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,NULL};VkDescriptorSetLayoutCreateInfo dsi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=1,.pBindings=&binding};VkDescriptorSetLayout setLayout;CHECK(vkCreateDescriptorSetLayout(dev,&dsi,NULL,&setLayout));VkPipelineLayoutCreateInfo li={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&setLayout};VkPipelineLayout layout;CHECK(vkCreatePipelineLayout(dev,&li,NULL,&layout));
 VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=4,.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};VkBuffer buffer;CHECK(vkCreateBuffer(dev,&bi,NULL,&buffer));VkMemoryRequirements req;vkGetBufferMemoryRequirements(dev,buffer,&req);VkPhysicalDeviceMemoryProperties mp;
#ifdef _WIN32
 PFN_vkGetPhysicalDeviceMemoryProperties getMem=(PFN_vkGetPhysicalDeviceMemoryProperties)GetProcAddress(dll,"vkGetPhysicalDeviceMemoryProperties");if(!getMem)return 2;getMem(physical,&mp);
#else
 vkGetPhysicalDeviceMemoryProperties(physical,&mp);
#endif
 unsigned type=0;for(;type<mp.memoryTypeCount;type++)if((req.memoryTypeBits&(1u<<type)) && (mp.memoryTypes[type].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))break;if(type==mp.memoryTypeCount)return 2;
 VkMemoryAllocateInfo mi={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=type};VkDeviceMemory memory;CHECK(vkAllocateMemory(dev,&mi,NULL,&memory));CHECK(vkBindBufferMemory(dev,buffer,memory,0));void *mapped;CHECK(vkMapMemory(dev,memory,0,VK_WHOLE_SIZE,0,&mapped));
 VkDescriptorPoolSize ps={VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1};VkDescriptorPoolCreateInfo dpi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&ps};VkDescriptorPool pool;CHECK(vkCreateDescriptorPool(dev,&dpi,NULL,&pool));VkDescriptorSetAllocateInfo da={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=pool,.descriptorSetCount=1,.pSetLayouts=&setLayout};VkDescriptorSet set;CHECK(vkAllocateDescriptorSets(dev,&da,&set));VkDescriptorBufferInfo db={buffer,0,4};VkWriteDescriptorSet write={.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&db};vkUpdateDescriptorSets(dev,1,&write,0,NULL);
 VkCommandPoolCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=family};VkCommandPool commands;CHECK(vkCreateCommandPool(dev,&cpi,NULL,&commands));VkCommandBufferAllocateInfo ca={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=commands,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};VkCommandBuffer cmd;CHECK(vkAllocateCommandBuffers(dev,&ca,&cmd));
 VkPipelineCacheCreateInfo pci={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};VkPipelineCache cache;CHECK(vkCreatePipelineCache(dev,&pci,NULL,&cache));VkPipeline retained=VK_NULL_HANDLE;size_t warm=0,full=0;
 for(unsigned i=0;i<limit*3;i++){VkPipeline pipeline;CHECK(build(dev,cache,layout,i,&pipeline));if(!i)retained=pipeline;else vkDestroyPipeline(dev,pipeline,NULL);if(i+1==limit)CHECK(vkGetPipelineCacheData(dev,cache,&warm,NULL));}
 CHECK(vkGetPipelineCacheData(dev,cache,&full,NULL));printf("[vk-cache-budget] cache-at-limit=%zu cache-after-3x=%zu\n",warm,full);int failed=full>warm+warm/10;
 failed|=readback(dev,queue,cmd,retained,layout,set,memory,mapped,0x12340000);vkDestroyPipeline(dev,retained,NULL);
 VkPipeline recreated;CHECK(build(dev,cache,layout,0,&recreated));failed|=readback(dev,queue,cmd,recreated,layout,set,memory,mapped,0x12340000);vkDestroyPipeline(dev,recreated,NULL);
 /* Multiple application threads share a normally synchronized cache. */
 struct cache_worker workers[4];
#ifdef _WIN32
 HANDLE threads[4];
#else
 pthread_t threads[4];
#endif
 for(unsigned i=0;i<4;i++){
  workers[i]=(struct cache_worker){dev,cache,layout,limit*3+i*limit,limit,0};
#ifdef _WIN32
  threads[i]=CreateThread(NULL,0,cache_worker_run,&workers[i],0,NULL);if(!threads[i])return 2;
#else
  if(pthread_create(&threads[i],NULL,cache_worker_run,&workers[i]))return 2;
#endif
 }
 for(unsigned i=0;i<4;i++){
#ifdef _WIN32
  WaitForSingleObject(threads[i],INFINITE);CloseHandle(threads[i]);
#else
  pthread_join(threads[i],NULL);
#endif
  failed|=workers[i].result!=0;
 }
 CHECK(vkGetPipelineCacheData(dev,cache,&full,NULL));failed|=full>warm+warm/10;
 printf("[vk-cache-budget] concurrent-shared-cache bytes=%zu workers=4\n",full);
 /* Export, import and merge must remain usable after eviction. */
 size_t bytes=0;CHECK(vkGetPipelineCacheData(dev,cache,&bytes,NULL));void *data=malloc(bytes);if(!data)return 2;CHECK(vkGetPipelineCacheData(dev,cache,&bytes,data));
 if(argc>3){FILE *file=fopen(argv[3],"wb");if(!file || fwrite(data,1,bytes,file)!=bytes)return 2;fclose(file);}
 if(argc>2 && strcmp(argv[2],"-")){FILE *file=fopen(argv[2],"rb");if(!file)return 2;fseek(file,0,SEEK_END);long length=ftell(file);rewind(file);if(length<=0 || length>64*1024*1024)return 2;free(data);bytes=(size_t)length;data=malloc(bytes);if(!data || fread(data,1,bytes,file)!=bytes)return 2;fclose(file);}
 pci.initialDataSize=bytes;pci.pInitialData=data;VkPipelineCache imported;CHECK(vkCreatePipelineCache(dev,&pci,NULL,&imported));free(data);CHECK(vkMergePipelineCaches(dev,imported,1,&cache));
 CHECK(build(dev,imported,layout,limit*3-1,&recreated));failed|=readback(dev,queue,cmd,recreated,layout,set,memory,mapped,0x12340000+limit*3-1);vkDestroyPipeline(dev,recreated,NULL);
 vkDestroyPipelineCache(dev,imported,NULL);vkDestroyPipelineCache(dev,cache,NULL);vkDestroyCommandPool(dev,commands,NULL);vkDestroyDescriptorPool(dev,pool,NULL);vkUnmapMemory(dev,memory);vkDestroyBuffer(dev,buffer,NULL);vkFreeMemory(dev,memory,NULL);vkDestroyPipelineLayout(dev,layout,NULL);vkDestroyDescriptorSetLayout(dev,setLayout,NULL);vkDestroyDevice(dev,NULL);vkDestroyInstance(instance,NULL);
 printf("[vk-cache-budget] %s bounded-cache + retained-pipeline + recompile + concurrent-cache + import/merge readback\n",failed?"FAIL":"PASS");return failed;
}
