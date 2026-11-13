#!/usr/bin/env python3
"""Build a small LiveContainer guest using Madeira's production signed FEX runner."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile

here = Path(__file__).resolve().parent
root = here.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--prepared', type=Path, default=here / 'out')
parser.add_argument('--wine-framework', type=Path)
parser.add_argument('--wine-license', type=Path)
args = parser.parse_args()
if args.wine_framework:
    args.wine_framework = args.wine_framework.resolve()
    assert args.wine_license and args.wine_license.is_file(), 'Include Wine COPYING.LIB'
prepared = args.prepared.resolve()
guest = json.loads((prepared / 'guest.json').read_text())
assert guest.get('reference_source'), 'The standalone diagnostic package needs a reference workload; attach external PEs through the runtime API'
out = prepared / 'device'
app = out / 'Payload/MadeiraSignedFEX.app'
app.mkdir(parents=True, exist_ok=True)
obsolete_notice = app / 'Wine-source.md'
if obsolete_notice.exists():
    assert not obsolete_notice.is_symlink()
    obsolete_notice.unlink()
shutil.copyfile(root / 'COPYING', app / 'Madeira-COPYING')
framework = prepared / 'iphoneos/MadeiraSignedFEX.framework'
assert framework.is_dir(), 'Build the iphoneos bundle first'
shutil.copytree(framework, app / 'Frameworks/MadeiraSignedFEX.framework', dirs_exist_ok=True)
sources = [here / 'device.m', root / 'app/Madeira/SignedFEX.c', root / 'app/Madeira/SignedCodeProbe.m']
extra = []
if args.wine_framework:
    assert args.wine_framework.is_dir()
    shutil.copytree(args.wine_framework, app / 'Frameworks' / args.wine_framework.name, dirs_exist_ok=True)
    sources += [root / 'app/Madeira/SignedWine.m', root / 'build/ntdll-unix/signed_pe_ios.c']
    extra = ['-DMADEIRA_SIGNED_WINE=1', '-I' + str(root / 'build/signed-pe'), '-I' + str(root / 'build/ntdll-unix')]
    shutil.copyfile(args.wine_license, app / 'Wine-COPYING.LIB')
    wine_revision = subprocess.check_output(['git', '-C', str(root), 'ls-tree', 'HEAD', 'wine'], text=True).split()[2]
    wine_input = json.loads((args.wine_framework / 'preparation.json').read_text())
    (app / 'Wine-source.json').write_text(json.dumps({'repository': 'https://github.com/willfaust/wine',
        'revision': wine_revision, 'source_url': 'https://github.com/willfaust/wine/tree/' + wine_revision,
        'dll_sha256': wine_input['source_sha256'], 'native_code_bytes_changed': wine_input['code_bytes_changed'],
        'offline_teb_rewrites': wine_input.get('offline_teb_rewrites', 0),
        'offline_tsd_rewrites': wine_input.get('offline_tsd_rewrites', 0),
        'preparation': 'https://github.com/willfaust/Madeira/pull/497'}, indent=2) + '\n')
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios17.0', '-isysroot', sdk,
    '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-I', str(root / 'app/Madeira'),
    *extra, *[str(p) for p in sources], '-framework', 'UIKit', '-framework', 'Foundation',
    '-o', str(app / 'MadeiraSignedFEX')], check=True)
inputs = [*sources, here / 'bridge.S', here / 'support.c', Path(guest.get('reference_source', here / 'workload.c')),
    prepared / 'translated.bin', prepared / 'guest-image.bin', prepared / 'metadata.json', prepared / 'frame.bin', prepared / 'indexed.bin',
    prepared / 'abi.h', prepared / 'runtime.h', prepared / 'image.h', prepared / 'guest.json', prepared / 'prepared.json', framework / 'MadeiraSignedFEX',
    framework / 'FEX-LICENSE', framework / 'FEX-LICENSE-MADEIRA.md',
    here / 'export.cpp', here / 'prepare.py', here / 'bundle.py', here / 'package.py', root / 'app/Madeira/SignedFEX.h']
if args.wine_framework:
    inputs += [root / 'build/ntdll-unix/signed_pe_ios.h', root / 'app/Madeira/SignedWine.h', root / 'build/signed-pe/thread_fixture.h',
               root / 'build/signed-pe/prepare.py', root / 'build/signed-pe/thread_state.py', root / 'build/signed-pe/workload.def',
               args.wine_framework / args.wine_framework.stem]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source_id = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
provenance = {'source_id': source_id, 'sha256': hashes,
    'fex_revision': json.loads((prepared / 'metadata.json').read_text())['fex_revision']}
(app / 'source-info.json').write_text(json.dumps(provenance, indent=2) + '\n')
(app / 'FEX-source.json').write_text(json.dumps({'repository': 'https://github.com/willfaust/FEX',
    'revision': provenance['fex_revision'], 'source_url': 'https://github.com/willfaust/FEX/tree/' + provenance['fex_revision']}, indent=2) + '\n')
info = {'CFBundleIdentifier': 'com.madeira.signed-fex.program', 'CFBundleName': 'Madeira Signed FEX',
    'CFBundleDisplayName': 'Madeira Signed FEX', 'CFBundleExecutable': 'MadeiraSignedFEX',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'MinimumOSVersion': '17.0', 'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1, 2],
    'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True, 'UILaunchScreen': {},
    'MadeiraFEXSourceID': source_id,
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
            'UISceneConfigurationName': 'FEX', 'UISceneDelegateClassName': 'MadeiraFEXScene'}]}}}
if args.wine_framework:
    info['CFBundleIdentifier'] = 'com.madeira.signed-fex.wine'
    info['CFBundleDisplayName'] = 'Madeira Signed Wine'
    info['MadeiraWineFramework'] = args.wine_framework.name
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in app.rglob('*'):
        if path.is_file(): archive.write(path, path.relative_to(out))
with zipfile.ZipFile(args.output) as archive:
    assert archive.testzip() is None
    assert 'Payload/MadeiraSignedFEX.app/Info.plist' in archive.namelist()
print(args.output.resolve())
print('source-id=' + source_id)
print('ipa-sha256=' + hashlib.sha256(args.output.read_bytes()).hexdigest())
