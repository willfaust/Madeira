/* Implementation compatibility test, NOT a Vulkan conformance test.
 * Missing vertex descriptions violate Input-07904 without enabled robustness.
 * An opt-in policy may supply real zero vertex data; capabilities stay unchanged.
 * SPDX-License-Identifier: MIT */
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { VkResult r=(x); if(r){fprintf(stderr,"FAIL %s result=%d\n",#x,r);return 2;} }while(0)
static const uint32_t code[]={0x07230203,0x10000,0,25,0,
 (2<<16)|17,1,(3<<16)|14,0,1,(7<<16)|15,0,10,0x6e69616d,0,14,18,
 (3<<16)|71,6,3,(5<<16)|72,6,0,35,0,(4<<16)|71,8,34,0,(4<<16)|71,8,33,0,
 (4<<16)|71,14,30,12,(4<<16)|71,18,11,0,
 (2<<16)|19,1,(3<<16)|33,2,1,(4<<16)|21,3,32,0,(4<<16)|43,3,4,0,
 (3<<16)|30,6,3,(4<<16)|32,7,2,6,(4<<16)|59,7,8,2,(4<<16)|32,9,2,3,
 (3<<16)|22,13,32,(4<<16)|23,15,13,4,(4<<16)|32,16,1,15,(4<<16)|59,16,14,1,
 (4<<16)|32,17,3,15,(4<<16)|59,17,18,3,(4<<16)|43,13,19,0,(4<<16)|43,13,20,0x3f800000,
 (7<<16)|44,15,21,19,19,19,20,
 (5<<16)|54,1,10,0,2,(2<<16)|248,11,(4<<16)|61,15,22,14,
 (5<<16)|81,13,23,22,0,(4<<16)|124,3,24,23,(5<<16)|65,9,12,8,4,
 (3<<16)|62,12,24,(3<<16)|62,18,21,(1<<16)|253,(1<<16)|56};
/* A second shader reads a real descriptor at Metal slot 1 after the missing
 * attribute pipeline used that slot for zeros. Catches bypassed state tracking. */
static size_t make_second_shader(uint32_t *out) {
 size_t n=5;memcpy(out,code,20);out[3]=29;
 for(size_t i=5;i<sizeof(code)/4;) {
  unsigned count=code[i]>>16,op=code[i]&65535;
  if(op==19) {uint32_t a[]={(4<<16)|71,25,34,0,(4<<16)|71,25,33,8};memcpy(out+n,a,sizeof(a));n+=8;}
  if(op==54) {uint32_t a[]={(4<<16)|59,7,25,2};memcpy(out+n,a,sizeof(a));n+=4;}
  if(op==62 && code[i+1]==12) {uint32_t a[]={(5<<16)|65,9,26,25,4,(4<<16)|61,3,27,26,(5<<16)|198,3,28,24,27,(3<<16)|62,12,28};memcpy(out+n,a,sizeof(a));n+=17;}
  else {memcpy(out+n,code+i,count*4);n+=count;}
  i+=count;
 }
 return n*4;
}
static size_t make_typed_input(uint32_t *out, unsigned kind) {
 size_t n=5;memcpy(out,code,20);out[3]=31;
 for(size_t i=5;i<sizeof(code)/4;) {
  unsigned count=code[i]>>16,op=code[i]&65535;uint32_t inst[16];memcpy(inst,code+i,count*4);
  if(op==32 && code[i+1]==16) {
   if(kind==1){uint32_t a[]={(4<<16)|21,29,32,1};memcpy(out+n,a,sizeof(a));n+=4;}
   uint32_t a[]={(4<<16)|23,30,kind==1 ? 29u : 3u,4};memcpy(out+n,a,sizeof(a));n+=4;inst[3]=30;
  }
  if(op==61 && inst[2]==22)inst[1]=30;
  if(op==81 && inst[2]==23)inst[1]=kind==1 ? 29 : 3;
  if(op==124 && kind==2)inst[0]=(4<<16)|83;
  memcpy(out+n,inst,count*4);n+=count;i+=count;
 }
 return n*4;
}
int main(int argc,char **argv) {
 unsigned kind=argc>1 ? (unsigned)atoi(argv[1]) : 0;if(kind>2)return 2;

 VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};
 VkInstanceCreateInfo ii={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
 VkInstance instance;CHECK(vkCreateInstance(&ii,NULL,&instance));
 uint32_t n=1;VkPhysicalDevice gpu;CHECK(vkEnumeratePhysicalDevices(instance,&n,&gpu));
 VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(gpu,&props);printf("GPU=%s\n",props.deviceName);
 VkPhysicalDeviceFeatures features;vkGetPhysicalDeviceFeatures(gpu,&features);uint64_t featureHash=14695981039346656037ull;for(size_t i=0;i<sizeof(features);i++)featureHash=(featureHash^((unsigned char*)&features)[i])*1099511628211ull;printf("features-hash=%016llx\n",(unsigned long long)featureHash);if(!features.vertexPipelineStoresAndAtomics)return 2;
 VkQueueFamilyProperties families[32];n=32;vkGetPhysicalDeviceQueueFamilyProperties(gpu,&n,families);uint32_t family=0;while(family<n && !(families[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))family++;if(family==n)return 2;
 float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
 const char *subset="VK_KHR_portability_subset";VkPhysicalDeviceFeatures enabled={.vertexPipelineStoresAndAtomics=VK_TRUE};
 VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=1,.ppEnabledExtensionNames=&subset,.pEnabledFeatures=&enabled};VkDevice dev;CHECK(vkCreateDevice(gpu,&di,NULL,&dev));VkQueue queue;vkGetDeviceQueue(dev,family,0,&queue);
 VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=256,.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_VERTEX_BUFFER_BIT};VkBuffer buffer;CHECK(vkCreateBuffer(dev,&bi,NULL,&buffer));
 VkMemoryRequirements req;vkGetBufferMemoryRequirements(dev,buffer,&req);VkPhysicalDeviceMemoryProperties mp;vkGetPhysicalDeviceMemoryProperties(gpu,&mp);unsigned type;
 for(type=0;type<mp.memoryTypeCount;type++)if((req.memoryTypeBits&(1u<<type)) && (mp.memoryTypes[type].propertyFlags&6)==6)break;
 if(type==mp.memoryTypeCount)return 2;VkMemoryAllocateInfo ma={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=type};VkDeviceMemory memory;CHECK(vkAllocateMemory(dev,&ma,NULL,&memory));CHECK(vkBindBufferMemory(dev,buffer,memory,0));uint32_t *mapped;CHECK(vkMapMemory(dev,memory,0,VK_WHOLE_SIZE,0,(void**)&mapped));mapped[16]=0x3f400000;mapped[32]=0x10203040;
 VkDescriptorSetLayoutBinding binding={.binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_VERTEX_BIT};VkDescriptorSetLayoutCreateInfo sli={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=1,.pBindings=&binding};VkDescriptorSetLayout sl;CHECK(vkCreateDescriptorSetLayout(dev,&sli,NULL,&sl));
 VkPipelineLayoutCreateInfo pli={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&sl};VkPipelineLayout layout;CHECK(vkCreatePipelineLayout(dev,&pli,NULL,&layout));
 VkDescriptorPoolSize ps={VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,20};VkDescriptorPoolCreateInfo dpi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=4,.poolSizeCount=1,.pPoolSizes=&ps};VkDescriptorPool pool;CHECK(vkCreateDescriptorPool(dev,&dpi,NULL,&pool));VkDescriptorSetAllocateInfo sa={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=pool,.descriptorSetCount=1,.pSetLayouts=&sl};VkDescriptorSet set;CHECK(vkAllocateDescriptorSets(dev,&sa,&set));VkDescriptorBufferInfo db={buffer,0,4};VkWriteDescriptorSet write={.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&db};vkUpdateDescriptorSets(dev,1,&write,0,NULL);
 VkSubpassDependency dependency={.srcSubpass=0,.dstSubpass=0,.srcStageMask=VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,.dstStageMask=VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT|VK_ACCESS_SHADER_READ_BIT,.dstAccessMask=VK_ACCESS_SHADER_WRITE_BIT|VK_ACCESS_SHADER_READ_BIT};
 VkSubpassDescription sub={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS};VkRenderPassCreateInfo ri={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.subpassCount=1,.pSubpasses=&sub,.dependencyCount=1,.pDependencies=&dependency};VkRenderPass pass;CHECK(vkCreateRenderPass(dev,&ri,NULL,&pass));VkFramebufferCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,.renderPass=pass,.width=16,.height=16,.layers=1};VkFramebuffer framebuffer;CHECK(vkCreateFramebuffer(dev,&fi,NULL,&framebuffer));
 VkShaderModuleCreateInfo smi={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=sizeof(code),.pCode=code};uint32_t typedCode[256];if(kind){smi.codeSize=make_typed_input(typedCode,kind);smi.pCode=typedCode;}VkShaderModule shader;CHECK(vkCreateShaderModule(dev,&smi,NULL,&shader));
 VkDescriptorSetLayoutBinding bindings2[9];for(unsigned i=0;i<9;i++){bindings2[i]=binding;bindings2[i].binding=i;}VkDescriptorSetLayoutCreateInfo sl2i=sli;sl2i.bindingCount=9;sl2i.pBindings=bindings2;VkDescriptorSetLayout sl2;CHECK(vkCreateDescriptorSetLayout(dev,&sl2i,NULL,&sl2));
 VkPipelineLayoutCreateInfo pl2i=pli;pl2i.pSetLayouts=&sl2;VkPipelineLayout layout2;CHECK(vkCreatePipelineLayout(dev,&pl2i,NULL,&layout2));
 VkDescriptorSetAllocateInfo sa2=sa;sa2.pSetLayouts=&sl2;VkDescriptorSet set2;CHECK(vkAllocateDescriptorSets(dev,&sa2,&set2));VkDescriptorBufferInfo db2={buffer,128,4};VkWriteDescriptorSet writes2[2]={write,write};writes2[0].dstSet=set2;writes2[1].dstSet=set2;writes2[1].dstBinding=8;writes2[1].pBufferInfo=&db2;vkUpdateDescriptorSets(dev,2,writes2,0,NULL);
 VkDescriptorSet missingSet,primeSet;CHECK(vkAllocateDescriptorSets(dev,&sa,&missingSet));CHECK(vkAllocateDescriptorSets(dev,&sa2,&primeSet));
 VkDescriptorBufferInfo missingOutput={buffer,4,4},primeOutput={buffer,8,4};VkWriteDescriptorSet missingWrite=write;missingWrite.dstSet=missingSet;missingWrite.pBufferInfo=&missingOutput;vkUpdateDescriptorSets(dev,1,&missingWrite,0,NULL);VkWriteDescriptorSet primeWrites[2]={writes2[0],writes2[1]};primeWrites[0].dstSet=primeSet;primeWrites[1].dstSet=primeSet;primeWrites[0].pBufferInfo=&primeOutput;vkUpdateDescriptorSets(dev,2,primeWrites,0,NULL);
 uint32_t second[256];VkShaderModuleCreateInfo sm2i=smi;sm2i.codeSize=make_second_shader(second);sm2i.pCode=second;VkShaderModule shader2;CHECK(vkCreateShaderModule(dev,&sm2i,NULL,&shader2));
 VkPipelineShaderStageCreateInfo stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_VERTEX_BIT,.module=shader,.pName="main"};
 VkVertexInputBindingDescription vb={0,16,VK_VERTEX_INPUT_RATE_VERTEX};VkVertexInputAttributeDescription va={12,0,VK_FORMAT_R32G32B32A32_SFLOAT,0};
 if(kind==1)va.format=VK_FORMAT_R32G32B32A32_SINT;if(kind==2)va.format=VK_FORMAT_R32G32B32A32_UINT;
 VkPipelineVertexInputStateCreateInfo vi={.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,.vertexBindingDescriptionCount=1,.pVertexBindingDescriptions=&vb,.vertexAttributeDescriptionCount=1,.pVertexAttributeDescriptions=&va};
 VkPipelineInputAssemblyStateCreateInfo ia={.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,.topology=VK_PRIMITIVE_TOPOLOGY_POINT_LIST};
 VkPipelineRasterizationStateCreateInfo raster={.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,.rasterizerDiscardEnable=VK_TRUE,.polygonMode=VK_POLYGON_MODE_FILL,.lineWidth=1};VkPipelineMultisampleStateCreateInfo ms={.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT};
 VkGraphicsPipelineCreateInfo pi={.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,.stageCount=1,.pStages=&stage,.pVertexInputState=&vi,.pInputAssemblyState=&ia,.pRasterizationState=&raster,.pMultisampleState=&ms,.layout=layout,.renderPass=pass};
 VkPipelineCacheCreateInfo pci={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};VkPipelineCache cache;CHECK(vkCreatePipelineCache(dev,&pci,NULL,&cache));
 VkCommandPoolCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=family};VkCommandPool commands;CHECK(vkCreateCommandPool(dev,&cpi,NULL,&commands));VkCommandBufferAllocateInfo ca={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=commands,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};VkCommandBuffer cmd;CHECK(vkAllocateCommandBuffers(dev,&ca,&cmd));
 int zero=getenv("MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS") && !strcmp(getenv("MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS"),"1");
 VkPipeline retainedMissing=VK_NULL_HANDLE;
 for(unsigned round=0;round<(kind ? 2u : 4u);round++) {
  int missing=round==1 || round==3;vi.vertexAttributeDescriptionCount=missing ? 0 : 1;vi.vertexBindingDescriptionCount=missing ? 0 : 1;
  stage.module=round==2 ? shader2 : shader;pi.layout=round==2 ? layout2 : layout;
  VkPipeline pipeline=VK_NULL_HANDLE;VkResult status=vkCreateGraphicsPipelines(dev,cache,1,&pi,NULL,&pipeline);printf("round=%u missing=%d create=%d\n",round,missing,status);fflush(stdout);
  if(missing && !zero) {if(status==VK_SUCCESS){puts("FAIL default unexpectedly accepted missing attribute");return 2;}continue;}
  CHECK(status);mapped[0]=mapped[1]=mapped[2]=0xdeadc0de;CHECK(vkResetCommandBuffer(cmd,0));VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};CHECK(vkBeginCommandBuffer(cmd,&begin));
  VkRenderPassBeginInfo rb={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,.renderPass=pass,.framebuffer=framebuffer,.renderArea={{0,0},{16,16}}};vkCmdBeginRenderPass(cmd,&rb,VK_SUBPASS_CONTENTS_INLINE);
  if(round==2 && retainedMissing) {
   VkDeviceSize vbOffset=64;
   vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,layout2,0,1,&primeSet,0,NULL);vkCmdBindVertexBuffers(cmd,0,1,&buffer,&vbOffset);vkCmdDraw(cmd,1,1,0,0);
   vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,retainedMissing);vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,layout,0,1,&missingSet,0,NULL);vkCmdDraw(cmd,1,1,0,0);
  }
  vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);VkDescriptorSet activeSet=round==2 ? set2 : set;vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pi.layout,0,1,&activeSet,0,NULL);VkDeviceSize offset=64;vkCmdBindVertexBuffers(cmd,0,1,&buffer,&offset);vkCmdDraw(cmd,1,1,0,0);vkCmdEndRenderPass(cmd);
  VkMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,.dstAccessMask=VK_ACCESS_HOST_READ_BIT};vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,NULL,0,NULL);CHECK(vkEndCommandBuffer(cmd));VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};CHECK(vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE));CHECK(vkQueueWaitIdle(queue));
  uint32_t expected=missing ? 0 : round==2 ? 0x2f603040 : 0x3f400000;printf("round=%u GPU readback expected=%08x actual=%08x\n",round,expected,mapped[0]);if(mapped[0]!=expected)return 2;if(round==2 && retainedMissing){printf("same-encoder outputs missing=%08x prime=%08x\n",mapped[1],mapped[2]);if(mapped[1]!=0 || mapped[2]!=0x2f603040)return 2;}if(round==1){retainedMissing=pipeline;}else{vkDestroyPipeline(dev,pipeline,NULL);}
 }
 if(retainedMissing)vkDestroyPipeline(dev,retainedMissing,NULL);
 vkDestroyShaderModule(dev,shader2,NULL);vkDestroyPipelineLayout(dev,layout2,NULL);vkDestroyDescriptorSetLayout(dev,sl2,NULL);
 vkDestroyCommandPool(dev,commands,NULL);vkDestroyPipelineCache(dev,cache,NULL);vkDestroyShaderModule(dev,shader,NULL);vkDestroyFramebuffer(dev,framebuffer,NULL);vkDestroyRenderPass(dev,pass,NULL);vkDestroyDescriptorPool(dev,pool,NULL);vkDestroyPipelineLayout(dev,layout,NULL);vkDestroyDescriptorSetLayout(dev,sl,NULL);vkUnmapMemory(dev,memory);vkDestroyBuffer(dev,buffer,NULL);vkFreeMemory(dev,memory,NULL);vkDestroyDevice(dev,NULL);vkDestroyInstance(instance,NULL);puts("PASS actual vertex-stage GPU writes and pipeline binding transitions");
}
