#!/usr/bin/env python3
"""Check source bootstrap selection and source preservation without building iOS libraries."""
from pathlib import Path
import os
import re
import shlex
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
server = (root / 'build/wineserver/build.sh').read_text()
fresh_base = '# Full builds must not reuse objects from a different Wine protocol revision.' in server
before_flags = server.split('mkdir -p "$OBJ_DIR"', 1)[1].split('CC_FLAGS=(', 1)[0]
selection = before_flags + server[server.index('PATCHED_FILES=('):server.index('echo "=== Building kill wrapper')]

with tempfile.TemporaryDirectory(prefix='madeira-bootstrap-') as t:
    fixture = Path(t)
    wine = fixture / 'wine/server'
    wine.mkdir(parents=True)
    makefile = wine / 'Makefile.in'
    makefile.write_text('SOURCES = \\\n    atom.c \\\n    new_server_source.c \\\n    object.c \\\n    thread.c\n')
    obj, app, trace = fixture / 'obj', fixture / 'app.a', fixture / 'compiled'
    obj.mkdir()
    pre = '\n'.join(f'{k}={shlex.quote(str(v))}' for k, v in {
        'BUILD_DIR': fixture, 'WINE_SRC': wine.parent, 'REPO_ROOT': fixture,
        'OBJ_DIR': obj, 'APP_LIB': app, 'TRACE': trace,
    }.items()) + r'''
compile_one() { echo "$2" >> "$TRACE"; }
ar() { touch "$2"; }
'''
    def run(*args):
        return subprocess.run(['bash', '-e', '-c', pre + selection, 'fixture', *args], capture_output=True, text=True)
    assert run().returncode == 0
    assert trace.read_text().splitlines() == ['atom', 'new_server_source']
    print('PASS: new upstream sources enter the base; replacement objects stay out')
    trace.unlink()
    assert run().returncode == 0
    if fresh_base:
        assert trace.read_text().splitlines() == ['atom', 'new_server_source']
        trace.unlink()
        print('PASS: a protocol-sensitive full build recompiles the base')
    else:
        assert not trace.exists()
        print('PASS: an existing base does not recompile unchanged sources')
    (obj / 'libwineserver.a').unlink()
    assert run('request').returncode != 0 and not trace.exists()
    print('PASS: a partial first build refuses an incomplete base')
    app.write_bytes(b'previous base')
    assert run().returncode == 0
    if fresh_base:
        assert trace.read_text().splitlines() == ['atom', 'new_server_source']
        assert app.read_bytes() == b'previous base'
        print('PASS: protocol-sensitive builds preserve the old app archive and compile a fresh base')
    else:
        assert (obj / 'libwineserver.a').read_bytes() == app.read_bytes()
        print('PASS: the existing app archive remains a valid incremental source')
    app.unlink(); (obj / 'libwineserver.a').unlink()
    makefile.write_text('SOURCES =\n')
    assert run().returncode != 0 and not (obj / 'libwineserver.a').exists()
    print('PASS: an empty source list cannot publish an empty base')

    build = fixture / 'build/freetype-ios'
    build.mkdir(parents=True)
    script = build / 'build.sh'
    shutil.copyfile(root / 'build/freetype-ios/build.sh', script)
    source = fixture / 'research/freetype'
    source.mkdir(parents=True)
    keep = source / 'local-source.txt'
    keep.write_text('preserve this work')
    result = subprocess.run(['bash', str(script)], capture_output=True, text=True)
    assert result.returncode != 0 and keep.read_text() == 'preserve this work'
    print('PASS: an incomplete FreeType directory is preserved and reported')

    pipeline = fixture / 'pipeline'
    tools = pipeline / 'bin'
    tools.mkdir(parents=True)
    (pipeline / 'app/Madeira').mkdir(parents=True)
    entry = (root / 'tools/build-ipa.sh').read_text()
    entry_path = pipeline / 'tools/build-ipa.sh'
    entry_path.parent.mkdir()
    entry_path.write_text(entry)
    for relative in set(re.findall(r'"\$ROOT/([^"]+\.sh)"', entry)) | {'build/rppairing-ios/build.sh'}:
        path = pipeline / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/bash\nexit 0\n')
        path.chmod(0o755)
    (pipeline / 'tools/build/runtime-components.py').write_text('import sys\nassert sys.argv[1:] == ["build", "all"]\n')
    pairing = pipeline / 'build/rppairing-ios'
    (pairing / 'build.sh').write_text((root / 'build/rppairing-ios/build.sh').read_text())
    (pairing / 'notices.py').write_text('from pathlib import Path\nimport sys\nPath(sys.argv[1]).write_text("notices")\n')
    commands = {
        'uname': 'echo Darwin',
        'brew': 'if [ "$1" = --prefix ]; then echo "$TEST_TOOLS"; fi',
        'git': 'exit 0',
        'xcodebuild': 'exit 0',
        'rustup': 'test "$*" = "target add aarch64-apple-ios"\ntouch "$TRACE.target"',
        'cargo': 'test -f "$TRACE.target"\nmkdir -p target/aarch64-apple-ios/release\necho archive > target/aarch64-apple-ios/release/libmadeira_rppairing.a',
    }
    for name, body in commands.items():
        path = tools / name
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)
    package = pipeline / 'tools/build/package-ipa.sh'
    package.write_text('#!/bin/bash\nset -eu\ntest -s "$ROOT/app/Madeira/libmadeira_rppairing.a"\n'
                       'test -s "$ROOT/app/Madeira/legal/LICENSES-rppairing-crates.txt"\ntouch "$TRACE.packaged"\n')
    result = subprocess.run(['bash', str(entry_path)], capture_output=True, text=True,
                            env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                                     TEST_TOOLS=str(tools), TRACE=str(pipeline / 'trace')))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (pipeline / 'trace.packaged').exists()
    print('PASS: the IPA entry point prepares the Rust target, pairing archive and notices before packaging')
    for name in ['rustup', 'cargo']:
        (tools / name).write_text('#!/bin/bash\nexit 86\n')
    cached_env = dict(os.environ, GITHUB_ACTIONS='true', PATH=str(tools) + os.pathsep + os.environ['PATH'])
    helper = pairing / 'build.sh'
    assert subprocess.run(['bash', str(helper)], env=cached_env, capture_output=True).returncode == 0
    (pipeline / 'app/Madeira/legal/LICENSES-rppairing-crates.txt').unlink()
    assert subprocess.run(['bash', str(helper)], env=cached_env, capture_output=True).returncode != 0
    print('PASS: a complete pairing cache skips its compiler; missing notices require a rebuild')

for relative in ['build/wineserver/build.sh', 'build/dxmt-ios/build.sh', 'build/fex-ios/build.sh',
                 'build/fex-arm64ec/build.sh', 'build/freetype-ios/build.sh',
                 'build/llvm-ios/build.sh', 'build/wine-macos/configure.sh']:
    if (root / relative).exists():
        subprocess.run(['bash', '-n', str(root / relative)], check=True)
    else:
        assert relative in ['build/llvm-ios/build.sh', 'build/wine-macos/configure.sh'], relative
print('PASS: combined build scripts pass Bash syntax checks')
