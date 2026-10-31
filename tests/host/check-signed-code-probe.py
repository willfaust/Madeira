#!/usr/bin/env python3
"""Run the production loader on macOS, including refused and broken inputs.

Signing flags and tracing are injected for guard tests. Mach-O loading, memory
permissions, ARM64 execution and callbacks are real. This is not iOS proof.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('Requires an ARM64 Mac and Xcode command line tools')


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    assert result.returncode == 0, result.stdout + result.stderr
    return result


run('bash', str(root / 'build/signed-code-probe/build.sh'), 'macosx')
library = root / 'build/signed-code-probe/out/macosx/MadeiraSignedProbe.framework/MadeiraSignedProbe'
source = root / 'app/Madeira/SignedCodeProbe.m'
with tempfile.TemporaryDirectory(prefix='madeira-signed-probe-') as directory:
    folder = Path(directory)
    harness = folder / 'check.m'
    harness.write_text(r'''
#include "SignedCodeProbe.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
static const char *mode;
bool jit_cs_status(uint32_t *flags)
{
    *flags = !strcmp(mode, "debugged") ? 0x10000000u : 0;
    return strcmp(mode, "unknown") != 0;
}
int probe_test_sysctl(int *mib, u_int count, void *old, size_t *size, void *new, size_t length)
{
    (void)mib; (void)count; (void)new; (void)length;
    if (!strcmp(mode, "trace-unknown")) return -1;
    memset(old, 0, *size);
    ((struct kinfo_proc *)old)->kp_proc.p_flag = !strcmp(mode, "traced") ? P_TRACED : 0;
    return 0;
}
int main(int argc, char **argv)
{
    if (argc != 3) return 99;
    mode = argv[2];
    return madeira_signed_code_probe_run(argv[1], stdout);
}
''')
    obj = folder / 'probe.o'
    run('xcrun', '--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
        '-Dsysctl=probe_test_sysctl', '-c', str(source), '-o', str(obj))
    exe = folder / 'check'
    run('xcrun', '--sdk', 'macosx', 'clang', '-Wall', '-Wextra', '-Werror',
        '-I', str(source.parent), str(harness), str(obj), '-framework', 'Foundation', '-o', str(exe))

    def check(path, mode, status, message):
        result = subprocess.run([str(exe), str(path), mode], capture_output=True, text=True)
        assert result.returncode == status, result.stdout + result.stderr
        assert message in result.stdout, result.stdout

    check(library, 'clean', 0, 'PASS: signed library loader contract (host-only)')
    check(library, 'unknown', 2, 'INCONCLUSIVE')
    check(library, 'debugged', 2, 'INCONCLUSIVE')
    check(library, 'traced', 2, 'INCONCLUSIVE')
    check(library, 'trace-unknown', 2, 'INCONCLUSIVE')
    check(folder / 'absent.dylib', 'clean', 1, 'FAIL: dlopen:')
    check('', 'clean', 1, 'FAIL: missing fixture path.')
    wrong = folder / 'wrong.c'
    wrong.write_text('int unrelated_symbol(void) { return 1; }\n')
    wrong_lib = folder / 'wrong.dylib'
    run('xcrun', '--sdk', 'macosx', 'clang', '-dynamiclib', str(wrong), '-o', str(wrong_lib))
    check(wrong_lib, 'clean', 1, 'FAIL: missing or invalid fixture symbols.')

    # Compile the same production file for the app's oldest deployment target.
    sdk = run('xcrun', '--sdk', 'iphoneos', '--show-sdk-path').stdout.strip()
    run('xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios17.0',
        '-isysroot', sdk, '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
        '-c', str(source), '-o', str(folder / 'probe-ios.o'))

print('PASS: host ARM64 loader, data/callback changes, unchanged code, four state guards, '
      'missing/wrong libraries, and iOS 17 source compile. No device or FEX/Wine execution.')
