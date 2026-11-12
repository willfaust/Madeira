#!/usr/bin/env python3
"""Check that changed crypto archives are rebuilt, even at the same version."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

source = Path(__file__).resolve().parents[2] / 'build/gnutls-ios/build.sh'
with tempfile.TemporaryDirectory(prefix='madeira-gnutls-reuse-') as tmp:
    root = Path(tmp)
    build = root / 'build/gnutls-ios'
    src, obj = build / 'src', build / 'obj'
    src.mkdir(parents=True)
    obj.mkdir()
    shutil.copy(source, build / 'build.sh')
    (obj / 'gmp.done').touch()
    (obj / 'nettle.done').touch()
    (obj / 'gnutls.done').touch()  # Old builds used an empty marker.
    fake_bin = root / 'bin'
    fake_bin.mkdir()
    for name, body in {
        'xcrun': 'echo /usr/bin/true',
        'sysctl': 'echo 2',
        'lipo': 'exit 0',
        'make': 'mkdir -p "$TASK_GNUTLS_PREFIX/lib"; : > "$TASK_GNUTLS_PREFIX/lib/libgnutls.a"',
    }.items():
        f = fake_bin / name
        f.write_text('#!/bin/sh\nset -e\n' + body + '\n')
        f.chmod(0o755)
    env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'],
               TASK_GNUTLS_LOG=str(root / 'configured'), TASK_GNUTLS_PREFIX=str(root / 'toolchains/gnutls-ios'))
    archives = {name: src / filename for name, filename in {
        'nettle': 'nettle-3.10.2.tar.gz', 'gnutls': 'gnutls-3.8.13.tar.xz'
    }.items()}
    digests = {}

    def write_source(name, label):
        archive = archives[name]
        data = ('#!/bin/sh\necho ' + label + ' >> "$TASK_GNUTLS_LOG"\n').encode()
        with tarfile.open(archive, 'w:gz' if name == 'nettle' else 'w:xz') as t:
            member = tarfile.TarInfo(archive.name.removesuffix('.tar.gz').removesuffix('.tar.xz') + '/configure')
            member.mode = 0o755
            member.size = len(data)
            t.addfile(member, io.BytesIO(data))
        digests[name] = hashlib.sha256(archive.read_bytes()).hexdigest()
        (src / 'SHA256SUMS').write_text(''.join(digests[n] + '  ' + archives[n].name + '\n' for n in digests))

    def run():
        subprocess.run(['bash', str(build / 'build.sh')], env=env, check=True, capture_output=True, text=True)

    write_source('nettle', 'n1')
    write_source('gnutls', 'g1')
    run()
    run()
    assert (root / 'configured').read_text().splitlines() == ['n1', 'g1']
    assert (obj / 'nettle.done').read_text().strip() == digests['nettle']
    assert (obj / 'gnutls.done').read_text().strip() == digests['gnutls'] + ':' + digests['nettle']
    write_source('gnutls', 'g2')
    run()
    write_source('nettle', 'n2')
    run()
    assert (root / 'configured').read_text().splitlines() == ['n1', 'g1', 'g2', 'n2', 'g2']
    assert (obj / 'gnutls.done').read_text().strip() == digests['gnutls'] + ':' + digests['nettle']
    for name in archives:
        sums = ''.join(('0' * 64 if n == name else digests[n]) + '  ' + archives[n].name + '\n' for n in digests)
        (src / 'SHA256SUMS').write_text(sums)
        bad = subprocess.run(['bash', str(build / 'build.sh')], env=env, capture_output=True, text=True)
        assert bad.returncode != 0 and 'sha256 mismatch' in bad.stderr
print('PASS: crypto source reuse tracks verified archives')
