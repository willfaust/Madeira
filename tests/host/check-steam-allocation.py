#!/usr/bin/env python3
"""Execute downstream checked FEX initialization and Wine's arena/breakpoint policies."""
from pathlib import Path
import importlib.util
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]

def body(src, marker):
    start = src.index(marker)
    brace = src.index('{', start)
    depth = 0
    for token in re.finditer(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', src[brace:], re.S):
        if token.group() == '{': depth += 1
        elif token.group() == '}':
            depth -= 1
            if not depth: return src[start:brace + token.end()]
    raise AssertionError(marker)

def run(code, cpp=False):
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / ('check.cpp' if cpp else 'check.c'); p.write_text(code)
        exe = Path(tmp) / 'check'
        subprocess.run([os.environ.get('CXX' if cpp else 'CC', 'c++' if cpp else 'cc'),
                        '-std=c++20' if cpp else '-std=gnu11', '-O1', '-g', '-pthread',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-I'+str(root/'build/ntdll-unix'), str(p), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

with tempfile.TemporaryDirectory() as tmp:
    target = Path(tmp)
    subprocess.run(['python3', str(root/'tools/build/stage-fex-compat.py'), 'stage', str(target)], check=True)
    s = (target/'Source/Windows/WOW64/Module.cpp').read_text()
    fn = body(s, 'extern "C" __declspec(dllexport) NTSTATUS WINAPI MadeiraBTCpuThreadInit()')
    legacy = body(s, 'void BTCpuThreadInit()')
    assert 'NTSYSAPI NTSTATUS NTAPI NtTerminateThread(HANDLE ThreadHandle, NTSTATUS ExitStatus);' in s
    protect = body((target/'FEXCore/include/FEXCore/Utils/AllocatorHooks.h').read_text(), 'inline bool VirtualProtect(')
    run(r'''
#include <cassert>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <new>
#include <unordered_map>
#define __declspec(x)
#define WINAPI
using NTSTATUS=int32_t; using DWORD=unsigned long;
static int failure, crt, destroyed, gdts, fronts, stacks;
static std::mutex ThreadCreationMutex;
namespace LogMan::Msg { template<class... T> void EFmt(const char*, T...) {} }
namespace GuestWindow { static uint64_t Base=0x400000000; }
namespace FEXCore::Core {
struct CPUState {
 struct gdt_segment {
  int L{}, D{};
  static void* operator new[](size_t n, const std::nothrow_t&) noexcept { if(failure==3)return nullptr; gdts++; return std::calloc(1,n); }
  static void operator delete[](void* p) noexcept { gdts--; std::free(p); }
 };
 static constexpr int SEGMENT_ARRAY_INDEX_GDT=0, SEGMENT_ARRAY_INDEX_LDT=1;
 gdt_segment* segment_arrays[2]{}; uint64_t cs_idx{}, cs_cached{};
 static void SetGDTBase(gdt_segment*, int) {} static void SetGDTLimit(gdt_segment*, unsigned) {}
 static uint64_t CalculateGDTBase(gdt_segment&) { return 0; }
};
struct CpuStateFrame { CPUState State; };
struct InternalThreadState { CpuStateFrame* CurrentFrame{}; void* FrontendPtr{}; void* ThreadStats{}; };
}
using ThreadState=FEXCore::Core::InternalThreadState;
struct FrontendThreadData {
 static void* operator new(size_t n, const std::nothrow_t&) noexcept { if(failure==4)return nullptr; fronts++;return std::calloc(1,n); }
 static void operator delete(void* p) noexcept {fronts--;std::free(p);}
};
static ThreadState* tls_thread;
struct TLSInfo {
 void* TEB{}; unsigned ThreadStateSlot=14;
 uint64_t RawThreadState() const{return reinterpret_cast<uint64_t>(tls_thread);}
 ::ThreadState*& ThreadState() const {return tls_thread;}
 std::atomic<unsigned>& ControlWord() const {static std::atomic<unsigned> c{};return c;}
};
static TLSInfo GetTLS(){return {};}
namespace ControlBits { static constexpr unsigned WOW_CPU_AREA_DIRTY=1; }
static unsigned GetCurrentThreadId(){return 0x248;}
namespace FEX::Windows {
void InitCRTThread(){crt++;} void DeinitCRTThread(){crt--;}
namespace CallRetStack { bool InitializeThread(::ThreadState*) {if(failure==5||failure==6)return false; stacks++;return true;} }
}
struct Context {
 ThreadState* CreateThread(int,int){if(failure==1)return nullptr;auto* t=new ThreadState; if(failure!=2)t->CurrentFrame=new FEXCore::Core::CpuStateFrame;return t;}
 void DestroyThread(ThreadState* t){assert(!tls_thread);destroyed++;delete t->CurrentFrame;delete t;}
} context;
static Context* CTX=&context;
static std::unordered_map<unsigned, ThreadState*> Threads;
struct Stats {void* AllocateSlot(unsigned){return nullptr;}}; static Stats* StatAllocHandler=nullptr;
''' + fn + r'''
struct Retired { NTSTATUS status; };
static void* GetCurrentThread(){return nullptr;}
static NTSTATUS NtTerminateThread(void*, NTSTATUS status){
 assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
 assert(!tls_thread && !crt && Threads.empty() && !gdts && !fronts);
 throw Retired{status};
}
''' + legacy + r'''
namespace FEXCore::Allocator {
enum class ProtectOptions { None=0, Read=1, Write=2, Exec=4 };
constexpr ProtectOptions operator|(ProtectOptions a, ProtectOptions b){return ProtectOptions(unsigned(a)|unsigned(b));}
}
#define PAGE_NOACCESS 1
#define PAGE_READONLY 2
#define PAGE_READWRITE 4
#define PAGE_EXECUTE_READ 0x20
#define PAGE_EXECUTE_READWRITE 0x40
#define LOGMAN_MSG_A_FMT(...)
static int protect_result, old_output;
static int VirtualProtect(void*,size_t,DWORD,DWORD* old){assert(old);*old=0x20;old_output++;return protect_result;}
namespace FEXCore::Allocator {
''' + protect + r'''
}
int main(){
 for(failure=1;failure<=6;failure++){
  int before=destroyed;
  assert(uint32_t(MadeiraBTCpuThreadInit())==0xc0000017u);
  assert(!crt && !tls_thread && Threads.empty() && !gdts && !fronts && !stacks);
  assert(destroyed==before+(failure!=1));
  assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
 }
 failure=1;bool retired=false;
 try { BTCpuThreadInit(); } catch(const Retired& r) {retired=true;assert(uint32_t(r.status)==0xc0000017u);}
 assert(retired);
 failure=0;assert(!MadeiraBTCpuThreadInit());assert(tls_thread && Threads.size()==1 && crt==1 && gdts==1 && fronts==1 && stacks==1);
 assert(ThreadCreationMutex.try_lock());ThreadCreationMutex.unlock();
 auto* t=tls_thread; tls_thread=nullptr; Threads.clear(); delete static_cast<FrontendThreadData*>(t->FrontendPtr);
 delete[] t->CurrentFrame->State.segment_arrays[0];context.DestroyThread(t);FEX::Windows::DeinitCRTThread();
 protect_result=1;assert(FEXCore::Allocator::VirtualProtect(nullptr,4096,FEXCore::Allocator::ProtectOptions::None));
 protect_result=0;assert(!FEXCore::Allocator::VirtualProtect(nullptr,4096,FEXCore::Allocator::ProtectOptions::None));assert(old_output==2);
}
''', cpp=True)
print('PASS: actual FEX checked init rejects ThreadState/frame/GDT/frontend/call-ret failures, cleans allocations, leaves TLS unpublished and unlocks; successful initialization publishes complete state')
print('PASS: actual Windows protection wrapper supplies required output and reports success/failure correctly')

v=(root/'build/ntdll-unix/virtual_ios.c').read_text()
s=(root/'build/ntdll-unix/signal_arm64_ios.c').read_text()
run(r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uintptr_t ULONG_PTR;
typedef struct {struct{uint64_t Self;} Tib; uint64_t Peb;uint64_t TlsSlots[64];} TEB;
static uint64_t wow=0x400000000, ios_fex_arena_base_unix=0xb40000000,ios_fex_arena_end_unix=0xd40000000;
static ULONG_PTR ios_wow_base(void){return wow;}
static TEB teb;static uint64_t frame[16],fex;static uint32_t insn;static int owned=1;
static uint64_t owner=0x400310000;
static ULONG_PTR ios_wow_base_for_peb(void* p){return (uintptr_t)p==owner?wow:0;}
int ios_fex_code_owner_matches(uintptr_t pc,void* p){return owned&&pc==(uintptr_t)&insn&&(uintptr_t)p==owner;}
static int ios_fault_read(uint64_t a,void* out,size_t n){
 const uintptr_t lo[]={(uintptr_t)&teb,(uintptr_t)frame,(uintptr_t)&fex,(uintptr_t)&insn};
 const size_t size[]={sizeof(teb),sizeof(frame),sizeof(fex),sizeof(insn)};
 for(unsigned i=0;i<4;i++) if(a>=lo[i]&&a-lo[i]<=size[i]&&n<=size[i]-(a-lo[i])){memcpy(out,(void*)(uintptr_t)a,n);return 1;}
 return 0;
}
''' + r'''
static int ios_g32_read(uint64_t a,void* out,size_t n){return ios_fault_read(a,out,n);}
#include "guest32_origin.h"
''' + body(v,'static int fex_arena_covers(') + chr(10) + body(s,'static int ios_verified_guest_breakpoint(') + r'''
int main(){
 assert(fex_arena_covers((void*)0xc00000000,(void*)0xeffffffff));
 assert(fex_arena_covers((void*)0xc00000000,(void*)0xf00000000));
 assert(!fex_arena_covers(0,(void*)0xf00000000));
 assert(!fex_arena_covers((void*)0xc00000001,(void*)0xf00000000));
 wow=0;assert(!fex_arena_covers((void*)0xc00000000,(void*)0xf00000000));wow=0x400000000;
 ios_fex_arena_base_unix=0xf40000000;ios_fex_arena_end_unix=0xf80000000;
 assert(!fex_arena_covers((void*)0xc00000000,(void*)0xf00000000));
 teb.Tib.Self=(uintptr_t)&teb;teb.Peb=owner;teb.TlsSlots[14]=(uintptr_t)&fex;fex=(uintptr_t)frame;
 frame[3]=0x6df3def4;frame[8]=0x403fa24;insn=0xd4200000;
 assert(ios_verified_guest_breakpoint((uintptr_t)&insn,(uintptr_t)frame,(uintptr_t)&teb));
 owned=0;assert(!ios_verified_guest_breakpoint((uintptr_t)&insn,(uintptr_t)frame,(uintptr_t)&teb));owned=1;
 insn=0xd43e01a0;assert(!ios_verified_guest_breakpoint((uintptr_t)&insn,(uintptr_t)frame,(uintptr_t)&teb));insn=0xd4200000;
 assert(!ios_verified_guest_breakpoint((uintptr_t)&insn,(uintptr_t)frame+8,(uintptr_t)&teb));
 frame[8]=0;assert(!ios_verified_guest_breakpoint((uintptr_t)&insn,(uintptr_t)frame,(uintptr_t)&teb));
}
''')
print('PASS: exact legacy WOW64 band can use only its authoritative overlapping FEX arena; generic/native/foreign bands excluded')
print('PASS: guest breakpoint classification requires owned FEX code, correct TEB/TLS14/frame and valid guest state; state is never modified')
# Production Wine uses the checked return before fetching context or simulating.
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(['python3',str(root/'tools/build/stage-io-status-abi.py'),'stage',tmp],check=True)
    w=(Path(tmp)/'dlls/wow64/syscall.c').read_text()
    fn=body(w,'static void thread_init(void)')
    assert fn.index('pMadeiraBTCpuThreadInit()') < fn.index('NtTerminateThread(') < fn.index('pBTCpuGetContext(')
    assert 'XLATE_PTR( MadeiraBTCpuThreadInit );' in w
print('PASS: staged Wine resolves/translates checked ABI and retires failed native thread before guest context or simulation')

# The build applies only the maintained overlay and restores exact original bytes.
spec=importlib.util.spec_from_file_location('fex_stage',root/'tools/build/stage-fex-compat.py')
stager=importlib.util.module_from_spec(spec);spec.loader.exec_module(stager)
with tempfile.TemporaryDirectory() as tmp:
    source=Path(tmp)/'source'; state=Path(tmp)/'state';state.mkdir()
    originals={}
    for name in stager.FILES:
        p=source/name;p.parent.mkdir(parents=True,exist_ok=True)
        data=(root/'FEX'/name).read_bytes();p.write_bytes(data);originals[name]=data
    subprocess.run(['git','init','-q',str(source)],check=True)
    subprocess.run(['git','-C',str(source),'add','.'],check=True)
    subprocess.run(['git','-C',str(source),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'],check=True)
    stager.apply(state,source)
    p=source/stager.FILES[0];patched=p.read_bytes();p.write_bytes(patched+b'/* concurrent edit */')
    try: stager.restore(state)
    except SystemExit: pass
    else: raise AssertionError('build-time source edit overwritten')
    p.write_bytes(patched);stager.restore(state)
    assert all((source/n).read_bytes()==data for n,data in originals.items())
print('PASS: FEX overlay restoration preserves exact pinned inputs and refuses concurrent edits')
