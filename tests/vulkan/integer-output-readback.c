/* SPDX-License-Identifier: MIT
 * Compatibility regression, not a conformance test: float-to-integer fragment
 * output values are undefined by Vulkan. Verify the opt-in bit-preserving policy
 * using real Vulkan rendering and image readback. No game data or fake driver.
 */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { VkResult r=(x); if(r){fprintf(stderr,"FAIL %s: %d\n",#x,r);exit(2);} }while(0)
static const uint32_t vs[]={0x07230203,0x10000,0,13,0,
 (2<<16)|17,1,(3<<16)|14,0,1,(7<<16)|15,0,10,0x6e69616d,0,7,8,
 (4<<16)|71,7,30,3,(4<<16)|71,8,11,0,
 (2<<16)|19,1,(3<<16)|33,2,1,(3<<16)|22,3,32,(4<<16)|23,4,3,4,
 (4<<16)|32,5,1,4,(4<<16)|32,6,3,4,(4<<16)|59,5,7,1,(4<<16)|59,6,8,3,
 (5<<16)|54,1,10,0,2,(2<<16)|248,11,(4<<16)|61,4,12,7,(3<<16)|62,8,12,(1<<16)|253,(1<<16)|56};
static const uint32_t fs[]={0x07230203,0x10000,0,12,0,
 (2<<16)|17,1,(3<<16)|14,0,1,(6<<16)|15,4,10,0x6e69616d,0,8,(3<<16)|16,10,7,
 (4<<16)|71,8,30,0,(2<<16)|19,1,(3<<16)|33,2,1,(3<<16)|22,3,32,
 (4<<16)|23,4,3,4,(4<<16)|32,5,3,4,(4<<16)|43,3,6,0x3f400000,
 (7<<16)|44,4,7,6,6,6,6,(4<<16)|59,5,8,3,
 (5<<16)|54,1,10,0,2,(2<<16)|248,11,(3<<16)|62,8,7,(1<<16)|253,(1<<16)|56};
static unsigned sourceInteger;
static size_t fragment_words(uint32_t* out,unsigned size,uint32_t bits){
 size_t n=5;memcpy(out,fs,20);
 for(size_t i=5;i<sizeof(fs)/4;){unsigned count=fs[i]>>16,op=fs[i]&65535;uint32_t w[16];memcpy(w,fs+i,count*4);
  if(op==22&&w[1]==3&&sourceInteger){w[0]=(4u<<16)|21;w[3]=sourceInteger==2;count=4;}
  if(op==23&&w[1]==4){if(size==1){i+=fs[i]>>16;continue;}w[3]=size;}
  if(op==32&&w[1]==5&&size==1)w[3]=3;
  if(op==43&&w[2]==6)w[3]=bits;
  if(op==44&&w[2]==7){if(size==1){w[0]=(4u<<16)|43;w[1]=3;w[3]=bits;count=4;}else{count=3+size;w[0]=(count<<16)|44;}}
  memcpy(out+n,w,count*4);n+=count;i+=fs[i]>>16;
 }return n*4;
}
static VkDevice dev;static VkPhysicalDeviceMemoryProperties mp;
static unsigned memtype(uint32_t bits,VkMemoryPropertyFlags flags){for(unsigned i=0;i<mp.memoryTypeCount;i++)if((bits&(1u<<i))&&(mp.memoryTypes[i].propertyFlags&flags)==flags)return i;exit(2);}
static VkDeviceMemory bind_buffer(VkBuffer b){VkMemoryRequirements r;vkGetBufferMemoryRequirements(dev,b,&r);VkMemoryAllocateInfo a={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=r.size,.memoryTypeIndex=memtype(r.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};VkDeviceMemory m;CHECK(vkAllocateMemory(dev,&a,NULL,&m));CHECK(vkBindBufferMemory(dev,b,m,0));return m;}
int main(int argc,char** argv){
 unsigned width=argc>1 ? (unsigned)atoi(argv[1]) : 4;uint32_t expected=argc>2 ? (uint32_t)strtoul(argv[2],NULL,16) : 0x3f400000;if(width<1||width>4)return 2;sourceInteger=argc>3?(unsigned)atoi(argv[3]):0;if(sourceInteger>2)return 2;int discard=argc>4?atoi(argv[4]):0;
 VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};VkInstanceCreateInfo ii={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};VkInstance ins;CHECK(vkCreateInstance(&ii,NULL,&ins));
 uint32_t n=1;VkPhysicalDevice gpu;CHECK(vkEnumeratePhysicalDevices(ins,&n,&gpu));VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(gpu,&props);printf("GPU=%s\n",props.deviceName);vkGetPhysicalDeviceMemoryProperties(gpu,&mp);
 VkQueueFamilyProperties families[32];n=32;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&n,families);unsigned family=0;while(family<n&&!(families[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))family++;if(family==n)return 2;
 float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};const char* ext="VK_KHR_portability_subset";
 VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=1,.ppEnabledExtensionNames=&ext};CHECK(vkCreateDevice(gpu,&di,NULL,&dev));VkQueue queue;vkGetDeviceQueue(dev,family,0,&queue);
 VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=256,.usage=VK_BUFFER_USAGE_VERTEX_BUFFER_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT};VkBuffer buffer;CHECK(vkCreateBuffer(dev,&bi,NULL,&buffer));VkDeviceMemory memory=bind_buffer(buffer);void* mapped;CHECK(vkMapMemory(dev,memory,0,VK_WHOLE_SIZE,0,&mapped));
 const float vertices[]={-1,-1,0,1,3,-1,0,1,-1,3,0,1};memcpy(mapped,vertices,sizeof(vertices));
 VkShaderModuleCreateInfo si={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=sizeof(vs),.pCode=vs};VkShaderModule vert,frag;CHECK(vkCreateShaderModule(dev,&si,NULL,&vert));uint32_t words[256];si.codeSize=fragment_words(words,width,expected);si.pCode=words;CHECK(vkCreateShaderModule(dev,&si,NULL,&frag));
 VkPipelineLayoutCreateInfo li={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};VkPipelineLayout layout;CHECK(vkCreatePipelineLayout(dev,&li,NULL,&layout));VkPipelineCacheCreateInfo pci={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};VkPipelineCache cache;CHECK(vkCreatePipelineCache(dev,&pci,NULL,&cache));
 VkCommandPoolCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=family};VkCommandPool pool;CHECK(vkCreateCommandPool(dev,&cpi,NULL,&pool));VkCommandBufferAllocateInfo ca={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};VkCommandBuffer cmd;CHECK(vkAllocateCommandBuffers(dev,&ca,&cmd));
 VkFormat formats[]={VK_FORMAT_R32_SFLOAT,VK_FORMAT_R32_UINT,VK_FORMAT_R32_SINT,VK_FORMAT_R32_SFLOAT,VK_FORMAT_R32_UINT};int failed=0;
 const char* setting=getenv("MADEIRA_VK_INTEGER_FRAGMENT_OUTPUTS");int enabled=setting&&!strcmp(setting,"1");
 if(sourceInteger)formats[0]=sourceInteger==1?VK_FORMAT_R32_UINT:VK_FORMAT_R32_SINT;
 for(unsigned round=0;round<(sourceInteger?1u:sizeof(formats)/sizeof(*formats));round++){
  VkFormat format=formats[round];VkAttachmentDescription ad={.format=format,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE,.storeOp=VK_ATTACHMENT_STORE_OP_STORE,.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED,.finalLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};VkAttachmentReference ref={0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription sub={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS,.colorAttachmentCount=1,.pColorAttachments=&ref};VkRenderPassCreateInfo ri={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.attachmentCount=1,.pAttachments=&ad,.subpassCount=1,.pSubpasses=&sub};VkRenderPass pass;CHECK(vkCreateRenderPass(dev,&ri,NULL,&pass));
  VkPipelineShaderStageCreateInfo stages[]={{.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_VERTEX_BIT,.module=vert,.pName="main"},{.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_FRAGMENT_BIT,.module=frag,.pName="main"}};
  VkVertexInputBindingDescription binding={0,16,VK_VERTEX_INPUT_RATE_VERTEX};VkVertexInputAttributeDescription attr={3,0,VK_FORMAT_R32G32B32A32_SFLOAT,0};VkPipelineVertexInputStateCreateInfo vi={.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,.vertexBindingDescriptionCount=1,.pVertexBindingDescriptions=&binding,.vertexAttributeDescriptionCount=1,.pVertexAttributeDescriptions=&attr};VkPipelineInputAssemblyStateCreateInfo ia={.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};VkViewport viewport={0,0,1,1,0,1};VkRect2D scissor={{0,0},{1,1}};VkPipelineViewportStateCreateInfo vp={.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,.viewportCount=1,.pViewports=&viewport,.scissorCount=1,.pScissors=&scissor};VkPipelineRasterizationStateCreateInfo raster={.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,.rasterizerDiscardEnable=discard,.polygonMode=VK_POLYGON_MODE_FILL,.lineWidth=1};VkPipelineMultisampleStateCreateInfo ms={.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT};VkPipelineColorBlendAttachmentState ba={.colorWriteMask=15};VkPipelineColorBlendStateCreateInfo bs={.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,.attachmentCount=1,.pAttachments=&ba};VkGraphicsPipelineCreateInfo pi={.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,.stageCount=2,.pStages=stages,.pVertexInputState=&vi,.pInputAssemblyState=&ia,.pViewportState=discard?(void*)1:&vp,.pRasterizationState=&raster,.pMultisampleState=discard?(void*)1:&ms,.pColorBlendState=discard?(void*)1:&bs,.layout=layout,.renderPass=pass};VkPipeline pipeline=VK_NULL_HANDLE;VkResult result=vkCreateGraphicsPipelines(dev,cache,1,&pi,NULL,&pipeline);printf("round=%u format=%d create=%d enabled=%d\n",round,format,result,enabled);
  if(discard){if(result)failed=1;if(pipeline)vkDestroyPipeline(dev,pipeline,NULL);vkDestroyRenderPass(dev,pass,NULL);continue;}
  if(result){if(enabled||sourceInteger||format==VK_FORMAT_R32_SFLOAT)failed=1;vkDestroyRenderPass(dev,pass,NULL);continue;}if(!enabled&&!sourceInteger&&format!=VK_FORMAT_R32_SFLOAT)failed=1;
  VkImageCreateInfo im={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,.format=format,.extent={1,1,1},.mipLevels=1,.arrayLayers=1,.samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT};VkImage image;CHECK(vkCreateImage(dev,&im,NULL,&image));VkMemoryRequirements mr;vkGetImageMemoryRequirements(dev,image,&mr);VkMemoryAllocateInfo ma={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,.memoryTypeIndex=memtype(mr.memoryTypeBits,0)};VkDeviceMemory imageMemory;CHECK(vkAllocateMemory(dev,&ma,NULL,&imageMemory));CHECK(vkBindImageMemory(dev,image,imageMemory,0));VkImageViewCreateInfo iv={.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,.image=image,.viewType=VK_IMAGE_VIEW_TYPE_2D,.format=format,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};VkImageView view;CHECK(vkCreateImageView(dev,&iv,NULL,&view));VkFramebufferCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,.renderPass=pass,.attachmentCount=1,.pAttachments=&view,.width=1,.height=1,.layers=1};VkFramebuffer frame;CHECK(vkCreateFramebuffer(dev,&fi,NULL,&frame));
  *(uint32_t*)((char*)mapped+128)=0xdeadc0de;CHECK(vkResetCommandBuffer(cmd,0));VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};CHECK(vkBeginCommandBuffer(cmd,&begin));VkRenderPassBeginInfo rb={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,.renderPass=pass,.framebuffer=frame,.renderArea={{0,0},{1,1}}};vkCmdBeginRenderPass(cmd,&rb,VK_SUBPASS_CONTENTS_INLINE);vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);VkDeviceSize offset=0;vkCmdBindVertexBuffers(cmd,0,1,&buffer,&offset);vkCmdDraw(cmd,3,1,0,0);vkCmdEndRenderPass(cmd);
  VkMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT};vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,1,&barrier,0,NULL,0,NULL);VkBufferImageCopy copy={.bufferOffset=128,.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageExtent={1,1,1}};vkCmdCopyImageToBuffer(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buffer,1,&copy);barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,NULL,0,NULL);CHECK(vkEndCommandBuffer(cmd));VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE));CHECK(vkQueueWaitIdle(queue));uint32_t actual=*(uint32_t*)((char*)mapped+128);printf("GPU image readback expected=%08x actual=%08x\n",expected,actual);failed|=actual!=expected;
  if(round==2){
   size_t bytes=0;CHECK(vkGetPipelineCacheData(dev,cache,&bytes,NULL));void* data=malloc(bytes);if(!data)return 2;CHECK(vkGetPipelineCacheData(dev,cache,&bytes,data));
   unsigned char guard[17];memset(guard,0xa5,sizeof(guard));size_t small=1;VkResult shortResult=vkGetPipelineCacheData(dev,cache,&small,guard+8);if(shortResult!=VK_INCOMPLETE||guard[7]!=0xa5||guard[9]!=0xa5){puts("FAIL short export guard");return 2;}
   VkPipelineCacheCreateInfo importedInfo={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,.initialDataSize=bytes,.pInitialData=data};VkPipelineCache imported,merged;CHECK(vkCreatePipelineCache(dev,&importedInfo,NULL,&imported));free(data);CHECK(vkCreatePipelineCache(dev,&pci,NULL,&merged));CHECK(vkMergePipelineCaches(dev,merged,1,&imported));vkDestroyPipelineCache(dev,imported,NULL);vkDestroyPipelineCache(dev,cache,NULL);cache=merged;printf("cache export/import/merge bytes=%zu source caches destroyed\n",bytes);
  }
  vkDestroyFramebuffer(dev,frame,NULL);vkDestroyImageView(dev,view,NULL);vkDestroyImage(dev,image,NULL);vkFreeMemory(dev,imageMemory,NULL);vkDestroyPipeline(dev,pipeline,NULL);vkDestroyRenderPass(dev,pass,NULL);
 }
 vkDestroyCommandPool(dev,pool,NULL);vkDestroyPipelineCache(dev,cache,NULL);vkDestroyPipelineLayout(dev,layout,NULL);vkDestroyShaderModule(dev,vert,NULL);vkDestroyShaderModule(dev,frag,NULL);vkUnmapMemory(dev,memory);vkDestroyBuffer(dev,buffer,NULL);vkFreeMemory(dev,memory,NULL);vkDestroyDevice(dev,NULL);vkDestroyInstance(ins,NULL);printf("%s integer-output compatibility and float control\n",failed?"FAIL":"PASS");return failed;
}
