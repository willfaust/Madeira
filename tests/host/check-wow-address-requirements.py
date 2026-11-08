#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'wine/dlls/wow64/virtual.c').read_text()
start = source.index('static NTSTATUS mem_extended_parameters_32to64(')
function = source[start:source.index('\n}\n', start) + 3]
prefix = r"""
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t ULONG;
typedef uintptr_t ULONG_PTR;
typedef uint32_t NTSTATUS;
typedef int BOOL;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 0xc000000dU
#define ULongToPtr(x) ((void *)(uintptr_t)(x))
#define ULongToHandle(x) ULongToPtr(x)
enum { MemExtendedParameterAddressRequirements = 1, MemExtendedParameterNumaNode,
       MemExtendedParameterPartitionHandle, MemExtendedParameterUserPhysicalHandle,
       MemExtendedParameterAttributeFlags, MemExtendedParameterImageMachine };
typedef struct { ULONG LowestStartingAddress, HighestEndingAddress, Alignment; } MEM_ADDRESS_REQUIREMENTS32;
typedef struct { void *LowestStartingAddress, *HighestEndingAddress; uintptr_t Alignment; } MEM_ADDRESS_REQUIREMENTS;
typedef struct { ULONG Type, Reserved, Pointer, ULong, Handle; } MEM_EXTENDED_PARAMETER32;
typedef struct { ULONG Type, Reserved; void *Pointer; ULONG ULong; void *Handle; } MEM_EXTENDED_PARAMETER;
static ULONG_PTR highest_user_address = 0xffffffffU;
static MEM_ADDRESS_REQUIREMENTS32 request;
static _Alignas(max_align_t) unsigned char storage[1024];
static void *Wow64AllocateTemp(size_t size) { memset(storage, 0, size); return storage; }
static void *guest_ptr32(ULONG address) { return address == 0x10000 ? &request : NULL; }
"""
suffix = r"""
static unsigned failures;
static void check(int value, const char *name) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", name); failures++; }
}
int main(void) {
    MEM_EXTENDED_PARAMETER32 input = { .Type = MemExtendedParameterAddressRequirements, .Pointer = 0x10000 };
    MEM_EXTENDED_PARAMETER *output;
    MEM_ADDRESS_REQUIREMENTS *result;
    ULONG count = 1;
    request = (MEM_ADDRESS_REQUIREMENTS32){0x10000, 0, 0x10000};
    check(!mem_extended_parameters_32to64(&output, &input, &count, 1), "alignment-only request accepted");
    result = output[0].Pointer;
    check((uintptr_t)result->HighestEndingAddress == highest_user_address, "unspecified ceiling stays in the 32-bit address space");
    check((uintptr_t)result->LowestStartingAddress == 0x10000 && result->Alignment == 0x10000, "floor and alignment preserved");
    request.HighestEndingAddress = 0x3fffffff;
    count = 1;
    check(!mem_extended_parameters_32to64(&output, &input, &count, 1), "explicit ceiling accepted");
    check((uintptr_t)((MEM_ADDRESS_REQUIREMENTS *)output[0].Pointer)->HighestEndingAddress == 0x3fffffff, "explicit ceiling preserved");
    request.HighestEndingAddress = 0;
    count = 1;
    check(!mem_extended_parameters_32to64(&output, &input, &count, 0), "unlimited non-placement request accepted");
    check(!((MEM_ADDRESS_REQUIREMENTS *)output[0].Pointer)->HighestEndingAddress, "non-placement request unchanged");
    count = 0;
    check(!mem_extended_parameters_32to64(&output, NULL, &count, 1) && count == 1, "missing requirement inserted");
    check((uintptr_t)((MEM_ADDRESS_REQUIREMENTS *)output[0].Pointer)->HighestEndingAddress == highest_user_address, "inserted requirement has guest ceiling");
    highest_user_address = 0x7ffeffff;
    request.HighestEndingAddress = 0x80000000;
    count = 1;
    check(mem_extended_parameters_32to64(&output, &input, &count, 1) == STATUS_INVALID_PARAMETER, "out-of-range ceiling rejected");
    check(mem_extended_parameters_32to64(&output, NULL, &count, 1) == STATUS_INVALID_PARAMETER, "missing parameter array rejected");
    return failures != 0;
}
"""
with tempfile.TemporaryDirectory(prefix='madeira-wow-address-') as folder:
    c = Path(folder) / 'check.c'
    binary = Path(folder) / 'check'
    c.write_text(prefix + function + suffix)
    subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: actual WoW64 parameter conversion preserves the guest ceiling and explicit constraints')
