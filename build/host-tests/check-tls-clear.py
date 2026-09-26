#!/usr/bin/env python3
"""Exercise the production TLS clear routine in a host-only process model."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[2]
s=(root/"build/ntdll-unix/virtual_ios.c").read_text()
a=s.index("NTSTATUS virtual_clear_tls_index(")
b=s.index("\n\n/***********************************************************************",a)
source=r"""
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#define WINE_IOS 1
#define _WIN64 1
#define TLS_MINIMUM_AVAILABLE 64
#define IOS_WOW_WINDOW_SIZE (1ull<<32)
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER ((int)0xc000000d)
typedef int NTSTATUS;
typedef unsigned int ULONG;
typedef uintptr_t ULONG_PTR;
typedef int BOOL;
typedef struct { unsigned TlsExpansionBitmapBits[32]; } PEB;
typedef struct { ULONG TlsSlots[64], TlsExpansionSlots; } WOW_TEB;
struct ntdll_thread_data { struct ntdll_thread_data *entry; };
typedef struct {
    struct ntdll_thread_data GdiTebBatch;
    PEB *Peb;
    void *TlsSlots[64], **TlsExpansionSlots;
    WOW_TEB *wow;
} TEB;
static TEB *current;
static PEB *peb;
static struct ntdll_thread_data *teb_list;
static int virtual_mutex;
struct ios_wow_window { uintptr_t base; };
static struct ios_wow_window window;
static TEB *NtCurrentTeb(void) { return current; }
static WOW_TEB *get_wow_teb(TEB *t) { return t->wow; }
static struct ios_wow_window *ios_wow_slot_at_base(uintptr_t address)
{ return address == ((uintptr_t)current & ~(IOS_WOW_WINDOW_SIZE-1)) ? &window : NULL; }
#define CONTAINING_RECORD(ptr,type,field) ((type *)((char *)(ptr)-offsetof(type,field)))
#define LIST_FOR_EACH_ENTRY(p,list,type,member) for(p=*(list);p;p=p->entry)
#define server_enter_uninterrupted_section(m,s) ((void)0)
#define server_leave_uninterrupted_section(m,s) ((void)0)
#define ULongToPtr(p) ((void *)(uintptr_t)(p))
"""
main=r"""
int main(void)
{
    PEB owners[2];
    TEB a={0},b={0},native={0};
    WOW_TEB aw={0},bw={0};
    ULONG expansion[1024], foreign[1024];
    void *native_expansion[1024];
    for(unsigned i=0;i<1024;i++) { expansion[i]=123; foreign[i]=456; native_expansion[i]=(void *)789; }
    a.Peb=&owners[0];b.Peb=&owners[1];native.Peb=&owners[0];
    a.wow=&aw;b.wow=&bw;native.TlsExpansionSlots=native_expansion;
    aw.TlsExpansionSlots=128; bw.TlsExpansionSlots=256;
    window.base=(uintptr_t)expansion-128;
    current=&a;peb=&owners[1]; /* Deliberately stale global PEB. */
    teb_list=&a.GdiTebBatch;a.GdiTebBatch.entry=&b.GdiTebBatch;b.GdiTebBatch.entry=&native.GdiTebBatch;
    aw.TlsSlots[3]=123;bw.TlsSlots[3]=456;native.TlsSlots[3]=(void *)789;
    assert(virtual_clear_tls_index(3)==0);
    assert(!aw.TlsSlots[3] && bw.TlsSlots[3]==456 && !native.TlsSlots[3]);
    assert(virtual_clear_tls_index(64+7)==0);
    assert(!expansion[7] && expansion[6]==123 && expansion[8]==123);
    assert(foreign[7]==456 && !native_expansion[7]);
    assert(virtual_clear_tls_index(64+1023)==0 && !expansion[1023]);
    assert(virtual_clear_tls_index(64+1024)==STATUS_INVALID_PARAMETER);
    aw.TlsExpansionSlots=0;assert(virtual_clear_tls_index(64)==0);
    setenv("MADEIRA_TLS_CLEAR_OWNER","0",1);
    assert(virtual_clear_tls_index(3)==0 && !bw.TlsSlots[3]);
    puts("PASS: TLS owner isolation, expanded guest pointers, boundaries, null storage, rollback");
}
"""
with tempfile.TemporaryDirectory(prefix="madeira-tls-") as temp:
    p=Path(temp)/"test.c";p.write_text(source+s[a:b]+main)
    out=Path(temp)/"test"
    subprocess.run(["cc","-g","-O1","-fsanitize=address,undefined","-fno-pie","-no-pie",str(p),"-o",str(out)],check=True)
    subprocess.run([str(out)],check=True)
