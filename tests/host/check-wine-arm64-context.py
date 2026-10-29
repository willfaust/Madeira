#!/usr/bin/env python3
"""Round-trip the iOS context converter through Wine 11.20's real protocol."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/thread_ios.c').read_text()
start = '    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARM64 ):\n'
end = '    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_I386 ):\n'
parts = []
pos = 0
for _ in range(2):
    a = source.index(start, pos)
    b = source.index(end, a)
    parts.append(source[a:b])
    pos = b
code = r'''
#include <assert.h>
#include <string.h>
#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"
#include "wine/server_protocol.h"
static const ULONG cpsr_user_mask = 0xf620fc30;
static void exception_request_flags_to_server(struct context_data *c, DWORD f) {}
static void exception_request_flags_from_server(DWORD *f, const struct context_data *c) {}
static NTSTATUS convert_to(struct context_data *to, const void *src)
{
    DWORD flags, i;
    switch (MAKELONG(IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARM64)) {
TO
    } return STATUS_INVALID_PARAMETER;
}
static NTSTATUS convert_from(void *dst, const struct context_data *from)
{
    DWORD to_flags, i;
    switch (MAKELONG(IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARM64)) {
FROM
    } return STATUS_INVALID_PARAMETER;
}
int main(void)
{
    ARM64_NT_CONTEXT input = {0}, output = {0};
    struct context_data wire = {0};
    input.ContextFlags = output.ContextFlags = CONTEXT_ARM64 | CONTEXT_ARM64_INTEGER | CONTEXT_ARM64_CONTROL;
    for (unsigned i = 0; i < 31; i++) input.X[i] = 0x100 + i;
    input.Sp = 0x500; input.Pc = 0x600; input.Cpsr = ~0u;
    output.X18 = 0xdeadbeef;
    assert(!convert_to(&wire, &input));
    assert(wire.integer.arm64_regs.x0[17] == input.X17);
    assert(wire.integer.arm64_regs.x19[0] == input.X19);
    assert(!convert_from(&output, &wire));
    for (unsigned i = 0; i < 31; i++) if (i != 18) assert(output.X[i] == input.X[i]);
    assert(output.X18 == 0xdeadbeef);
    assert(output.Sp == input.Sp && output.Pc == input.Pc && output.Cpsr == cpsr_user_mask);
}
'''.replace('TO\n', parts[0]).replace('FROM\n', parts[1])
with tempfile.TemporaryDirectory() as folder:
    c = Path(folder) / 'test.c'
    binary = Path(folder) / 'test'
    c.write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-fsanitize=address,undefined', '-DWINE_UNIX_LIB',
                    '-D__WINESRC__', '-I' + str(root / 'wine/include'), str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('PASS: ARM64 protocol round-trip, control registers and preserved x18')
