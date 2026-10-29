#!/usr/bin/env python3
"""Select the versioned Wine PE farm from the pinned source, preserving owners."""
from pathlib import Path
import re
import os
import importlib.util
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DXMT = {'d3d9.dll', 'd3d9shim.dll', 'd3d9-emulated.dll', 'd3d10core.dll',
        'd3d11.dll', 'dxgi.dll', 'winemetal.dll', 'nvapi64.dll'}
CUSTOM = {'faultrep.dll', 'madeira_d3d12.dll', 'xtajit64.dll', 'xtajit.dll',
          'dockhost.exe', 'dock-notices.txt', 'wineios.drv', 'tftrace-x64.dll'}


def targets(arch, names=None):
    modules = {}
    for category in ('dlls', 'programs'):
        for makefile in (ROOT / 'wine' / category).glob('*/Makefile.in'):
            match = re.search(r'^MODULE\s*=\s*(\S+)', makefile.read_text(), re.M)
            if match:
                modules[match[1].lower()] = (makefile.parent.name, category, match[1])
    result = []
    farm = ROOT / f'app/Madeira/{arch}-windows'
    if names is None:
        required = json.loads((ROOT / 'tools/build/runtime-components.json').read_text())['windows']['required']
        names = {p.name for p in farm.iterdir()} | {
            Path(p).name for p in required if p.startswith(f'{arch}-windows/')}
    for dest in sorted(farm / name for name in names):
        name = dest.name.lower()
        dxmt = DXMT if arch == 'arm64ec' else {'d3d11.dll', 'dxgi.dll', 'winemetal.dll'}
        if name in dxmt | CUSTOM or (arch == 'arm64ec' and name in {'d3d12.dll', 'd3d12core.dll'}):
            continue
        source = 'd3d9.dll' if name == 'd3d9-wined3d.dll' else name
        if source not in modules:
            if dest.suffix.lower() in {'.exe', '.tlb'} or name.startswith('.'):
                continue  # versioned test programs and type libraries
            raise ValueError(f'No source owner for {dest.relative_to(ROOT)}')
        directory, category, module = modules[source]
        result.append((f'{category}/{directory}/{arch}-windows/{module}', dest.name, directory))
    if not result:
        raise ValueError(f'No Wine targets selected for {arch}')
    return result


def install(arch, selected):
    build = ROOT / 'wine/build-macos'
    subprocess.run(['make', '-C', str(build), '-j' + os.environ.get('JOBS', '8'),
                    *(target for target, _, _ in selected)], check=True)
    strip = ROOT / 'toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/aarch64-w64-mingw32-strip'
    for target, name, _ in selected:
        dest = ROOT / f'app/Madeira/{arch}-windows' / name
        shutil.copyfile(build / target, str(dest) + '.tmp')
        if dest.suffix != '.tlb':
            subprocess.run([str(strip), '--strip-debug', str(dest) + '.tmp'], check=True)
        Path(str(dest) + '.tmp').replace(dest)


def close_imports():
    spec = importlib.util.spec_from_file_location('runtime', ROOT / 'tools/build/runtime-components.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    for arch in ['arm64ec', 'aarch64']:
        farm = ROOT / f'app/Madeira/{arch}-windows'
        for _ in range(16):
            files = {p.name.lower(): p.read_bytes() for p in farm.iterdir() if p.is_file()}
            missing = runtime.missing_imports(files)
            if not missing:
                break
            selected = targets(arch, missing)
            if len(selected) != len(missing):
                raise ValueError(f'{arch}: missing a DLL owned by DXMT/FEX/custom runtime: {missing}')
            print(f'{arch}: building imported modules: {sorted(missing)}', flush=True)
            if arch == 'arm64ec':
                subprocess.run([str(ROOT / 'build/wine-pe/build-modules.sh'),
                                *(directory for _, _, directory in selected)], check=True)
            else:
                install(arch, selected)
        else:
            raise ValueError(f'{arch}: import closure did not converge')


def main():
    if sys.argv[1:] == ['closure']:
        close_imports()
        return
    arch, action = sys.argv[1:]
    selected = targets(arch)
    if action == 'list':
        print('\n'.join(directory if name != 'd3d9-wined3d.dll' else 'd3d9-wined3d'
                        for _, name, directory in selected))
    else:
        install(arch, selected)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
