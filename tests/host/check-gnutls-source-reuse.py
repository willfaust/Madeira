#!/usr/bin/env python3
"""Check that a changed GnuTLS archive is rebuilt, even at the same version."""
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
    archive = src / 'gnutls-3.8.13.tar.xz'

    def write_source(label):
        data = ('#!/bin/sh\necho ' + label + ' >> "$TASK_GNUTLS_LOG"\n').encode()
        with tarfile.open(archive, 'w:xz') as t:
            member = tarfile.TarInfo('gnutls-3.8.13/configure')
            member.mode = 0o755
            member.size = len(data)
            t.addfile(member, io.BytesIO(data))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (src / 'SHA256SUMS').write_text(digest + '  ' + archive.name + '\n')
        return digest

    def run():
        subprocess.run(['bash', str(build / 'build.sh')], env=env, check=True, capture_output=True, text=True)

    first = write_source('first')
    run()
    run()
    assert (root / 'configured').read_text().splitlines() == ['first'], 'unchanged source should be reused'
    assert (obj / 'gnutls.done').read_text().strip() == first
    second = write_source('second')
    assert first != second
    run()
    assert (root / 'configured').read_text().splitlines() == ['first', 'second'], 'changed source should be extracted and rebuilt'
    assert (obj / 'gnutls.done').read_text().strip() == second
    (src / 'SHA256SUMS').write_text('0' * 64 + '  ' + archive.name + '\n')
    bad = subprocess.run(['bash', str(build / 'build.sh')], env=env, capture_output=True, text=True)
    assert bad.returncode != 0 and 'sha256 mismatch' in bad.stderr, 'invalid source must fail even with a completed marker'
print('PASS: GnuTLS source reuse tracks the verified archive')
