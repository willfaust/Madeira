#!/usr/bin/env python3
"""Host-only ABI/dispatch regressions. Does not load Wine or a Windows program."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
network = (root / "build/ntdll-unix/nsi_network_ios.c").read_text()
network = network[network.index("static const struct module *modules[]"):]
thunks = (root / "build/ntdll-unix/nsi_unixlib_ios.c").read_text()
thunks = thunks[thunks.index("typedef ULONG PTR32;"):thunks.index("const void *nsi_unix_call_wow64_funcs[]")]
header = r"""
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "ifdef.h"
#define __WINE_INIT_NPI_MODULEID
#define USE_WS_PREFIX
#include "netiodef.h"
#include "wine/nsi.h"
#include "dlls/nsiproxy.sys/unix_private.h"
#define WARN(...) ((void)0)
static const NET_LUID test_luid = {.Value = 0x06000007000000};
static unsigned calls;
static NTSTATUS mock_enum(void *key, UINT ks, void *rw, UINT rs, void *dyn, UINT ds,
                          void *stat, UINT ss, UINT_PTR *count)
{
    calls++;
    assert(!rw && !rs && !dyn && !ds);
    if (!(ks || ss)) { *count = 1; return 0; }
    if (!*count) return STATUS_BUFFER_OVERFLOW;
    if (ks) *(NET_LUID *)key = test_luid;
    if (ss) memset(stat, 0x5a, ss);
    *count = 1;
    return 0;
}
static NTSTATUS mock_all(const void *key, UINT ks, void *rw, UINT rs, void *dyn, UINT ds,
                         void *stat, UINT ss)
{
    calls++;
    assert(ks == sizeof(NET_LUID) && ((NET_LUID *)key)->Value == test_luid.Value);
    assert(!rw && !dyn);
    if (ss) memset(stat, 0x5a, ss);
    return 0;
}
static NTSTATUS mock_param(const void *key, UINT ks, UINT type, void *data, UINT size, UINT offset)
{
    calls++;
    assert(ks == sizeof(NET_LUID) && ((NET_LUID *)key)->Value == test_luid.Value);
    assert(type == NSI_PARAM_TYPE_STATIC);
    if (size) memset(data, 0x5a, size);
    return 0;
}
static const struct module_table tables[] = {
    {NSI_NDIS_IFINFO_TABLE, {sizeof(NET_LUID), 0, 0, sizeof(struct nsi_ndis_ifinfo_static)},
     mock_enum, mock_all, mock_param}, {~0u}
};
const struct module ndis_module = {&NPI_MS_NDIS_MODULEID, tables};
const struct module ipv4_module = {&NPI_MS_IPV4_MODULEID, tables};
const struct module ipv6_module = {&NPI_MS_IPV6_MODULEID, tables};
static unsigned char arena[8192] __attribute__((aligned(16)));
static void *ios_wow_host_ptr(ULONG guest) { return guest ? arena + guest : NULL; }
static NTSTATUS ios_nsi_enumerate_all_ex(void *p) { return nsi_enumerate_all_ex(p); }
static TEB test_teb;   /* ml1520 [nsi-rate] reader attribution reads the current TEB */
TEB * WINAPI NtCurrentTeb(void) { return &test_teb; }
"""
main = r"""
int main(void)
{
    struct nsi_enumerate_all_ex e = {.module=&NPI_MS_NDIS_MODULEID, .table=NSI_NDIS_IFINFO_TABLE};
    NET_LUID key;
    struct nsi_ndis_ifinfo_static stat;
    assert(nsi_enumerate_all_ex(&e) == 0 && e.count == 1);
    e.key_data=&key; e.key_size=sizeof(key); e.static_data=&stat; e.static_size=sizeof(stat); e.count=0;
    assert(nsi_enumerate_all_ex(&e) == STATUS_BUFFER_OVERFLOW);
    e.count=1; assert(nsi_enumerate_all_ex(&e)==0 && key.Value==test_luid.Value);
    e.key_size--; assert(nsi_enumerate_all_ex(&e)==STATUS_INVALID_PARAMETER); e.key_size++;
    e.key_data=NULL; assert(nsi_enumerate_all_ex(&e)==STATUS_INVALID_PARAMETER); e.key_data=&key;
    e.table=999; assert(nsi_enumerate_all_ex(&e)==STATUS_NOT_SUPPORTED); e.table=0;
    setenv("MADEIRA_NSI_NETWORK_TABLES", "0", 1);
    assert(nsi_enumerate_all_ex(&e)==STATUS_NOT_SUPPORTED);
    unsetenv("MADEIRA_NSI_NETWORK_TABLES");
    struct nsi_get_parameter_ex p = {.module=&NPI_MS_NDIS_MODULEID, .table=0,
        .key=&key, .key_size=sizeof(key), .param_type=NSI_PARAM_TYPE_STATIC,
        .data=&stat, .data_size=sizeof(stat)};
    assert(nsi_get_parameter_ex(&p)==0);
    p.data_offset=0xffffffffu; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    p.data_offset=sizeof(stat); p.data_size=1; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    p.data_offset=0; p.data_size=1; p.param_type=3; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    p.param_type=2; p.data=NULL; assert(nsi_get_parameter_ex(&p)==STATUS_INVALID_PARAMETER);
    memcpy(arena+64, &NPI_MS_NDIS_MODULEID, sizeof(NPI_MODULEID));
    struct nsi_enumerate_all_ex32 w = {.module=64, .key_data=256, .key_size=sizeof(key),
        .static_data=1024, .static_size=sizeof(stat), .count=1};
    assert(sizeof(w)==60);
    assert(ios_wow64_nsi_enumerate_all_ex(&w)==0 && w.count==1);
    assert(((NET_LUID *)(arena+256))->Value==test_luid.Value);
    struct nsi_get_all_parameters_ex32 a = {.module=64, .key=256, .key_size=sizeof(key),
        .static_data=1024, .static_size=sizeof(stat)};
    assert(sizeof(a)==56);
    assert(ios_wow64_nsi_get_all_parameters_ex(&a)==0);
    struct nsi_get_parameter_ex32 b = {.module=64, .key=256, .key_size=sizeof(key),
        .param_type=2, .data=1024, .data_size=4, .data_offset=0};
    assert(sizeof(b)==48);
    memset(arena+1024,0,4);
    assert(ios_wow64_nsi_get_parameter_ex(&b)==0 && arena[1024]==0x5a);
    assert(ios_wow64_nsi_get_parameter_ex(NULL)==STATUS_INVALID_PARAMETER);
    assert(ios_wow64_nsi_get_all_parameters_ex(NULL)==STATUS_INVALID_PARAMETER);
    puts("PASS: native/32-bit NSI dispatch, count/retry, pointer translation, bounds, rollback");
}
"""
with tempfile.TemporaryDirectory(prefix="madeira-nsi-") as temp:
    source = Path(temp)/"test.c"
    source.write_text(header + network + thunks + main)
    binary = Path(temp)/"test"
    subprocess.run(["cc", "-g", "-O1", "-fshort-wchar", "-D__WINESRC__", "-DWINE_UNIX_LIB",
                    "-fsanitize=address,undefined", "-fno-pie", "-no-pie",
                    "-I"+str(root/"wine/include"), "-I"+str(root/"wine"),
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
