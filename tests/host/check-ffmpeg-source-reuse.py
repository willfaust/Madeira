#!/usr/bin/env python3
"""Exercise FFmpeg source and configure reuse without building FFmpeg."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

source = Path(__file__).resolve().parents[2] / 'build/ffmpeg/build.sh'
with tempfile.TemporaryDirectory(prefix='madeira-ffmpeg-reuse-') as tmp:
    root = Path(tmp)
    build = root / 'build/ffmpeg'
    src = build / 'src'
    src.mkdir(parents=True)
    (root / 'app/Madeira').mkdir(parents=True)
    shutil.copy(source, build / 'build.sh')
    bins = root / 'bin'
    bins.mkdir()
    for name, body in {
        'xcrun': 'echo /usr/bin/true',
        'sysctl': 'echo 2',
        'make': '''if [ "$1" = distclean ]; then rm -f config.h Makefile; exit 0; fi
if [ "$1" = install ]; then
  mkdir -p "$TASK_PREFIX/lib"
  for lib in avformat avcodec swresample avutil; do : > "$TASK_PREFIX/lib/lib$lib.a"; done
fi''',
    }.items():
        path = bins / name
        path.write_text('#!/bin/sh\nset -e\n' + body + '\n')
        path.chmod(0o755)
    env = dict(os.environ, PATH=str(bins) + os.pathsep + os.environ['PATH'],
               TASK_LOG=str(root / 'configured'), TASK_PREFIX=str(root / 'toolchains/ffmpeg-ios'))
    archive = src / 'ffmpeg-7.1.5.tar.xz'

    def write_source(label):
        script = ('#!/bin/sh\necho ' + label + ' >> "$TASK_LOG"\n'
                  'touch config.h Makefile\n'
                  'printf "#define CONFIG_X_DECODER 1\\n#define CONFIG_X_DEMUXER 1\\n'
                  '#define CONFIG_X_PARSER 1\\n#define CONFIG_X_PROTOCOL 1\\n'
                  '#define CONFIG_X_MUXER 1\\n" > config_components.h\n').encode()
        with tarfile.open(archive, 'w:xz') as tar:
            item = tarfile.TarInfo('ffmpeg-7.1.5/configure')
            item.mode, item.size = 0o755, len(script)
            tar.addfile(item, io.BytesIO(script))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (src / 'SHA256SUMS').write_text(digest + '  ' + archive.name + '\n')
        return digest

    def run():
        return subprocess.run(['bash', str(build / 'build.sh')], env=env, capture_output=True, text=True)

    first = write_source('first')
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert (root / 'configured').read_text().splitlines() == ['first']
    second = write_source('second')
    assert first != second
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert (root / 'configured').read_text().splitlines() == ['first', 'second']
    assert (build / 'obj' / ('ffmpeg-7.1.5-' + second) / '.madeira-extracted').is_file()
    (src / 'SHA256SUMS').write_text('0' * 64 + '  ' + archive.name + '\n')
    result = run()
    assert result.returncode != 0 and 'sha256 mismatch' in result.stderr
print('PASS: FFmpeg source reuse tracks verified archive content')
