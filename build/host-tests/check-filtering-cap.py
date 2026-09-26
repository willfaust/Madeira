from pathlib import Path
import subprocess
import tempfile
r=Path(__file__).resolve().parents[2];t=Path(tempfile.mkdtemp());s=(r/'research/dxmt/src/d3d9/d3d9_device.cpp').read_text()
a=s.index('MTLD3D9Device::getOrCreateSampler(');b=s.index('\n}\n',a)+3
fn=s[a:b].replace('MTLD3D9Device::','Device::')
source=r'''#include <algorithm>
#include <cassert>
#include <cstdint>
#include <map>
#include <memory>
#include <iostream>
struct WMTSamplerInfo {uint32_t max_anisotroy;int filter;};
template<class T>using Rc=std::shared_ptr<T>;
struct Sampler {WMTSamplerInfo info;static Rc<Sampler> createSampler(int,const WMTSamplerInfo&i,float){return std::make_shared<Sampler>(Sampler{i});}};
using SamplerKey=std::pair<uint32_t,int>;
SamplerKey samplerKeyFromInfo(const WMTSamplerInfo&i){return {i.max_anisotroy,i.filter};}
struct Device {uint32_t m_anisotropyLimit=16;int m_metalDevice=0;std::map<SamplerKey,Rc<Sampler>>m_samplerCache;Rc<Sampler>getOrCreateSampler(const WMTSamplerInfo&);};
'''+ 'Rc<Sampler>\n'+fn+r'''
int main(){for(unsigned cap:{1u,2u,4u,8u,16u}){
 Device d;d.m_anisotropyLimit=cap;
 for(unsigned requested:{1u,2u,4u,8u,16u}){
  WMTSamplerInfo info{requested,7};auto sampler=d.getOrCreateSampler(info);
  assert(info.max_anisotroy==requested);assert(sampler->info.max_anisotroy==std::min(requested,cap));assert(sampler->info.filter==7);
  assert(d.getOrCreateSampler(info)==sampler);
  assert(d.getOrCreateSampler({requested,8})!=sampler);
 }
}
std::cout<<"PASS: filtering cap, unchanged guest state, uncapped default and effective descriptor cache keys\n";
}
'''
p=t/'ml1250-sampler.cpp';p.write_text(source);o=t/'ml1250-sampler'
subprocess.run(['g++','-std=c++20','-O1','-fsanitize=address,undefined',str(p),'-o',str(o)],check=True);subprocess.run([str(o)],check=True)
