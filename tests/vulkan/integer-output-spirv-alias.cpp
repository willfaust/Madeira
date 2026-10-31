// SPDX-License-Identifier: MIT
// Build with MoltenVKShaderConverter + SPIRV-Tools include directories and
// libSPIRVTools.a. Checks a valid shader is rejected before an invalid rewrite.
#include "SPIRVIntegerFragmentOutputs.h"
#include <spirv-tools/libspirv.hpp>
#include <iostream>
int main(){
 const std::string assembly=R"(OpCapability Shader
OpMemoryModel Logical GLSL450
OpEntryPoint Fragment %main "main" %out
OpExecutionMode %main OriginUpperLeft
OpDecorate %out Location 0
%void = OpTypeVoid
%fn = OpTypeFunction %void
%float = OpTypeFloat 32
%output = OpTypePointer Output %float
%local = OpTypePointer Function %float
%zero = OpConstant %float 0
%out = OpVariable %output Output
%main = OpFunction %void None %fn
%label = OpLabel
%tmp = OpVariable %local Function
OpStore %tmp %zero
OpCopyMemory %out %tmp
OpReturn
OpFunctionEnd
)";
 spvtools::SpirvTools tools(SPV_ENV_VULKAN_1_1);std::vector<uint32_t> input,output;std::string error;
 tools.SetMessageConsumer([](spv_message_level_t,const char*,const spv_position_t&,const char* message){std::cerr<<message<<"\n";});
 for(unsigned direction=0;direction<2;direction++) {
  auto code=assembly;
  if(direction)code.replace(code.find("OpCopyMemory %out %tmp"),std::string("OpCopyMemory %out %tmp").size(),"OpCopyMemory %tmp %out");
  if(!tools.Assemble(code,&input)||!tools.Validate(input))return 1;
  if(mvk::integerFragmentOutputs(input,1,0,output,error)||error.empty())return 2;
 }
 std::cout<<"PASS valid OpCopyMemory input rejected safely for source and destination pointers\n";
}
