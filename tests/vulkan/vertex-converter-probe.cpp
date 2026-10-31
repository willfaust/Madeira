// SPDX-License-Identifier: MIT
#include "SPIRVToMSLConverter.h"
#include <cassert>
#include <cstdio>
using namespace mvk;
static const uint32_t vs[]={0x07230203,0x00010000,0,13,0,
 (2<<16)|17,1, (3<<16)|14,0,1,
 (7<<16)|15,0,10,0x6e69616d,0,7,8,
 (4<<16)|71,7,30,3, (4<<16)|71,8,11,0,
 (2<<16)|19,1, (3<<16)|22,2,32, (4<<16)|23,3,2,4,
 (4<<16)|32,4,1,3, (4<<16)|32,5,3,3, (3<<16)|33,6,1,
 (4<<16)|59,4,7,1, (4<<16)|59,5,8,3,
 (5<<16)|54,1,10,0,6, (2<<16)|248,11,
 (4<<16)|61,3,12,7, (3<<16)|62,8,12, (1<<16)|253, (1<<16)|56};

static SPIRVToMSLConversionConfiguration config(unsigned location){
 SPIRVToMSLConversionConfiguration c;c.options.entryPointStage=spv::ExecutionModelVertex;c.options.entryPointName="main";
 MSLShaderInterfaceVariable si;si.shaderVar.location=location;si.binding=0;c.shaderInputs.push_back(si);return c;
}
static void convert(SPIRVToMSLConversionConfiguration& c){
 SPIRVToMSLConverter compiler;compiler.setSPIRV(vs,sizeof(vs)/sizeof(*vs));SPIRVToMSLConversionResult result;
 bool ok=compiler.convert(c,result);if(!ok)std::puts(result.resultLog.c_str());assert(ok);
}
int main(){
 auto good=config(3);assert(!good.vertexInputsFullyCovered);convert(good);assert(good.vertexInputsFullyCovered);
 auto unused=config(3);MSLShaderInterfaceVariable si;si.shaderVar.location=0;si.binding=0;unused.shaderInputs.push_back(si);
 assert(good.matches(unused)); // ignored input must not recompile the MSL
 auto requiredMissing=config(0);assert(!good.matches(requiredMissing));convert(requiredMissing);assert(!requiredMissing.vertexInputsFullyCovered);assert(!requiredMissing.matches(good));
 auto empty=config(0);empty.shaderInputs.clear();convert(empty);assert(!empty.vertexInputsFullyCovered);assert(!empty.matches(good));
 auto differentFormat=config(3);differentFormat.shaderInputs[0].shaderVar.format=SPIRV_CROSS_NAMESPACE::MSL_SHADER_VARIABLE_FORMAT_UINT8;assert(!good.matches(differentFormat));
 auto loaded=good;loaded.vertexInputsFullyCovered=false;assert(!loaded.matches(unused));assert(loaded.matches(config(3)));
 std::puts("PASS: actual converter reflection and matching: covered, unused, missing, empty, format, conservative loaded hint");
}
