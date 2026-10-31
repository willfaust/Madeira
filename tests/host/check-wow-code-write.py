#!/usr/bin/env python3
"""Run the staged SMC writer and real interval policy, including permission revocation."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
def function(s,marker):
 a=s.index(marker);return s[a:s.index('\n}',a)+2]
with tempfile.TemporaryDirectory() as t:
 d=Path(t)
 subprocess.run(['python3',str(root/'tools/build/stage-fex-compat.py'),'stage',str(d/'fex')],check=True)
 subprocess.run(['python3',str(root/'tools/build/stage-io-status-abi.py'),'stage',str(d/'wine')],check=True)
 module=(d/'fex/Source/Windows/WOW64/Module.cpp').read_text()
 tracker=(d/'fex/Source/Windows/Common/InvalidationTracker.cpp').read_text()
 virtual=(d/'wine/dlls/wow64/virtual.c').read_text()
 # Use FEX's actual interval-list algorithm; substitute only its allocator.
 stub=d/'FEXCore/fextl';stub.mkdir(parents=True)
 (stub/'vector.h').write_text('#include <vector>\nnamespace fextl {template<class T> using vector=std::vector<T>;}\n')
 source=r'''
#include <cassert>
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <atomic>
#include <mutex>
#include <shared_mutex>
#include <algorithm>
#include <limits>
#include <thread>
#include <chrono>
#include <cstring>
#include <FEXCore/Utils/IntervalList.h>
using ULONG=uint32_t;using SIZE_T=size_t;using NTSTATUS=int32_t;using HANDLE=void*;
#define WINAPI
#define __declspec(x)
#define PAGE_NOACCESS 1
#define PAGE_READONLY 2
#define PAGE_READWRITE 4
#define PAGE_WRITECOPY 8
#define PAGE_EXECUTE 0x10
#define PAGE_EXECUTE_READ 0x20
#define PAGE_EXECUTE_READWRITE 0x40
#define PAGE_EXECUTE_WRITECOPY 0x80
#define PAGE_GUARD 0x100
#define NtCurrentProcess() ((void*)(intptr_t)-1)
namespace FEXCore::Utils {constexpr uint64_t FEX_PAGE_SIZE=4096,FEX_PAGE_MASK=~4095ull;}
namespace LogMan::Msg {template<class... T> void DFmt(T...){ } template<class... T> void EFmt(T...){ }}
class CodeMutex {
 std::mutex m; static thread_local bool held;
public:
 void lock(){assert(!held);m.lock();held=true;}
 void unlock(){assert(held);held=false;m.unlock();}
 bool IosHeldExclusiveByThisThread()const{return held;}
};thread_local bool CodeMutex::held=false;
struct Context {CodeMutex mutex;CodeMutex& GetCodeInvalidationMutex(){return mutex;}} context;
static Context* CTX=&context;static std::mutex ThreadCreationMutex;
namespace GuestWindow {
 constexpr uint64_t Base=0x500000000;
 bool Contains(uint64_t a){return a>=Base&&a-Base<0x100000000;}
}
static bool initialised=true;
struct TLS {void* ThreadStateIfInitialised(){return initialised?&context:nullptr;}};
static TLS GetTLS(){return {};}
static unsigned GetCurrentThreadId(){return 0x68;}
static ULONG permissions[8];static unsigned protects,invalidations,writes;
static unsigned char storage[8*4096];
static bool fail_write,fail_protect,expect_locked;static std::atomic<bool> compiler_started,compiler_done;
static NTSTATUS NtProtectVirtualMemory(HANDLE p,void** a,SIZE_T* n,ULONG prot,ULONG* old){
 assert(p==NtCurrentProcess());uint64_t start=(uintptr_t)*a-GuestWindow::Base,end=start+*n;
 assert(start<sizeof(storage)&&end<=sizeof(storage));protects++;
 if(fail_protect)return NTSTATUS(0xc0000022u);
 *old=permissions[start/4096];for(uint64_t off=start&~4095ull;off<end;off+=4096)permissions[off/4096]=prot;
 return 0;
}
static NTSTATUS NtWriteVirtualMemory(HANDLE p,void* a,const void* b,SIZE_T n,SIZE_T* written){
 writes++;if(written)*written=0;
 if(expect_locked)assert(context.mutex.IosHeldExclusiveByThisThread());
 if(p!=NtCurrentProcess()&&p!=(void*)8)return NTSTATUS(0xc0000022u);
 uint64_t start=(uintptr_t)a-GuestWindow::Base;if(start>sizeof(storage)||n>sizeof(storage)-start)return NTSTATUS(0xc0000005u);
 if(fail_write)return NTSTATUS(0x8000000du);
 for(uint64_t off=start&~4095ull;off<start+n;off+=4096){
  ULONG prot=permissions[off/4096];if((prot&PAGE_GUARD)||!(prot&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)))return NTSTATUS(0xc0000005u);
 }
 if(compiler_started.load()){
  // A competing compiler cannot publish a block while the actual write runs.
  std::this_thread::yield();assert(!compiler_done.load());
 }
 if(n)memcpy(storage+start,b,n);if(written)*written=n;return 0;
}
class OwnedMutex:public std::shared_mutex {public:bool HeldByThisThread()const{return false;}};
class InvalidationTracker {
public:
 uint64_t GuestBase=GuestWindow::Base;bool DEPDisabled=false,SMCDetectionDisabled=false;
 OwnedMutex IntervalsLock;std::atomic<unsigned> NestedNotificationSkips{},HotPagesUsed{};
 FEXCore::IntervalList<uint64_t> XIntervals,RWXIntervals,DEPPromotedIntervals;
 void InvalidateIntervalInternal(uint64_t,uint64_t){invalidations++;}
 void InvalidateIntervalInternalLocked(uint64_t,uint64_t){assert(context.mutex.IosHeldExclusiveByThisThread());invalidations++;}
 bool IsHotSMCPage(uint64_t)const{return false;}
 void HandleMemoryProtectionNotification(uint64_t,uint64_t,ULONG);
 ULONG GetTrapProt(uint64_t)const;ULONG GetUntrapProt(uint64_t)const;
 bool ProtectRWXIntervalsInternal(uint64_t,uint64_t,bool);bool BeginUntrackedWriteLocked(uint64_t,uint64_t);
} tracker;
static InvalidationTracker* InvalidationTracker=&tracker;
''' + '\n'.join(function(tracker,x) for x in ['static bool ProtHasExec(', 'static bool ProtIsReadable(', 'static bool ProtIsWritable(',
 'void InvalidationTracker::HandleMemoryProtectionNotification(', 'ULONG InvalidationTracker::GetTrapProt(',
 'ULONG InvalidationTracker::GetUntrapProt(', 'bool InvalidationTracker::ProtectRWXIntervalsInternal(',
 'bool InvalidationTracker::BeginUntrackedWriteLocked(']) + '\n' + function(module,'extern "C" __declspec(dllexport) NTSTATUS WINAPI MadeiraBTCpuWriteMemory(') + r'''
static void protect_guest(unsigned page,ULONG prot){
 permissions[page]=prot;tracker.HandleMemoryProtectionNotification(GuestWindow::Base+page*4096,4096,prot);
}
static void recompile(unsigned page){tracker.ProtectRWXIntervalsInternal(GuestWindow::Base+page*4096,4096,false);}
int main(){
 const unsigned char hook[12]={0xb8,0x28,0,0,0,0xba,0x18,0xc0,0xd9,0x6a,0xff,0xe2};
 void* target=(void*)(GuestWindow::Base+4096+0x6a0);size_t written=123;
 protect_guest(1,PAGE_EXECUTE_READ);protect_guest(1,PAGE_EXECUTE_WRITECOPY);
 recompile(1);assert(permissions[1]==PAGE_EXECUTE_READ);
 // Negative control: this is the old failure after a successful temporary protect.
 assert(uint32_t(NtWriteVirtualMemory(NtCurrentProcess(),target,hook,12,&written))==0xc0000005u&&!written);
 unsigned before=invalidations;expect_locked=true;
 assert(!MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,12,&written));
 assert(written==12&&!memcmp(storage+4096+0x6a0,hook,12)&&invalidations>before);
 // Restore must revoke the interval: a subsequent direct write gets no permission.
 protect_guest(1,PAGE_EXECUTE_READ);assert(!tracker.RWXIntervals.Query(GuestWindow::Base+4096).Enclosed);
 before=protects;assert(uint32_t(MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,12,&written))==0xc0000005u&&!written);
 assert(protects==before&&permissions[1]==PAGE_EXECUTE_READ);
 // Guest guards cannot be cleared by untrapping. A neighbouring RWX 4 KB
 // page cannot authorize the RX sibling on the same iOS 16 KB host page.
 protect_guest(1,PAGE_EXECUTE_READWRITE|PAGE_GUARD);before=protects;
 assert(uint32_t(MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,12,&written))==0xc0000005u&&protects==before);
 protect_guest(1,PAGE_EXECUTE_READWRITE);recompile(1);protect_guest(2,PAGE_EXECUTE_READ);
 unsigned char prior[12];memcpy(prior,storage+8190,12);
 assert(uint32_t(MadeiraBTCpuWriteMemory(NtCurrentProcess(),(void*)(GuestWindow::Base+8190),hook,12,&written))==0xc0000005u);
 assert(!memcmp(prior,storage+8190,12)&&permissions[2]==PAGE_EXECUTE_READ);
 // Permission-restore failures and source failures propagate without stranded locks.
 fail_write=true;assert(uint32_t(MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,12,&written))==0x8000000du&&!written);fail_write=false;
 recompile(1);fail_protect=true;assert(uint32_t(MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,12,&written))==0xc0000005u);fail_protect=false;
 // Existing writable ClipCursor patch still succeeds. VM_WRITE is rechecked
 // by the native writer; the private backend does not substitute a self handle.
 protect_guest(1,PAGE_EXECUTE_WRITECOPY);assert(!MadeiraBTCpuWriteMemory((void*)8,target,hook,5,&written)&&written==5);
 assert(uint32_t(MadeiraBTCpuWriteMemory((void*)9,target,hook,5,&written))==0xc0000022u&&!written);
 assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
 assert(!context.mutex.IosHeldExclusiveByThisThread());
 // An already owned code lock stays owned on return (no recursive lock).
 context.mutex.lock();assert(!MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,5,&written));assert(context.mutex.IosHeldExclusiveByThisThread());context.mutex.unlock();
 // A real competing compiler is blocked until the writer finishes.
 context.mutex.lock();std::thread compiler([]{compiler_started=true;std::scoped_lock l(context.mutex);compiler_done=true;});
 while(!compiler_started.load())std::this_thread::yield();
 assert(!MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,5,&written));context.mutex.unlock();compiler.join();assert(compiler_done);compiler_started=false;
 // Non-window and uninitialised calls never touch the tracker.
 expect_locked=false;before=protects;assert(uint32_t(MadeiraBTCpuWriteMemory(NtCurrentProcess(),(void*)0x10000,hook,5,&written))==0xc0000005u);
 initialised=false;assert(!MadeiraBTCpuWriteMemory(NtCurrentProcess(),target,hook,5,&written));assert(protects==before);
 puts("PASS actual staged SMC write: old ntdll patch failure reproduced, tracked code untrapped/invalidation locked, RX restoration revokes writes, guards/4KB siblings/source/protect failures/handle rights retain rejection, ClipCursor succeeds, competing compiler excluded");
}
'''
 src=d/'check.cpp';src.write_text(source);exe=d/'check'
 compiler=os.environ.get('CXX','c++')
 version=subprocess.check_output([compiler,'--version'],text=True)
 # The pinned FEX header names a member Interval as well as its type. GCC 14
 # diagnoses this legal-for-Clang spelling; keep the production algorithm intact.
 portability=[] if 'clang' in version.lower() else ['-Wno-changes-meaning']
 subprocess.run([compiler,'-std=c++20','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-Wno-unused-function',*portability,'-fsanitize=address,undefined','-fno-sanitize-recover=all','-pthread','-I'+str(d),'-I'+str(root/'FEX/FEXCore/include'),str(src),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
 # Verify the real consumer routes only the current process to the backend;
 # every call still enters the unmodified native NtWriteVirtualMemory policy.
 fn=function(virtual,'NTSTATUS WINAPI wow64_NtWriteVirtualMemory(')
 assert 'pMadeiraBTCpuWriteMemory && RtlIsCurrentProcess( process )' in fn
 assert 'else status = NtWriteVirtualMemory( process, addr, buffer, size, &ret_size );' in fn
 assert fn.index('retarget_ptr(')<fn.index('pMadeiraBTCpuWriteMemory &&')
 syscall=(d/'wine/dlls/wow64/syscall.c').read_text()
 assert 'GET_PTR( MadeiraBTCpuWriteMemory );' in syscall and 'XLATE_PTR( MadeiraBTCpuWriteMemory );' in syscall
