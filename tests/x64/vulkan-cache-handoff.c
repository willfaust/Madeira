/* Generic multi-worker Vulkan cache handoff regression. SPDX-License-Identifier: MIT
 * Reuse the valid compute SPIR-V/bootstrap/readback helpers. No game inputs,
 * capability overrides or error-result substitution. All waits are finite on
 * Windows; native pthread controls are run under a subprocess timeout.
 */
#define main cache_budget_fixture_main
#include "vulkan-cache-budget.c"
#undef main
#ifdef _WIN32
int windows_handoff_test(void);
#endif
int cache_handoff_main(void) {
 setvbuf(stdout,NULL,_IONBF,0);
 puts("[vk-handoff] BEGIN eight-worker cache merge and GPU handoff");
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
 unsigned limit=32;
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

 VkPipelineCache sources[8], target;
 VkPipeline retained[8];
 VkPipelineCacheCreateInfo pci={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
 struct cache_worker workers[8];
#ifdef _WIN32
 HANDLE threads[8];
#else
 pthread_t threads[8];
#endif
 CHECK(vkCreatePipelineCache(dev,&pci,NULL,&target));
 for(unsigned i=0;i<8;i++) {
  CHECK(vkCreatePipelineCache(dev,&pci,NULL,&sources[i]));
  CHECK(build(dev,sources[i],layout,i*32,&retained[i]));
  workers[i]=(struct cache_worker){dev,sources[i],layout,i*32,32,0};
#ifdef _WIN32
  threads[i]=CreateThread(NULL,0,cache_worker_run,&workers[i],0,NULL);
  if(!threads[i])return 2;
#else
  if(pthread_create(&threads[i],NULL,cache_worker_run,&workers[i]))return 2;
#endif
 }
#ifdef _WIN32
 DWORD joined=WaitForMultipleObjects(8,threads,TRUE,30000);
 if(joined!=WAIT_OBJECT_0){printf("[vk-handoff] FAIL worker join status=%lu error=%lu\n",(unsigned long)joined,(unsigned long)GetLastError());return 2;}
#endif
 for(unsigned i=0;i<8;i++) {
#ifdef _WIN32
  CloseHandle(threads[i]);
#else
  pthread_join(threads[i],NULL);
#endif
  if(workers[i].result)return 2;
 }
 puts("[vk-handoff] workers complete; merge8 ENTRY");
 CHECK(vkMergePipelineCaches(dev,target,8,sources));
 puts("[vk-handoff] merge8 RETURN");
 for(unsigned i=0;i<8;i++) {
  printf("[vk-handoff] destroy source[%u] ENTRY\n",i);
  vkDestroyPipelineCache(dev,sources[i],NULL);
  printf("[vk-handoff] destroy source[%u] RETURN\n",i);
 }
#ifdef _WIN32
 if(windows_handoff_test())return 2;
#endif
 for(unsigned i=0;i<8;i++) {
  if(readback(dev,queue,cmd,retained[i],layout,set,memory,mapped,0x12340000+i*32))return 2;
  vkDestroyPipeline(dev,retained[i],NULL);
  VkPipeline recreated;
  CHECK(build(dev,target,layout,i*32,&recreated));
  if(readback(dev,queue,cmd,recreated,layout,set,memory,mapped,0x12340000+i*32))return 2;
  vkDestroyPipeline(dev,recreated,NULL);
 }
 size_t bytes=0;CHECK(vkGetPipelineCacheData(dev,target,&bytes,NULL));
 void *data=malloc(bytes);if(!data)return 2;
 CHECK(vkGetPipelineCacheData(dev,target,&bytes,data));free(data);
 printf("[vk-handoff] merged cache export bytes=%zu; GPU readbacks16 PASS\n",bytes);
 vkDestroyPipelineCache(dev,target,NULL);
 vkDestroyCommandPool(dev,commands,NULL);vkDestroyDescriptorPool(dev,pool,NULL);
 vkUnmapMemory(dev,memory);vkDestroyBuffer(dev,buffer,NULL);vkFreeMemory(dev,memory,NULL);
 vkDestroyPipelineLayout(dev,layout,NULL);vkDestroyDescriptorSetLayout(dev,setLayout,NULL);
 vkDestroyDevice(dev,NULL);vkDestroyInstance(instance,NULL);
 puts("[vk-handoff] PASS eight-source merge/destroy and post-merge real GPU work");return 0;
}

#ifndef _WIN32
int main(void) { return cache_handoff_main(); }
#endif
