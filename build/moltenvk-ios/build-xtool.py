#!/usr/bin/env python3
"""Build pinned MoltenVK as an iOS framework with xtool's SDK on Linux.

No Xcode, signing or device installation. SPIRV-Tools disassembly is disabled
using MoltenVK's supported MVK_EXCLUDE_SPIRV_TOOLS option; shader compilation
still uses the exact pinned SPIRV-Cross. All paths are explicit.
"""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess

PIN = 'db445ff2042d9ce348c439ad8451112f354b8d2a'


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def revision(path):
    return subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=pathlib.Path, required=True)
    p.add_argument('--sdk', type=pathlib.Path, required=True, help='iPhoneOS.sdk directory')
    p.add_argument('--toolchain', type=pathlib.Path, required=True, help='Swift toolchain usr directory')
    p.add_argument('--linker', type=pathlib.Path, required=True, help='Mach-O ld64.lld executable')
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--jobs', type=int, default=4)
    p.add_argument('--link-sdk', type=pathlib.Path, help='Optional linker-compatible SDK stubs; compilation always uses --sdk')
    a = p.parse_args()
    src, sdk, tc, linker = [x.resolve(strict=True) for x in (a.source, a.sdk, a.toolchain, a.linker)]
    link_sdk = a.link_sdk.resolve(strict=True) if a.link_sdk else sdk
    sdk_version = str(plistlib.loads((sdk / 'SDKSettings.plist').read_bytes())['Version'])
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    obj = out / 'obj'
    logs = out / 'logs'
    obj.mkdir(exist_ok=True)
    logs.mkdir(exist_ok=True)
    if revision(src) != PIN:
        raise SystemExit('Expected official MoltenVK v1.4.1 source pin')
    run(['git', '-C', src, 'diff', '--exit-code', 'HEAD', '--'], stdout=subprocess.DEVNULL)
    deps = {}
    for name, owner in [('SPIRV-Cross', 'KhronosGroup'), ('Vulkan-Headers', 'KhronosGroup'), ('cereal', 'USCiLab')]:
        pin = (src / 'ExternalRevisions' / (name + '_repo_revision')).read_text().strip()
        path = out / 'dependencies' / name
        if not (path / '.git').is_dir():
            path.mkdir(parents=True, exist_ok=True)
            run(['git', '-C', path, 'init', '-q'])
            run(['git', '-C', path, 'remote', 'add', 'origin', 'https://github.com/' + owner + '/' + name + '.git'])
            run(['git', '-C', path, 'fetch', '--depth', '1', 'origin', pin])
            run(['git', '-C', path, 'checkout', '--detach', '-q', 'FETCH_HEAD'])
        if revision(path) != pin:
            raise SystemExit('Unexpected dependency revision: ' + name)
        run(['git', '-C', path, 'diff', '--exit-code', 'HEAD', '--'], stdout=subprocess.DEVNULL)
        deps[name] = {'path': str(path), 'commit': pin}
    sc = pathlib.Path(deps['SPIRV-Cross']['path'])
    includes = [src / 'Common', src / 'MoltenVK/include',
                src / 'MoltenVKShaderConverter', src / 'MoltenVKShaderConverter/MoltenVKShaderConverter',
                pathlib.Path(deps['Vulkan-Headers']['path']) / 'include',
                pathlib.Path(deps['cereal']['path']) / 'include', sc, obj]
    includes += [src / 'MoltenVK/MoltenVK' / d for d in ['API', 'Commands', 'GPUObjects', 'Layers', 'OS', 'Utility', 'Vulkan']]
    template = (src / 'Templates/cmake/mvkGitRevDerived.h.in').read_text()
    (obj / 'mvkGitRevDerived.h').write_text(template.replace('@MVK_GIT_REV@', PIN[:8]))
    common = ['-target', 'arm64-apple-ios17.0', '-isysroot', str(sdk), '-O2', '-fPIC', '-fblocks',
              '-DMVK_FRAMEWORK_VERSION=1.4.1', '-DMVK_EXCLUDE_SPIRV_TOOLS=1',
              '-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross', '-DMVK_HIDE_VULKAN_SYMBOLS=0',
              '-DMVK_USE_METAL_PRIVATE_API=0', '-Wno-deprecated-declarations']
    common += ['-I' + str(x) for x in includes]
    files = []
    for directory in [src / 'Common', src / 'MoltenVKShaderConverter/MoltenVKShaderConverter', src / 'MoltenVK/MoltenVK']:
        files += sorted(x for x in directory.rglob('*') if x.suffix in ('.c', '.m', '.cpp', '.mm'))
    files += [sc / (name + '.cpp') for name in ['spirv_cross', 'spirv_parser', 'spirv_cross_parsed_ir',
                                              'spirv_cfg', 'spirv_glsl', 'spirv_msl', 'spirv_reflect']]
    report = {'status': 'RUNNING', 'source': PIN, 'dependencies': deps, 'target': 'arm64-apple-ios17.0',
              'spirv_disassembly': False, 'geometry_overlay': False, 'commands': [],
              'signed': False, 'installed': False, 'device_rendering': False,
              'sdk': str(sdk), 'link_sdk': str(link_sdk), 'sdk_version': sdk_version}
    tasks = []
    for i, path in enumerate(files):
        output = obj / (str(i) + '-' + path.stem + '.o')
        cxx = path.suffix in ('.cpp', '.mm')
        args = [tc / 'bin' / ('clang++' if cxx else 'clang'), *common]
        if cxx: args += ['-std=c++17']
        if path.suffix in ('.m', '.mm'): args += ['-fno-objc-arc']
        args += ['-c', path, '-o', output]
        report['commands'].append(list(map(str, args)))
        tasks.append((path, output, args))

    def compile_one(task):
        path, output, args = task
        with (logs / (output.stem + '.log')).open('w') as log:
            result = subprocess.run(list(map(str, args)), stdout=log, stderr=subprocess.STDOUT)
        print(('PASS ' if result.returncode == 0 else 'FAIL ') + path.name, flush=True)
        return result.returncode

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as pool:
            failures = sum(x != 0 for x in pool.map(compile_one, tasks))
        if failures: raise RuntimeError(str(failures) + ' compilation failures; see logs')
        framework = out / 'MoltenVK.framework'
        framework.mkdir(exist_ok=True)
        binary = framework / 'MoltenVK'
        args = [tc / 'bin/clang++', '-target', 'arm64-apple-ios17.0', '-isysroot', link_sdk,
                '-fuse-ld=' + str(linker), '-dynamiclib', '-Wl,-install_name,@rpath/MoltenVK.framework/MoltenVK',
                '-Wl,-platform_version,ios,17.0,' + sdk_version, '-o', binary, *[x[1] for x in tasks]]
        for f in ['Foundation', 'Metal', 'QuartzCore', 'IOSurface', 'IOKit', 'CoreGraphics', 'UIKit']:
            args += ['-framework', f]
        report['commands'].append(list(map(str, args)))
        with (logs / 'link.log').open('w') as log: run(args, stdout=log, stderr=subprocess.STDOUT)
        header_target = framework / 'Headers'
        shutil.copytree(src / 'MoltenVK/include', header_target, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('vulkan', 'vk_video'))
        shutil.copytree(pathlib.Path(deps['Vulkan-Headers']['path']) / 'include',
                        header_target, dirs_exist_ok=True)
        info = {'CFBundleExecutable': 'MoltenVK', 'CFBundleIdentifier': 'org.khronos.MoltenVK',
                'CFBundleName': 'MoltenVK', 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1.4.1',
                'CFBundleShortVersionString': '1.4.1', 'CFBundleSupportedPlatforms': ['iPhoneOS'],
                'MinimumOSVersion': '17.0'}
        (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
        licenses = out / 'licenses'
        licenses.mkdir(exist_ok=True)
        shutil.copy2(src / 'LICENSE', licenses / 'MoltenVK-LICENSE.txt')
        for name in ['SPIRV-Cross', 'cereal']:
            shutil.copy2(pathlib.Path(deps[name]['path']) / 'LICENSE', licenses / (name + '-LICENSE.txt'))
        vh = pathlib.Path(deps['Vulkan-Headers']['path'])
        shutil.copy2(vh / 'LICENSE.md', licenses / 'Vulkan-Headers-LICENSE.md')
        shutil.copytree(vh / 'LICENSES', licenses / 'Vulkan-Headers', dirs_exist_ok=True)
        receipt = {'repository': 'https://github.com/KhronosGroup/MoltenVK', 'commit': PIN,
                   'version': '1.4.1', 'geometry_overlay': False, 'spirv_disassembly': False,
                   'dependencies': {k: v['commit'] for k, v in deps.items()},
                   'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
        (out / 'source.json').write_text(json.dumps(receipt, indent=2) + '\n')
        report['status'] = 'PASS_UNSIGNED_FRAMEWORK_LINK'
        report['framework_sha256'] = receipt['sha256']
    except Exception as e:
        report['status'] = 'FAILED'
        report['error'] = str(e)
        raise
    finally:
        (out / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: unsigned iOS MoltenVK framework; device rendering unverified')


if __name__ == '__main__':
    main()
