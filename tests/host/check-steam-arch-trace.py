#!/usr/bin/env python3
"""Compile the staged architecture APIs; prove tracing preserves real results."""
from pathlib import Path
import importlib.util, os, subprocess, tempfile

root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('stager',root/'tools/build/stage-io-status-abi.py')
stager=importlib.util.module_from_spec(spec);spec.loader.exec_module(stager)
def function(text,signature):
    a=text.index(signature);i=text.index('{',a)+1;depth=1
    while depth:depth+=(text[i]=='{')-(text[i]=='}');i+=1
    return text[a:i]

with tempfile.TemporaryDirectory(prefix='madeira-steam-arch-') as temp:
    p=Path(temp);stager.stage(p,root/'wine')
    mem=(p/'dlls/kernelbase/memory.c').read_text();proc=(p/'dlls/kernelbase/process.c').read_text()
    info=function(mem,'static BOOL steam_arch_info_enabled(')+'\n'+function(mem,'static void steam_arch_trace_info(')
    process=function(proc,'static BOOL steam_arch_process_enabled(')+'\n'+function(proc,'static void steam_arch_trace_process(')
    code=r'''
#include <assert.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
typedef int BOOL;typedef BOOL *PBOOL;typedef uint16_t WCHAR,USHORT;typedef unsigned long ULONG,DWORD;typedef long NTSTATUS;typedef int32_t LONG;
typedef uintptr_t ULONG_PTR;typedef void *HANDLE;
#define TRUE 1
#define FALSE 0
#define WINAPI
#define DECLSPEC_HOTPATCH
#define STATUS_SUCCESS 0
#define STATUS_NOT_IMPLEMENTED 0xc0000002L
#define IMAGE_FILE_MACHINE_AMD64 0x8664
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_FILE_MACHINE_ARM64 0xaa64
#define PROCESSOR_ARCHITECTURE_INTEL 0
#define PROCESSOR_ARCHITECTURE_AMD64 9
#define PROCESSOR_ARCHITECTURE_ARM 5
#define PROCESSOR_ARCHITECTURE_ARM64 12
#define PROCESSOR_INTEL_386 386
#define PROCESSOR_INTEL_486 486
#define PROCESSOR_INTEL_PENTIUM 586
#define PROCESSOR_AMD_X8664 8664
#define PROCESSOR_ARM_7TDMI 70001
#define PROCESSOR_ARM920 2336
enum {SystemBasicInformation,SystemCpuInformation,ProcessWow64Information};
typedef struct {USHORT Length;WCHAR *Buffer;} UNICODE_STRING;
typedef struct {UNICODE_STRING ImagePathName;} PARAMETERS;
typedef struct {PARAMETERS *ProcessParameters;} PEB;
typedef struct {PEB *Peb;struct {void *UniqueProcess,*UniqueThread;} ClientId;ULONG LastErrorValue;} TEB;
static TEB teb;static PARAMETERS params;static PEB peb={&params};
static TEB *NtCurrentTeb(void){return &teb;}
static LONG InterlockedIncrement(LONG *p){return ++*p;}
static BOOL is_wow64=TRUE;
typedef struct {ULONG PageSize;void *LowestUserAddress,*HighestUserAddress;ULONG_PTR ActiveProcessorsAffinityMask;ULONG AllocationGranularity;} SYSTEM_BASIC_INFORMATION;
typedef struct {USHORT ProcessorArchitecture,ProcessorLevel,ProcessorRevision,MaximumProcessors;} SYSTEM_CPU_INFORMATION;
typedef struct {USHORT wProcessorArchitecture,wReserved;DWORD dwPageSize;void *lpMinimumApplicationAddress,*lpMaximumApplicationAddress;ULONG_PTR dwActiveProcessorMask;DWORD dwAllocationGranularity,dwNumberOfProcessors,dwProcessorType;USHORT wProcessorLevel,wProcessorRevision;} SYSTEM_INFO;
static NTSTATUS query_status,machine_status,process_status;static unsigned calls,nt_calls,native_calls,machine_calls,process_calls;
static USHORT reported_machine=IMAGE_FILE_MACHINE_I386,reported_native=IMAGE_FILE_MACHINE_ARM64;static ULONG_PTR reported_pbi=1;
static char logs[32768];static size_t log_size;
static void log_error(const char *format,...){va_list args;va_start(args,format);log_size+=vsnprintf(logs+log_size,sizeof(logs)-log_size,format,args);va_end(args);calls++;teb.LastErrorValue=999;}
#define ERR(...) log_error(__VA_ARGS__)
#define FIXME(...) ((void)0)
static BOOL set_ntstatus(NTSTATUS status){if(status)teb.LastErrorValue=87;return !status;}
static NTSTATUS RtlWow64GetProcessMachines(HANDLE h,USHORT *machine,USHORT *native){(void)h;machine_calls++;if(!machine_status){if(machine)*machine=reported_machine;if(native)*native=reported_native;}return machine_status;}
static NTSTATUS info_query(unsigned what,void *output,size_t size,void *needed){(void)size;(void)needed;if(query_status)return query_status;if(what==SystemBasicInformation){SYSTEM_BASIC_INFORMATION b={4096,(void *)0x10000,(void *)0x7fff0000,255,65536};memcpy(output,&b,sizeof(b));}else{SYSTEM_CPU_INFORMATION c={0,6,1,28};memcpy(output,&c,sizeof(c));}return 0;}
static NTSTATUS NtQuerySystemInformation(unsigned what,void *output,size_t size,void *needed){nt_calls++;return info_query(what,output,size,needed);}
static NTSTATUS RtlGetNativeSystemInformation(unsigned what,void *output,size_t size,void *needed){native_calls++;NTSTATUS status=info_query(what,output,size,needed);if(!status&&what==SystemCpuInformation)((SYSTEM_CPU_INFORMATION *)output)->ProcessorArchitecture=PROCESSOR_ARCHITECTURE_AMD64;return status;}
static NTSTATUS NtQueryInformationProcess(HANDLE h,unsigned what,void *out,size_t size,void *needed){(void)h;(void)size;(void)needed;assert(what==ProcessWow64Information);process_calls++;if(!process_status)*(ULONG_PTR *)out=reported_pbi;return process_status;}
void GetSystemInfo(SYSTEM_INFO *si);
'''+'\n'+info+'\n'+process+'\n'+function(mem,'static void fill_system_info(')+'\n'+function(mem,'void WINAPI DECLSPEC_HOTPATCH GetNativeSystemInfo(')+'\n'+function(mem,'void WINAPI DECLSPEC_HOTPATCH GetSystemInfo(')+'\n'+function(proc,'BOOL WINAPI DECLSPEC_HOTPATCH IsWow64Process2(')+'\n'+function(proc,'BOOL WINAPI DECLSPEC_HOTPATCH IsWow64Process(')+r'''
static void image(const char *path){static WCHAR chars[256];size_t n=strlen(path);assert(n<256);for(size_t i=0;i<n;i++)chars[i]=(unsigned char)path[i];params.ImagePathName.Buffer=chars;params.ImagePathName.Length=n*sizeof(WCHAR);}
int main(void){
 teb.Peb=&peb;teb.ClientId.UniqueProcess=(void *)0x20;teb.ClientId.UniqueThread=(void *)0x24;teb.LastErrorValue=77;
 image("C:\\Program Files (x86)\\Steam\\STEAM.EXE");
 SYSTEM_INFO si={0};GetSystemInfo(&si);assert(si.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_INTEL&&si.dwNumberOfProcessors==28&&si.dwPageSize==4096);assert(nt_calls==2&&teb.LastErrorValue==77);
 unsigned previous_nt=nt_calls;GetNativeSystemInfo(&si);assert(si.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_AMD64);assert(machine_calls==1&&nt_calls==previous_nt+2&&native_calls==0&&teb.LastErrorValue==77); // preserve pre-existing ARM64 compatibility branch
 reported_native=IMAGE_FILE_MACHINE_AMD64;GetNativeSystemInfo(&si);assert(si.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_AMD64&&native_calls==2&&teb.LastErrorValue==77);
 USHORT machine=0,native=0;assert(IsWow64Process2((void *)-1,&machine,&native));assert(machine==IMAGE_FILE_MACHINE_I386&&native==IMAGE_FILE_MACHINE_AMD64&&teb.LastErrorValue==77);
 BOOL wow=FALSE;assert(IsWow64Process((void *)-1,&wow)&&wow&&teb.LastErrorValue==77);
 reported_pbi=0;assert(IsWow64Process((void *)-1,&wow)&&!wow&&teb.LastErrorValue==77);
 process_status=0xc000000dL;wow=TRUE;assert(!IsWow64Process((void *)-1,&wow)&&wow&&teb.LastErrorValue==87);
 machine_status=0xc000000dL;machine=0xbeef;native=0xcafe;assert(!IsWow64Process2((void *)-1,&machine,&native)&&machine==0xbeef&&native==0xcafe&&teb.LastErrorValue==87);
 query_status=0xc000000dL;si.dwPageSize=123;previous_nt=nt_calls;GetSystemInfo(&si);assert(si.dwPageSize==123&&nt_calls==previous_nt+1&&teb.LastErrorValue==87);
 query_status=0;machine_status=0;process_status=0;image("C:\\Other\\not-steam.exe");unsigned previous_calls=calls;GetSystemInfo(&si);assert(calls==previous_calls);
 image("C:\\Steam\\steam.exe");for(unsigned i=0;i<100;i++)GetSystemInfo(&si);assert(calls<=32);
 assert(strstr(logs,"api=GetSystemInfo")&&strstr(logs,"api=GetNativeSystemInfo")&&strstr(logs,"api=IsWow64Process2")&&strstr(logs,"api=IsWow64Process"));
 assert(strstr(logs,"native-machine=aa64")&&strstr(logs,"arch=9")&&strstr(logs,"status=c000000d"));
 assert(!strstr(logs,"Program Files")&&!strstr(logs,"C:\\"));
 puts("PASS actual staged architecture APIs: results, error outputs, LastError, query counts and existing compatibility policy unchanged; Steam-only bounded trace and real source restoration");
}
'''
    src=p/'test.c';exe=p/'test';src.write_text(code)
    subprocess.run([os.environ.get('CC','cc'),'-std=gnu11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
