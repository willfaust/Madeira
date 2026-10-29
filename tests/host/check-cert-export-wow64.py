#!/usr/bin/env python3
"""Exercise the new certificate-export thunk with nonzero WoW64 windows."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/crypto-unix/crypt32_unixlib_ios.c').read_text()
header = (root / 'wine/dlls/crypt32/crypt32_private.h').read_text()
a = source.index('static NTSTATUS wow64_export_cert_store(')
thunk = source[a:source.index('\n}', a) + 2]
a = header.index('struct export_cert_store_params\n')
params = header[a:header.index('\n};', a) + 3]
code = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"
static unsigned char storage[2][256];
static int process, size_only;
ULONG_PTR ios_wow_base(void) { return (ULONG_PTR)storage[process] - 0x1000; }
#include "ios_wow.h"
typedef ULONG PTR32;
PARAMS
static NTSTATUS export_cert_store(void *args)
{
    struct export_cert_store_params *p = args;
    assert(p->cert_data == (size_only ? NULL : storage[process] + 16));
    assert(p->key_blob == (size_only ? NULL : storage[process] + 32));
    assert(p->password == (size_only ? NULL : (WCHAR *)(storage[process] + 48)));
    assert(p->pfx_data == (size_only ? NULL : storage[process] + 64));
    assert(p->pfx_size == (DWORD *)(storage[process] + 80));
    assert(p->cert_size == 3 && p->key_blob_size == 5);
    *p->pfx_size = 123;
    return 76;
}
THUNK
int main(void)
{
    struct { PTR32 cert_data; DWORD cert_size; PTR32 key_blob; DWORD key_blob_size;
        PTR32 password, pfx_data, pfx_size; } args = {0x1010,3,0x1020,5,0x1030,0x1040,0x1050};
    for (process = 0; process < 2; process++) {
        assert(wow64_export_cert_store(&args) == 76);
        assert(*(DWORD *)(storage[process] + 80) == 123);
    }
    process = 0; size_only = 1;
    args.cert_data = args.key_blob = args.password = args.pfx_data = 0;
    assert(wow64_export_cert_store(&args) == 76);
}
'''.replace('PARAMS', params).replace('THUNK', thunk)
with tempfile.TemporaryDirectory() as folder:
    c = Path(folder) / 'test.c'
    binary = Path(folder) / 'test'
    c.write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-fsanitize=address,undefined', '-D__WINESRC__',
                    '-DWINE_UNIX_LIB', '-I' + str(root / 'wine/include'),
                    '-I' + str(root / 'build/ntdll-unix'), str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: certificate export translates every pointer per process and preserves null optional pointers')
