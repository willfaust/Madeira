#!/usr/bin/env python3
"""Run the packaging entry point with synthetic build products/Xcode commands.
This validates resource gates and ZIP contents, not an iOS executable."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import zipfile
import struct
root = Path(__file__).resolve().parents[2]
entry = (root/'tools/build-ipa.sh').read_text()
assert entry.index('"$ROOT/tools/build/setup-llvm-mingw.sh"') < entry.index('"$ROOT/build/madeira-dock/build.sh"') < entry.index('"$ROOT/tools/build/package-ipa.sh"')
project = (root/'app/Madeira.xcodeproj/project.pbxproj').read_text()
assert 'A1000080 /* arm64ec-windows in Resources */' in project
assert 'lastKnownFileType = folder; path = "arm64ec-windows"' in project
script = (root/'tools/build/package-ipa.sh').read_text()
with tempfile.TemporaryDirectory() as temp:
    t = Path(temp); commands = t/'bin'; commands.mkdir()
    package = t/'package.sh'; package.write_text(script)
    # Populate all production prerequisites, avoiding a separate list that can drift.
    for relative in re.findall(r'"\$ROOT/([^"\n]+)"', script.split('for path in "${required[@]}"')[0]):
        p = t/relative
        if relative.endswith(('.a','.exe','.dll','.txt')):
            p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(b'fixture')
    # A minimal architecture/marker fixture tests the gate, not executable Wine.
    wow = bytearray(256)
    wow[:2] = b'MZ'; struct.pack_into('<I', wow, 0x3c, 0x80)
    wow[0x80:0x84] = b'PE\0\0'; struct.pack_into('<H', wow, 0x84, 0xaa64)
    wow[0xa0:0xa0+len(b'madeira-io-abi-v1')] = b'madeira-io-abi-v1'
    wow.extend(b'[wow-thread-init-v1][wow-break-deliver-v1]MadeiraBTCpuWriteMemory')
    (t/'app/Madeira/aarch64-windows/wow64.dll').write_bytes(wow)
    cpu = bytearray(wow)
    cpu.extend(b'MadeiraBTCpuThreadInit[fex-thread-init-v1]MadeiraBTCpuWriteMemory[fex-guest-write-v1]')
    (t/'app/Madeira/aarch64-windows/xtajit.dll').write_bytes(cpu)
    guest = bytearray(wow)
    struct.pack_into('<H',guest,0x84,0x14c)
    guest.extend(b'[wpm-call-v1]')
    (t/'app/Madeira/i386-windows/kernelbase.dll').write_bytes(guest)
    (t/'tools').mkdir()
    (t/'tools/check-io-abi-package.py').write_text((root/'tools/check-io-abi-package.py').read_text())
    bodies = {
      'xcodebuild': '''mkdir -p "$TEST_APP/arm64ec-windows" "$TEST_APP/i386-windows" "$TEST_APP/x86_64-vcruntime" "$TEST_APP/aarch64-windows"
cp "$ROOT/app/Madeira/aarch64-windows/wow64.dll" "$ROOT/app/Madeira/aarch64-windows/xtajit.dll" "$TEST_APP/aarch64-windows/"
printf '[io-abi] v1 per-request IOSB layout active[wow-write][guest32-symbols]' > "$TEST_APP/Madeira.debug.dylib"
cp "$ROOT/app/Madeira/i386-windows/kernelbase.dll" "$TEST_APP/i386-windows/"
printf fixture > "$TEST_APP/Madeira"
printf fixture > "$TEST_APP/prefix-template.tar.gz"
printf fixture > "$TEST_APP/arm64ec-windows/xtajit64.dll"
printf fixture > "$TEST_APP/x86_64-vcruntime/vcruntime140.dll"
for resource in dockhost.exe dock-notices.txt madeira-steam-service.exe madeira-scm-probe.exe; do
  if [ "${OMIT_RESOURCE:-}" != "$resource" ]; then cp "$ROOT/app/Madeira/arm64ec-windows/$resource" "$TEST_APP/arm64ec-windows/"; fi
done
for resource in madeira-wow64-probe.exe madeira-wow64-module-probe.dll; do
  if [ "${OMIT_RESOURCE:-}" != "$resource" ]; then cp "$ROOT/app/Madeira/i386-windows/$resource" "$TEST_APP/i386-windows/"; fi
done
''',
      'codesign': 'if [ "$1" = -d ]; then echo com.apple.security.cs.allow-jit; fi\n',
      'ditto': 'cp -R "$1" "$2"\n',
    }
    for name, body in bodies.items():
        p=commands/name; p.write_text('#!/bin/sh\nset -eu\n'+body); p.chmod(0o755)
    env=dict(os.environ, ROOT=str(t), TEST_APP=str(t/'app/DerivedData/Build/Products/Debug-iphoneos/Madeira.app'), PATH=str(commands)+os.pathsep+os.environ['PATH'])
    def run(extra=None):
        return subprocess.run(['bash',str(package)],env=dict(env,**(extra or {})),capture_output=True,text=True)
    result=run(); assert result.returncode == 0, result.stdout+result.stderr
    with zipfile.ZipFile(t/'dist/Madeira.ipa') as archive:
        for resource in ['dockhost.exe','dock-notices.txt','madeira-steam-service.exe','madeira-scm-probe.exe']:
            assert archive.read('Payload/Madeira.app/arm64ec-windows/'+resource) == b'fixture'
    with zipfile.ZipFile(t/'dist/Madeira.ipa') as archive:
        for resource in ['madeira-wow64-probe.exe','madeira-wow64-module-probe.dll']:
            assert archive.read('Payload/Madeira.app/i386-windows/'+resource)==b'fixture'
    print('PASS final ZIP includes Dock, helpers, i386 loader fixture and license notices')
    for resource in ['dockhost.exe','dock-notices.txt','madeira-steam-service.exe','madeira-scm-probe.exe']:
        result=run({'OMIT_RESOURCE':resource})
        assert result.returncode != 0 and 'required bundle resource missing' in result.stderr, result.stderr
        p=t/'app/Madeira/arm64ec-windows'/resource; p.write_bytes(b'')
        result=run()
        assert result.returncode != 0 and 'required build artifact missing' in result.stderr, result.stderr
        p.write_bytes(b'fixture')
    for resource in ['madeira-wow64-probe.exe','madeira-wow64-module-probe.dll']:
        result=run({'OMIT_RESOURCE':resource}); assert result.returncode and 'required bundle resource missing' in result.stderr
        p=t/'app/Madeira/i386-windows'/resource; p.write_bytes(b'')
        result=run();assert result.returncode and 'required build artifact missing' in result.stderr
        p.write_bytes(b'fixture')
    print('PASS missing bundle resources and empty staging outputs fail packaging')
    (t/'app/Madeira/aarch64-windows/xtajit.dll').write_bytes(wow)
    result=run()
    assert result.returncode and 'stale FEX CPU producer' in result.stderr, result.stderr
    (t/'app/Madeira/aarch64-windows/xtajit.dll').write_bytes(cpu)
    print('PASS stale FEX checked-init producer fails final IPA validation')
    (t/'app/Madeira/aarch64-windows/wow64.dll').write_bytes(b'old image')
    result=run()
    assert result.returncode and 'not a PE image' in result.stderr, result.stderr
    print('PASS stale WoW64 IOSB producer fails final IPA validation')
