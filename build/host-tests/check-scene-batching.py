from pathlib import Path
import subprocess,os
import tempfile
r=Path(__file__).resolve().parents[2];t=Path(tempfile.mkdtemp());s=(r/'research/dxmt/src/d3d9/d3d9_device.cpp').read_text()
def body(name):
 p=s.index('MTLD3D9Device::'+name+'(');a=s.index('{',p);n=1;b=a+1
 while n:
  n+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
stub=r'''#include <cassert>
#include <cstdint>
#include <vector>
#include <string>
#include <algorithm>
#include <map>
#include <iostream>
using HRESULT=int;
#define D3D_OK 0
#define D3DERR_INVALIDCALL -1
#define D3D9_CENSUS(x)
struct D9DeviceLock {};
namespace WMT {int MakeAutoreleasePool(){return 0;}}
namespace str {template<class...T>std::string format(T...){return "";}}
struct Logger {static void warn(const std::string&) {}};
struct Device {
 bool m_inScene=false,m_batchScenes=true;
 uint64_t m_batchedSceneEnds=0;
 std::vector<int>m_pendingOps,submitted;
 bool clear=false;int flushes=0,clears=0;
 D9DeviceLock LockDevice(){return {};}
 void flushOpenWork(){if(clear){++clears;clear=false;}}
 void FlushDrawBatch(){if(m_pendingOps.empty())return;flushOpenWork();++flushes;submitted.insert(submitted.end(),m_pendingOps.begin(),m_pendingOps.end());m_pendingOps.clear();}
 HRESULT BeginScene();HRESULT EndScene();
};
'''
main=r'''
int main(){
 for(bool enabled:{false,true}){
  Device d;d.m_batchScenes=enabled;
  assert(d.EndScene()==D3DERR_INVALIDCALL);
  for(int i=0;i<257;++i){
   assert(d.BeginScene()==D3D_OK);assert(d.BeginScene()==D3DERR_INVALIDCALL);
   d.m_pendingOps.push_back(i);assert(d.EndScene()==D3D_OK);
   assert(d.m_pendingOps.size()<256);
  }
  // The unchanged Present drain must publish all retained work in FIFO order.
  d.FlushDrawBatch();d.flushOpenWork();assert(d.submitted.size()==257);
  for(int i=0;i<257;++i)assert(d.submitted[i]==i);
  assert(d.flushes==(enabled?2:257));
  d.clear=true;assert(d.BeginScene()==D3D_OK);assert(d.EndScene()==D3D_OK);assert(d.clears==1);
  // Query/readback hazard drains between scene pairs retain ordering.
  assert(d.BeginScene()==0);d.m_pendingOps.push_back(300);assert(d.EndScene()==0);
  d.FlushDrawBatch();assert(d.submitted.back()==300);
 }
 std::cout<<"PASS: scene pairing, 256-op bound, FIFO, clear-only drain, hazard drain and rollback\n";
}
'''
p=t/'ml1250-batching.cpp';p.write_text(stub+'HRESULT Device::BeginScene()'+body('BeginScene')+'\nHRESULT Device::EndScene()'+body('EndScene')+main)
o=t/'ml1250-batching';subprocess.run(['g++','-std=c++20','-O1','-fsanitize=address,undefined',str(p),'-o',str(o)],check=True);subprocess.run([str(o)],check=True)
# Verify real ordering boundaries were retained in production sources.
q=(r/'research/dxmt/src/d3d9/d3d9_query.cpp').read_text();p=(r/'research/dxmt/src/d3d9/d3d9_swapchain.cpp').read_text()
assert q.count('m_device->FlushDrawBatch();')>=4
assert 'm_device->FlushDrawBatch();\n  m_device->flushOpenWork();' in p
assert 'FlushDrawBatch();\n  flushOpenWork();\n  emitCmdbufTailSignal();' in s
print('PASS: production query, Present and forced submission drains preserved')
