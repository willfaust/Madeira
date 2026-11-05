/* Generic Windows event/address handoff, no game-specific checks.
 * SPDX-License-Identifier: MIT */
#include <windows.h>
#include <stdio.h>
typedef BOOL (WINAPI *wait_address_fn)(volatile VOID *, PVOID, SIZE_T, DWORD);
typedef VOID (WINAPI *wake_address_fn)(PVOID);
struct handoff {
 HANDLE ready, go, done;
 volatile LONG phase;
 volatile CHAR byte_phase;
 int failed;
 wait_address_fn wait_address;
 wake_address_fn wake_address;
};
static DWORD WINAPI worker(void *opaque) {
 struct handoff *s=opaque;
 if(WaitForSingleObject(s->go,5000)!=WAIT_OBJECT_0){s->failed=1;return 2;}
 for(LONG step=1;step<=64;step++) {
  LONG expected=(step-1)*2;
  InterlockedExchange(&s->phase,expected+1);
  s->wake_address((void*)&s->phase);
  if(step==1)SetEvent(s->ready);
  while(InterlockedCompareExchange(&s->phase,0,0)==expected+1) {
   LONG compare=expected+1;
   if(!s->wait_address(&s->phase,&compare,sizeof(compare),5000)) {
    if(GetLastError()!=ERROR_TIMEOUT || InterlockedCompareExchange(&s->phase,0,0)==compare) {
     s->failed=1;return 2;
    }
   }
  }
 }
 __atomic_exchange_n(&s->byte_phase,1,__ATOMIC_SEQ_CST);
 s->wake_address((void*)&s->byte_phase);
 while(__atomic_load_n(&s->byte_phase,__ATOMIC_SEQ_CST)==1) {
  CHAR expected=1;
  if(!s->wait_address(&s->byte_phase,&expected,1,5000) &&
     __atomic_load_n(&s->byte_phase,__ATOMIC_SEQ_CST)==1){s->failed=1;return 2;}
 }
 SetEvent(s->done);return 0;
}
int windows_handoff_test(void) {
 HMODULE base=GetModuleHandleA("kernelbase.dll");
 struct handoff s={0};
 s.wait_address=(wait_address_fn)GetProcAddress(base,"WaitOnAddress");
 s.wake_address=(wake_address_fn)GetProcAddress(base,"WakeByAddressAll");
 if(!s.wait_address || !s.wake_address){puts("[win-handoff] FAIL address API unavailable");return 2;}
 s.ready=CreateEventA(NULL,TRUE,FALSE,NULL);
 s.go=CreateEventA(NULL,FALSE,FALSE,NULL);
 s.done=CreateEventA(NULL,TRUE,FALSE,NULL);
 if(!s.ready || !s.go || !s.done)return 2;
 HANDLE thread=CreateThread(NULL,0,worker,&s,0,NULL);if(!thread)return 2;
 puts("[win-handoff] BEGIN event + atomic/address handoff64");
 SetEvent(s.go);
 HANDLE first[2]={s.ready,s.done};
 if(WaitForMultipleObjects(2,first,FALSE,5000)!=WAIT_OBJECT_0)return 2;
 for(LONG step=1;step<=64;step++) {
  LONG wanted=step*2-1;
  while(InterlockedCompareExchange(&s.phase,0,0)!=wanted) {
   LONG observed=InterlockedCompareExchange(&s.phase,0,0);
   if(observed==wanted)break;
   if(!s.wait_address(&s.phase,&observed,sizeof(observed),5000)) {
    if(GetLastError()!=ERROR_TIMEOUT || InterlockedCompareExchange(&s.phase,0,0)==observed) {
     printf("[win-handoff] FAIL step=%ld phase=%ld error=%lu\n",(long)step,(long)s.phase,(unsigned long)GetLastError());return 2;
    }
   }
  }
  InterlockedExchange(&s.phase,wanted+1);
  s.wake_address((void*)&s.phase);
 }
 ULONGLONG deadline=GetTickCount64()+5000;
 while(__atomic_load_n(&s.byte_phase,__ATOMIC_SEQ_CST)!=1) {
  if(GetTickCount64()>=deadline){puts("[win-handoff] FAIL byte/yield handoff");return 2;}
  Sleep(0);
 }
 __atomic_exchange_n(&s.byte_phase,2,__ATOMIC_SEQ_CST);s.wake_address((void*)&s.byte_phase);
 HANDLE both[2]={s.done,thread};DWORD result=WaitForMultipleObjects(2,both,TRUE,5000);
 if(result!=WAIT_OBJECT_0 || s.failed || s.phase!=128){printf("[win-handoff] FAIL join=%lu phase=%ld\n",(unsigned long)result,(long)s.phase);return 2;}
 ResetEvent(s.ready);ResetEvent(s.done);
 if(WaitForMultipleObjects(2,first,FALSE,0)!=WAIT_TIMEOUT)return 2;
 SetEvent(s.done);
 if(WaitForMultipleObjects(2,first,FALSE,0)!=WAIT_OBJECT_0+1)return 2;
 SetEvent(s.go);
 if(WaitForSingleObject(s.go,0)!=WAIT_OBJECT_0 || WaitForSingleObject(s.go,0)!=WAIT_TIMEOUT)return 2;
 CloseHandle(thread);CloseHandle(s.ready);CloseHandle(s.go);CloseHandle(s.done);
 puts("[win-handoff] PASS event + atomic/address handoff64 + byte/yield + wait-any/all + reset/auto-consume");return 0;
}
